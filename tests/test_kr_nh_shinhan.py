"""NH(NHPLUG REST)·신한(indi) 클라이언트 검증. NH 는 가짜 HTTP 세션, 신한은 가짜 indi 세션을 쓴다."""

import json

import pytest

from kr_stock_trader.brokers import _token_cache
from kr_stock_trader.brokers.base import BrokerError
from kr_stock_trader.brokers.nh import NhBroker
from kr_stock_trader.brokers.shinhan import IndiResult, ShinhanBroker, load_fields
from kr_stock_trader.models import OrderType, Side


@pytest.fixture(autouse=True)
def isolated_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(_token_cache, "CACHE_DIR", str(tmp_path))


class Resp:
    def __init__(self, data, status=200, headers=None):
        self._data, self.status_code, self.headers = data, status, headers or {}
        self.content = json.dumps(data).encode()
        self.text = self.content.decode()

    def json(self):
        return self._data


class Session:
    def __init__(self, routes):
        self.routes, self.calls = routes, []

    def post(self, url, headers=None, json=None, params=None, timeout=None, data=None):
        self.calls.append({"url": url, "headers": headers or {}, "json": json, "params": params})
        for suffix, responses in self.routes.items():
            if url.endswith(suffix):
                return responses.pop(0) if len(responses) > 1 else responses[0]
        raise AssertionError(f"예상하지 못한 요청: {url}")


def nh(routes, env="demo", account=""):
    routes = {"/oauth2/token": [Resp({"access_token": "N", "expires_in": 86400})], **routes}
    s = Session(routes)
    return NhBroker("key", "secret", account, env, session=s, rate_interval=0), s


ACCTS = Resp({"rsp_msg": "정상", "Output_0": [{"acct_no": "20100000001", "acct_type": "01"},
                                              {"acct_no": "20100000003", "acct_type": "03"}]})


def test_nh_token_from_live_host_and_mock_account_selection():
    broker, s = nh({"/n2/acctinfo": [ACCTS], "/krstock/order/v1/cashBuy": [Resp(
        {"rsp_cd": "00166", "rsp_msg": "매수주문이 접수되었습니다", "Output_0": {"mkt_orr_no": "0000012345"}})]})
    r = broker.place_order("005930", Side.BUY, 2, OrderType.LIMIT, 70_100)
    assert r.ok and r.order_id == "0000012345"
    token = s.calls[0]
    assert token["url"] == "https://api.nhplug.com:8443/oauth2/token"
    assert token["params"]["appsecretkey"] == "secret" and token["params"]["scope"] == "oob"
    order = s.calls[-1]
    assert order["url"].startswith("https://moapi.nhplug.com:8443")
    assert order["headers"]["x-client-id"] == "key" and order["headers"]["authorization"] == "Bearer N"
    body = order["json"]["Input_0"]
    assert body["act_no"] == "20100000003"  # 모의투자는 acct_type 03
    assert body["nmn_pr_tp_cd"] == "01" and body["orr_pr"] == 70_100 and body["rmt_mkt_cd"] == "KRX"


def test_nh_market_sell_and_failure_uses_rsp_msg():
    broker, s = nh({"/krstock/order/v1/cashSell": [
        Resp({"rsp_cd": "10006", "rsp_msg": "매도가능수량이 부족합니다"}),
        Resp({"rsp_msg": "정상", "Output_0": {"mkt_orr_no": "77"}}),
    ]}, env="real", account="20100000001")
    bad = broker.place_order("005930", Side.SELL, 5)
    assert not bad.ok and "부족" in bad.message
    good = broker.place_order("005930", Side.SELL, 5)
    assert good.ok
    body = s.calls[-1]["json"]["Input_0"]
    assert body["nmn_pr_tp_cd"] == "05" and "orr_pr" not in body
    assert s.calls[-1]["url"].startswith("https://api.nhplug.com:8443")


def test_nh_real_env_needs_live_account():
    broker, _ = nh({"/n2/acctinfo": [Resp({"Output_0": [{"acct_no": "3", "acct_type": "03"}]})]}, env="real")
    assert "실전 계좌를 찾지 못했습니다" in broker.place_order("005930", Side.BUY, 1).message


def test_nh_quote_candles_balance():
    broker, s = nh({
        "/krstock/quote/v1/currentPrice": [Resp({"Output_0": {"stck_prpr": "70100", "askp1": "70200", "bidp1": "70100"}})],
        "/krstock/quote/v1/period": [Resp({"Output_0": {"iem_cd": "005930"}, "Output_1": [
            {"bsop_date": "20260925", "bsop_time": "090500", "stck_oprc": "70000", "stck_hgpr": "70300",
             "stck_lwpr": "69900", "stck_prpr": "70200", "vol": "100"},
            {"bsop_date": "20260925", "bsop_time": "090000", "stck_oprc": "69800", "stck_hgpr": "70100",
             "stck_lwpr": "69700", "stck_prpr": "70000", "vol": "50"}]})],
        "/krstock/inquiry/v1/balance": [
            Resp({"Output_0": {"orr_pbl_amt4": "800000", "tot_aet_amt": "1500000"},
                  "Output_1": [{"iem_cd": "A005930", "iem_nm": "삼성전자", "itg_bnc_qty": "10.000000",
                                "phs_pr": "68000", "now_pr": "70100"}]},
                 headers={"cts": "NEXT", "cts_flag": "Y"}),
            Resp({"Output_0": {"orr_pbl_amt4": "800000", "tot_aet_amt": "1500000"},
                  "Output_1": [{"iem_cd": "035420", "iem_nm": "NAVER", "itg_bnc_qty": "2", "phs_pr": "200000",
                                "now_pr": "210000"}]}, headers={"cts_flag": "N"}),
        ],
    }, account="20100000003")
    q = broker.get_quote("005930")
    assert (q.price, q.bid, q.ask) == (70_100, 70_100, 70_200)
    candles = broker.get_candles("005930", "5m", 10)
    assert [c.close for c in candles] == [70_000, 70_200]
    period = [c for c in s.calls if c["url"].endswith("/period")][0]["json"]["Input_0"]
    assert period["gubun"] == "5" and period["xtick"] == "5" and period["view_main_yn"] == "Y"
    b = broker.get_balance()
    assert b.cash == 800_000 and b.total_eval == 1_500_000
    assert [(p.symbol, p.qty) for p in b.positions] == [("005930", 10), ("035420", 2)]
    balance_calls = [c for c in s.calls if c["url"].endswith("/balance")]
    assert balance_calls[1]["headers"]["cts"] == "NEXT"
    assert balance_calls[0]["json"]["Input_0"]["aly_qut_cd"] == "1"


def test_nh_empty_quote_raises_with_message():
    broker, _ = nh({"/krstock/quote/v1/currentPrice": [Resp({"rsp_msg": "종목코드를 확인하세요"})]})
    with pytest.raises(BrokerError, match="종목코드"):
        broker.get_quote("999999")


def test_nh_http_errors():
    broker, s = nh({"/krstock/quote/v1/currentPrice": [
        Resp({"rsp_cd": "IGW40043", "rsp_msg": "token invalid"}, status=401),
        Resp({"Output_0": {"stck_prpr": "1"}}),
    ]})
    assert broker.get_quote("005930").price == 1
    assert sum(c["url"].endswith("/oauth2/token") for c in s.calls) == 2

    broker2, _ = nh({"/krstock/quote/v1/currentPrice": [Resp({"rsp_cd": "IGW42902", "rsp_msg": "too many"}, status=429)]})
    with pytest.raises(BrokerError, match="한도"):
        broker2.get_quote("005930")


class FakeIndi:
    def __init__(self, responses):
        self.responses, self.calls = responses, []

    def request(self, tr, inputs, single=(), multi=()):
        self.calls.append((tr, dict(inputs), list(single), list(multi)))
        res = self.responses[tr]
        if isinstance(res, Exception):
            raise res
        return res


def shinhan(responses, orders_enabled=True):
    session = FakeIndi(responses)
    return ShinhanBroker("270-01-123456", "0000", "demo", session=session, orders_enabled=orders_enabled), session


def test_shinhan_chart_uses_confirmed_field_order():
    rows = [{0: "20260925", 1: "090500", 2: "70000", 3: "70300", 4: "69900", 5: "70200", 9: "100"},
            {0: "20260925", 1: "090000", 2: "69800", 3: "70100", 4: "69700", 5: "70000", 9: "50"}]
    broker, s = shinhan({"TR_SCHART": IndiResult({}, rows)})
    candles = broker.get_candles("005930", "5m", 10)
    assert [c.close for c in candles] == [70_000, 70_200] and candles[0].volume == 50
    tr, inputs, _, multi = s.calls[0]
    assert inputs[0] == "005930" and inputs[1] == "1" and inputs[2] == "5" and 9 in multi
    assert broker.get_quote("005930").price == 70_200


def test_shinhan_balance():
    broker, s = shinhan({
        "SABA200QB": IndiResult({}, [{0: "A005930", 1: "삼성전자", 2: "10", 5: "70100", 6: "68000"},
                                     {0: "A000660", 1: "SK하이닉스", 2: "0", 5: "0", 6: "0"}]),
        "SABA655Q1": IndiResult({0: "800000"}, []),
    })
    b = broker.get_balance()
    assert b.cash == 800_000 and [(p.symbol, p.qty, p.avg_price) for p in b.positions] == [("005930", 10, 68_000)]
    assert s.calls[0][1] == {0: "27001123456", 1: "01", 2: "0000"}


def test_shinhan_orders_disabled_until_verified():
    broker, s = shinhan({"SABA101U1": IndiResult({0: "1"}, [])}, orders_enabled=False)
    r = broker.place_order("005930", Side.BUY, 1)
    assert not r.ok and "SHINHAN_ORDER_ENABLED" in r.message and not s.calls


def test_shinhan_order_inputs_and_result():
    broker, s = shinhan({"SABA101U1": IndiResult({0: "0001234"}, [])})
    r = broker.place_order("005930", Side.SELL, 3, OrderType.LIMIT, 70_100)
    assert r.ok and r.order_id == "0001234"
    inputs = s.calls[0][1]
    assert inputs[5] == "1" and inputs[6] == "005930" and inputs[7] == "3" and inputs[8] == "70100"
    assert inputs[10] == "2"  # 지정가

    broker2, _ = shinhan({"SABA101U1": BrokerError("indi SABA101U1 오류 [1] 주문가능수량 부족")})
    assert "부족" in broker2.place_order("005930", Side.BUY, 1).message


def test_shinhan_fields_override(tmp_path):
    p = tmp_path / "f.json"
    p.write_text('{"balance": {"out": {"qty": 3}}, "cash": {"tr": "SABA999Q1"}}', encoding="utf-8")
    fields = load_fields(str(p))
    assert fields["balance"]["out"]["qty"] == 3 and fields["balance"]["out"]["code"] == 0
    assert fields["cash"]["tr"] == "SABA999Q1" and fields["cash"]["single"]["orderable"] == 0


def test_shinhan_requires_windows_without_session(monkeypatch):
    monkeypatch.setattr("sys.platform", "linux")
    with pytest.raises(BrokerError, match="Windows"):
        ShinhanBroker("1", "2")
