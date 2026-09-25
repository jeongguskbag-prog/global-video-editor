"""KIS/키움 클라이언트가 공식 명세대로 요청을 만들고 응답을 해석하는지 가짜 세션으로 검증한다."""

import json

import pytest

from kr_stock_trader.brokers import _token_cache
from kr_stock_trader.brokers.base import BrokerError
from kr_stock_trader.brokers.kis import KisBroker
from kr_stock_trader.brokers.db import DbBroker
from kr_stock_trader.brokers.kiwoom import KiwoomBroker
from kr_stock_trader.brokers.ls import LsBroker
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
        h = headers or {}
        key_id = h.get("tr_id") or h.get("api-id") or h.get("tr_cd")
        for (suffix, rid), responses in self.routes.items():
            if url.endswith(suffix) and (rid is None or rid == key_id):
                return responses.pop(0) if len(responses) > 1 else responses[0]
        raise AssertionError(f"예상하지 못한 요청: {url} {key_id}")

    def post(self, url, json=None, headers=None, timeout=None, data=None):
        return self._respond(url, headers, json if json is not None else data)

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


def ls(routes):
    routes = {("/oauth2/token", None): [FakeResponse({"access_token": "L", "expires_in": 86400})], **routes}
    session = FakeSession(routes)
    return LsBroker("key", "secret", "demo", session=session, rate_interval=0, chart_interval=0), session


def test_ls_token_is_form_encoded_and_order_body():
    broker, session = ls({("/stock/order", "CSPAT00601"): [FakeResponse({
        "rsp_cd": "00040", "rsp_msg": "매수주문이 완료되었습니다.", "CSPAT00601OutBlock2": {"OrdNo": 12345}})]})
    r = broker.place_order("005930", Side.BUY, 3, OrderType.LIMIT, 70_100)
    assert r.ok and r.order_id == "12345"
    token_call = session.calls[0]
    assert token_call["payload"]["appsecretkey"] == "secret" and token_call["payload"]["scope"] == "oob"
    body = session.calls[-1]["payload"]["CSPAT00601InBlock1"]
    assert body["IsuNo"] == "A005930" and body["OrdQty"] == 3 and body["OrdPrc"] == 70_100
    assert body["BnsTpCode"] == "2" and body["OrdprcPtnCode"] == "00"
    assert session.calls[-1]["headers"]["authorization"] == "Bearer L"


def test_ls_error_code_and_market_sell():
    broker, session = ls({("/stock/order", "CSPAT00601"): [
        FakeResponse({"rsp_cd": "01234", "rsp_msg": "주문가능수량이 부족합니다"}),
        FakeResponse({"rsp_cd": "00039", "rsp_msg": "매도주문 완료", "CSPAT00601OutBlock2": {"OrdNo": 7}}),
    ]})
    bad = broker.place_order("005930", Side.SELL, 1)
    assert not bad.ok and "부족" in bad.message
    good = broker.place_order("005930", Side.SELL, 1)
    assert good.ok
    body = session.calls[-1]["payload"]["CSPAT00601InBlock1"]
    assert body["BnsTpCode"] == "1" and body["OrdprcPtnCode"] == "03" and body["OrdPrc"] == 0


def test_ls_quote_balance_and_candles():
    broker, _ = ls({
        ("/stock/market-data", "t1101"): [FakeResponse({"rsp_cd": "00000", "t1101OutBlock": {
            "price": 70100, "bidho1": 70100, "offerho1": 70200}})],
        ("/stock/accno", "CSPAQ12200"): [FakeResponse({"rsp_cd": "00136", "CSPAQ12200OutBlock2": {"MnyOrdAbleAmt": 500000}})],
        ("/stock/accno", "t0424"): [FakeResponse({"rsp_cd": "00000",
            "t0424OutBlock": {"sunamt": 1201000, "cts_expcode": ""},
            "t0424OutBlock1": [{"expcode": "005930", "hname": "삼성전자", "janqty": 10, "pamt": 68000, "price": 70100}]})],
        ("/stock/chart", "t8412"): [FakeResponse({"rsp_cd": "00000", "t8412OutBlock": {"cts_date": ""},
            "t8412OutBlock1": [
                {"date": "20260925", "time": "090000", "open": 69800, "high": 70100, "low": 69700, "close": 70000, "jdiff_vol": 50},
                {"date": "20260925", "time": "090500", "open": 70000, "high": 70300, "low": 69900, "close": 70200, "jdiff_vol": 100},
            ]})],
    })
    q = broker.get_quote("005930")
    assert (q.price, q.bid, q.ask) == (70_100, 70_100, 70_200)
    b = broker.get_balance()
    assert b.cash == 500_000 and b.total_eval == 1_201_000 and b.positions[0].qty == 10
    candles = broker.get_candles("005930", "5m", 2)
    assert [c.close for c in candles] == [70_000, 70_200] and candles[1].time.minute == 5


def db(routes):
    routes = {("/oauth2/token", None): [FakeResponse({"access_token": "D", "expires_in": 86400})], **routes}
    session = FakeSession(routes)
    return DbBroker("key", "secret", "demo", session=session, rate_interval=0), session


def test_db_order_body_and_result():
    broker, session = db({("/api/v1/trading/kr-stock/order", None): [FakeResponse({
        "rsp_cd": "00000", "rsp_msg": "정상", "Out": {"OrdNo": 3021, "IsuNm": "삼성전자"}})]})
    r = broker.place_order("005930", Side.SELL, 2)
    assert r.ok and r.order_id == "3021"
    body = session.calls[-1]["payload"]["In"]
    assert body == {"IsuNo": "A005930", "OrdQty": 2, "OrdPrc": 0, "BnsTpCode": "1", "OrdprcPtnCode": "03",
                    "MgntrnCode": "000", "LoanDt": "00000000", "OrdCndiTpCode": "0", "TrchNo": 1}


def test_db_token_retry_and_error():
    broker, session = db({("/api/v1/quote/kr-stock/inquiry/price", None): [
        FakeResponse({"rsp_cd": "IGW00123", "rsp_msg": "기간이 만료된 token 입니다."}),
        FakeResponse({"rsp_cd": "00000", "Out": {"Prpr": "70100", "Bidp1": "70100", "Askp1": "70200"}}),
    ]})
    q = broker.get_quote("005930")
    assert q.price == 70_100 and q.ask == 70_200
    assert sum(c["url"].endswith("/oauth2/token") for c in session.calls) == 2

    broker2, _ = db({("/api/v1/trading/kr-stock/order", None): [FakeResponse(
        {"rsp_cd": "IGW00201", "rsp_msg": "호출 거래건수를 초과하였습니다."})]})
    assert not broker2.place_order("005930", Side.BUY, 1).ok


def test_db_balance_and_candles():
    broker, _ = db({
        ("/inquiry/acnt-deposit", None): [FakeResponse({"rsp_cd": "00000", "Out1": {"PrsmptDpsD2": 800000, "DpsBalAmt": 900000}})],
        ("/inquiry/balance", None): [FakeResponse({"rsp_cd": "00000", "Out": {"DpsastAmt": 1500000},
            "Out1": [{"IsuNo": "A005930", "IsuNm": "삼성전자", "BalQty0": 10, "ExecPrc": 68000, "NowPrc": 70100},
                     {"IsuNo": "A000660", "IsuNm": "SK하이닉스", "BalQty0": 0}]})],
        ("/kr-chart/day", None): [FakeResponse({"rsp_cd": "00000", "Out": [
            {"Date": "20260925", "Oprc": "3", "Hprc": "4", "Lprc": "2", "Prpr": "3", "CntgVol": "1"},
            {"Date": "20260924", "Oprc": "2", "Hprc": "3", "Lprc": "1", "Prpr": "2", "CntgVol": "1"}]})],
    })
    b = broker.get_balance()
    assert b.cash == 800_000 and b.total_eval == 1_500_000
    assert [(p.symbol, p.qty, p.avg_price) for p in b.positions] == [("005930", 10, 68_000)]
    assert [c.close for c in broker.get_candles("005930", "D", 5)] == [2, 3]
