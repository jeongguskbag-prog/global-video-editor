"""대신증권 CYBOS Plus 클라이언트를 가짜 COM 객체로 검증한다 (Windows 없이 실행 가능)."""

import pytest

from kr_stock_trader.brokers.base import BrokerError
from kr_stock_trader.brokers.daishin import DaishinBroker
from kr_stock_trader.models import OrderType, Side


class FakeCom:
    def __init__(self, header=None, rows=None, status=0, msg="정상", pages=None):
        self.inputs, self.header, self.rows = {}, header or {}, rows or []
        self.status, self.msg = status, msg
        self.pages = pages or []  # 연속조회 시 이어서 줄 (header, rows) 목록
        self.requests = 0
        self.Continue = bool(self.pages)

    def SetInputValue(self, i, v):
        self.inputs[i] = v

    def BlockRequest(self):
        self.requests += 1
        if self.requests > 1 and self.pages:
            self.header, self.rows = self.pages.pop(0)
            self.Continue = bool(self.pages)

    def GetDibStatus(self):
        return self.status

    def GetDibMsg1(self):
        return self.msg

    def GetHeaderValue(self, i):
        return self.header.get(i, 0)

    def GetDataValue(self, field, i):
        return self.rows[i][field]


class FakeCybos:
    def __init__(self, connected=1, remain=(5,)):
        self.IsConnect = connected
        self.remain = list(remain)
        self.LimitRequestRemainTime = 300

    def GetLimitRemainCount(self, kind):
        return self.remain.pop(0) if len(self.remain) > 1 else self.remain[0]


class FakeTdUtil:
    AccountNumber = ("78012345",)

    def __init__(self, init_result=0):
        self.init_result = init_result

    def TradeInit(self, flag):
        return self.init_result

    def GoodsList(self, account, kind):
        return ("01",)


def make(objs, account=""):
    objs.setdefault("CpUtil.CpCybos", FakeCybos())
    objs.setdefault("CpTrade.CpTdUtil", FakeTdUtil())
    slept = []
    broker = DaishinBroker(account, "demo", dispatch=lambda prog: objs[prog], sleep=slept.append)
    return broker, slept


def test_requires_connection():
    with pytest.raises(BrokerError, match="연결"):
        make({"CpUtil.CpCybos": FakeCybos(connected=0)})


def test_quote():
    mst = FakeCom(header={11: 70100, 16: 70200, 17: 70100})
    broker, _ = make({"DsCbo1.StockMst": mst})
    q = broker.get_quote("005930")
    assert mst.inputs[0] == "A005930"
    assert (q.price, q.bid, q.ask) == (70_100, 70_100, 70_200)


def test_minute_chart_parsing_and_order():
    rows = [  # 최신 → 과거, 필드 순서: 날짜, 시간, 시가, 고가, 저가, 종가, 거래량
        (20260925, 905, 70000, 70300, 69900, 70200, 100),
        (20260925, 900, 69800, 70100, 69700, 70000, 50),
    ]
    chart = FakeCom(header={3: 2}, rows=rows)
    broker, _ = make({"CpSysDib.StockChart": chart})
    candles = broker.get_candles("005930", "5m", 10)
    assert chart.inputs[6] == ord("m") and chart.inputs[7] == 5 and chart.inputs[1] == ord("2")
    assert [c.close for c in candles] == [70_000, 70_200]
    assert candles[0].time.hour == 9 and candles[0].time.minute == 0


def test_daily_chart():
    chart = FakeCom(header={3: 1}, rows=[(20260925, 0, 1, 3, 1, 2, 9)])
    broker, _ = make({"CpSysDib.StockChart": chart})
    c = broker.get_candles("005930", "D", 1)[0]
    assert chart.inputs[6] == ord("D") and 7 not in chart.inputs
    assert c.time.year == 2026 and c.close == 2


def test_balance_with_continuation():
    first = {3: 1_500_000, 7: 1}, [{0: "삼성전자", 7: 10, 9: 701_000, 12: "A005930", 17: 68_000}]
    second = {3: 1_500_000, 7: 2}, [{0: "SK하이닉스", 7: 0, 9: 0, 12: "A000660", 17: 0},
                                     {0: "NAVER", 7: 2, 9: 420_000, 12: "A035420", 17: 200_000}]
    bal = FakeCom(header=first[0], rows=first[1], pages=[second])
    cash = FakeCom(header={10: 800_000})
    broker, _ = make({"CpTrade.CpTd6033": bal, "CpTrade.CpTdNew5331A": cash})
    b = broker.get_balance()
    assert b.cash == 800_000 and b.total_eval == 1_500_000
    assert [(p.symbol, p.qty, p.avg_price, p.current_price) for p in b.positions] == [
        ("005930", 10, 68_000, 70_100), ("035420", 2, 200_000, 210_000)]
    assert bal.inputs[0] == "78012345" and bal.inputs[1] == "01"


def test_market_and_limit_orders():
    order = FakeCom(header={8: 4021})
    broker, _ = make({"CpTrade.CpTd0311": order})
    r = broker.place_order("005930", Side.BUY, 3)
    assert r.ok and r.order_id == "4021"
    assert order.inputs == {0: "2", 1: "78012345", 2: "01", 3: "A005930", 4: 3, 5: 0, 7: "0", 8: "03"}
    broker.place_order("005930", Side.SELL, 1, OrderType.LIMIT, 70_100)
    assert order.inputs[0] == "1" and order.inputs[5] == 70_100 and order.inputs[8] == "01"


def test_order_failure_and_trade_init_failure():
    broker, _ = make({"CpTrade.CpTd0311": FakeCom(status=1, msg="주문가능금액 부족")})
    r = broker.place_order("005930", Side.BUY, 1)
    assert not r.ok and "주문가능금액" in r.message

    broker2, _ = make({"CpTrade.CpTdUtil": FakeTdUtil(init_result=-1)})
    assert "초기화" in broker2.place_order("005930", Side.BUY, 1).message


def test_unknown_account_rejected():
    broker, _ = make({"CpTrade.CpTd0311": FakeCom(header={8: 1})}, account="99999999")
    assert "계좌 목록" in broker.place_order("005930", Side.BUY, 1).message


def test_waits_when_request_limit_exhausted():
    mst = FakeCom(header={11: 1})
    broker, slept = make({"CpUtil.CpCybos": FakeCybos(remain=(0, 0, 3)), "DsCbo1.StockMst": mst})
    broker.get_quote("005930")
    assert slept == [0.3, 0.3]


def test_non_windows_without_dispatch_gives_clear_error(monkeypatch):
    monkeypatch.setattr("sys.platform", "linux")
    with pytest.raises(BrokerError, match="Windows"):
        DaishinBroker()
