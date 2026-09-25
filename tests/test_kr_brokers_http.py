"""KIS/키움 클라이언트가 공식 명세대로 요청을 만들고 응답을 해석하는지 가짜 세션으로 검증한다."""

import json

import pytest

from kr_stock_trader.brokers import _token_cache
from kr_stock_trader.brokers.base import BrokerError
from kr_stock_trader.brokers.kis import KisBroker
from kr_stock_trader.brokers.kiwoom import KiwoomBroker
from kr_stock_trader.models import OrderType, Side


class FakeResponse:
    def __init__(self, data, headers=None, status=200):
        self._data, self.headers, self.status_code = data, headers or {}, status
        self.content = json.dumps(data).encode()
        self.text = self.content.decode()

    def json(self):
        return self._data


class FakeSession:
    def __init__(self, routes):
        self.routes = routes  # (path 끝부분, tr_id/api-id) → 응답 리스트
        self.calls = []

    def _respond(self, url, headers, payload):
        self.calls.append({"url": url, "headers": headers or {}, "payload": payload})
        key_id = (headers or {}).get("tr_id") or (headers or {}).get("api-id")
        for (suffix, rid), responses in self.routes.items():
            if url.endswith(suffix) and (rid is None or rid == key_id):
                return responses.pop(0) if len(responses) > 1 else responses[0]
        raise AssertionError(f"예상하지 못한 요청: {url} {key_id}")

    def post(self, url, json=None, headers=None, timeout=None):
        return self._respond(url, headers, json)

    def request(self, method, url, headers=None, params=None, json=None, timeout=None):
        return self._respond(url, headers, params if method == "GET" else json)


@pytest.fixture(autouse=True)
def isolated_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(_token_cache, "CACHE_DIR", str(tmp_path))


def kis(routes, env="demo"):
    routes = {("/oauth2/tokenP", None): [FakeResponse({"access_token": "T", "expires_in": 86400})], **routes}
    session = FakeSession(routes)
    return KisBroker("key", "secret", "12345678-01", env, session=session, rate_interval=0), session


def test_kis_order_uses_demo_tr_and_body():
    broker, session = kis({("/trading/order-cash", "VTTC0012U"): [FakeResponse(
        {"rt_cd": "0", "msg1": "주문 전송 완료", "output": {"ODNO": "0000117057"}})]})
    r = broker.place_order("005930", Side.BUY, 3, OrderType.LIMIT, 70_100)
    assert r.ok and r.order_id == "0000117057"
    body = session.calls[-1]["payload"]
    assert body["CANO"] == "12345678" and body["ACNT_PRDT_CD"] == "01"
    assert body["ORD_DVSN"] == "00" and body["ORD_QTY"] == "3" and body["ORD_UNPR"] == "70100"
    assert body["EXCG_ID_DVSN_CD"] == "KRX"
    assert session.calls[-1]["headers"]["authorization"] == "Bearer T"


def test_kis_real_sell_market_order_tr():
    broker, session = kis({("/trading/order-cash", "TTTC0011U"): [FakeResponse(
        {"rt_cd": "0", "msg1": "ok", "output": {"ODNO": "1"}})]}, env="real")
    assert broker.base_url.endswith(":9443")
    r = broker.place_order("005930", Side.SELL, 1)
    assert r.ok
    body = session.calls[-1]["payload"]
    assert body["ORD_DVSN"] == "01" and body["ORD_UNPR"] == "0" and body["SLL_TYPE"] == "01"


def test_kis_order_failure_is_reported():
    broker, _ = kis({("/trading/order-cash", None): [FakeResponse(
        {"rt_cd": "1", "msg_cd": "APBK0986", "msg1": "주문가능금액을 초과 했습니다"})]})
    r = broker.place_order("005930", Side.BUY, 1000)
    assert not r.ok and "주문가능금액" in r.message


def test_kis_quote_and_balance_pagination():
    broker, _ = kis({
        ("/quotations/inquire-price", None): [FakeResponse({"rt_cd": "0", "output": {"stck_prpr": "70100"}})],
        ("/quotations/inquire-asking-price-exp-ccn", None): [FakeResponse(
            {"rt_cd": "0", "output1": {"askp1": "70200", "bidp1": "70100"}})],
        ("/trading/inquire-balance", "VTTC8434R"): [
            FakeResponse({"rt_cd": "0", "ctx_area_fk100": "a", "ctx_area_nk100": "b",
                          "output1": [{"pdno": "005930", "prdt_name": "삼성전자", "hldg_qty": "10",
                                       "pchs_avg_pric": "68000.0000", "prpr": "70100"}],
                          "output2": [{"dnca_tot_amt": "1000000", "prvs_rcdl_excc_amt": "900000",
                                       "tot_evlu_amt": "1601000"}]}, headers={"tr_cont": "M"}),
            FakeResponse({"rt_cd": "0",
                          "output1": [{"pdno": "000660", "prdt_name": "SK하이닉스", "hldg_qty": "0"},
                                      {"pdno": "035420", "prdt_name": "NAVER", "hldg_qty": "2",
                                       "pchs_avg_pric": "200000", "prpr": "210000"}],
                          "output2": [{"dnca_tot_amt": "1000000", "prvs_rcdl_excc_amt": "900000",
                                       "tot_evlu_amt": "1601000"}]}, headers={"tr_cont": "D"}),
        ],
    })
    q = broker.get_quote("005930")
    assert (q.price, q.bid, q.ask) == (70_100, 70_100, 70_200)
    b = broker.get_balance()
    assert b.cash == 900_000 and b.total_eval == 1_601_000
    assert [(p.symbol, p.qty) for p in b.positions] == [("005930", 10), ("035420", 2)]


def test_kis_daily_candles_sorted_oldest_first():
    rows = [{"stck_bsop_date": d, "stck_oprc": "1", "stck_hgpr": "3", "stck_lwpr": "1",
             "stck_clpr": c, "acml_vol": "10"} for d, c in [("20260925", "3"), ("20260924", "2"), ("20260923", "1")]]
    broker, _ = kis({("/inquire-daily-itemchartprice", "FHKST03010100"): [
        FakeResponse({"rt_cd": "0", "output2": rows})]})
    candles = broker.get_candles("005930", "D", 2)
    assert [c.close for c in candles] == [2, 3]


def test_kis_token_is_cached_between_instances():
    b1, s1 = kis({("/inquire-price", None): [FakeResponse({"rt_cd": "0", "output": {"stck_prpr": "1"}})],
                  ("/inquire-asking-price-exp-ccn", None): [FakeResponse({"rt_cd": "1"})]})
    b1.get_quote("005930")
    b2, s2 = kis({("/inquire-price", None): [FakeResponse({"rt_cd": "0", "output": {"stck_prpr": "1"}})],
                  ("/inquire-asking-price-exp-ccn", None): [FakeResponse({"rt_cd": "1"})]})
    b2.get_quote("005930")
    assert not any(c["url"].endswith("/oauth2/tokenP") for c in s2.calls)


def test_kis_rejects_bad_account():
    with pytest.raises(BrokerError):
        KisBroker("k", "s", "1234", "demo")


def kiwoom(routes):
    routes = {("/oauth2/token", None): [FakeResponse({"token": "W", "expires_dt": "20991231235959",
                                                      "return_code": 0})], **routes}
    session = FakeSession(routes)
    return KiwoomBroker("key", "secret", "demo", session=session, rate_interval=0), session


def test_kiwoom_order_and_quote():
    broker, session = kiwoom({
        ("/api/dostk/ordr", "kt10000"): [FakeResponse({"ord_no": "00024", "return_code": 0, "return_msg": "정상"})],
        ("/api/dostk/stkinfo", "ka10001"): [FakeResponse({"cur_prc": "-70100", "return_code": 0})],
        ("/api/dostk/mrkcond", "ka10004"): [FakeResponse({"sel_fpr_bid": "+70200", "buy_fpr_bid": "-70100",
                                                          "return_code": 0})],
    })
    assert broker.base_url == "https://mockapi.kiwoom.com"
    r = broker.place_order("005930", Side.BUY, 2)
    assert r.ok and r.order_id == "00024"
    body = session.calls[-1]["payload"]
    assert body == {"dmst_stex_tp": "KRX", "stk_cd": "005930", "ord_qty": "2", "ord_uv": "",
                    "trde_tp": "3", "cond_uv": ""}
    q = broker.get_quote("005930")
    assert (q.price, q.bid, q.ask) == (70_100, 70_100, 70_200)


def test_kiwoom_balance_and_minute_candles():
    broker, _ = kiwoom({
        ("/api/dostk/acnt", "kt00001"): [FakeResponse({"ord_alow_amt": "000000500000", "return_code": 0})],
        ("/api/dostk/acnt", "kt00018"): [FakeResponse({
            "tot_evlt_amt": "000001201000", "return_code": 0,
            "acnt_evlt_remn_indv_tot": [{"stk_cd": "A005930", "stk_nm": "삼성전자", "rmnd_qty": "000000000010",
                                         "pur_pric": "000000068000", "cur_prc": "000000070100"}]})],
        ("/api/dostk/chart", "ka10080"): [FakeResponse({"return_code": 0, "stk_min_pole_chart_qry": [
            {"cntr_tm": "20260925090500", "open_pric": "+70000", "high_pric": "+70300",
             "low_pric": "-69900", "cur_prc": "+70200", "trde_qty": "100"},
            {"cntr_tm": "20260925090000", "open_pric": "+69800", "high_pric": "+70100",
             "low_pric": "-69700", "cur_prc": "+70000", "trde_qty": "50"}]})],
    })
    b = broker.get_balance()
    assert b.cash == 500_000 and b.positions[0].symbol == "005930" and b.positions[0].qty == 10
    candles = broker.get_candles("005930", "5m", 2)
    assert [c.close for c in candles] == [70_000, 70_200]


def test_kis_minute_candles_incremental(monkeypatch):
    from datetime import datetime
    from kr_stock_trader.brokers import kis as kis_module
    from kr_stock_trader.market import KST

    now = {"t": datetime(2026, 9, 25, 9, 40, 30, tzinfo=KST)}
    monkeypatch.setattr(kis_module, "now_kst", lambda: now["t"])

    def rows(start_min, end_min):
        out = []
        for m in range(end_min, start_min - 1, -1):  # 최신 → 과거
            out.append({"stck_bsop_date": "20260925", "stck_cntg_hour": f"09{m:02d}00", "stck_oprc": "100",
                        "stck_hgpr": "101", "stck_lwpr": "99", "stck_prpr": str(100 + m), "cntg_vol": "1"})
        return out

    broker, session = kis({("/inquire-time-itemchartprice", "FHKST03010200"): [
        FakeResponse({"rt_cd": "0", "output2": rows(11, 40)}),   # 첫 조회: 09:11~09:40
        FakeResponse({"rt_cd": "0", "output2": rows(0, 10)}),    # 이어서: 09:00~09:10
        FakeResponse({"rt_cd": "0", "output2": rows(12, 41)}),   # 다음 주기: 최신 1페이지만
    ]})
    first = broker.get_candles("005930", "1m", 100)
    assert len(first) == 41 and first[0].time.minute == 0
    now["t"] = datetime(2026, 9, 25, 9, 41, 30, tzinfo=KST)
    second = broker.get_candles("005930", "1m", 100)
    assert len(second) == 42 and second[-1].close == 141
    chart_calls = [c for c in session.calls if c["url"].endswith("inquire-time-itemchartprice")]
    assert len(chart_calls) == 3

    five = broker.get_candles("005930", "5m", 100)
    assert five[0].time.minute == 0 and five[0].close == 104 and five[-1].close == 141
