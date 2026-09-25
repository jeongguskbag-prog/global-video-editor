"""대신증권 CYBOS Plus 클라이언트 (Windows 전용).

REST 가 아니라 CYBOS Plus 가 설치한 COM 객체를 win32com 으로 호출한다. 실행 조건:
- Windows + 32비트 Python + pywin32 (`pip install pywin32`)
- CYBOS Plus(또는 CYBOS 5)가 켜져 있고 로그인된 상태 (모의투자는 로그인 창에서 '모의투자 접속')
- Python(명령 프롬프트)을 '관리자 권한으로 실행'
사용 객체: CpUtil.CpCybos, CpTrade.CpTdUtil, DsCbo1.StockMst, CpSysDib.StockChart,
           CpTrade.CpTd6033(잔고), CpTrade.CpTdNew5331A(주문가능금액), CpTrade.CpTd0311(현금주문)
"""

import sys
import time
from datetime import datetime
from typing import Callable, List

from .base import Broker, BrokerError, parse_interval
from ..market import KST
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side

LT_TRADE_REQUEST, LT_NONTRADE_REQUEST = 0, 1  # CpCybos.GetLimitRemainCount 인자
CHART_FIELDS = (0, 1, 2, 3, 4, 5, 8)          # 날짜, 시간, 시가, 고가, 저가, 종가, 거래량 (응답은 이 순서로 0..6)


def _default_dispatch() -> Callable[[str], object]:
    if sys.platform != "win32":
        raise BrokerError("대신증권(CYBOS Plus)은 Windows 에서만 사용할 수 있습니다")
    try:
        import pythoncom
        import win32com.client
    except ImportError:
        raise BrokerError("pywin32 가 필요합니다: 32비트 Python 에서 pip install pywin32")
    pythoncom.CoInitialize()
    return win32com.client.Dispatch


def _code(symbol: str) -> str:
    return symbol if symbol.startswith("A") else "A" + symbol


class DaishinBroker(Broker):
    name = "daishin"

    def __init__(self, account: str = "", env: str = "demo", dispatch: Callable[[str], object] = None,
                 sleep: Callable[[float], None] = time.sleep):
        if env not in ("demo", "real"):
            raise ValueError("env 는 demo 또는 real")
        self.env = env
        self._dispatch = dispatch or _default_dispatch()
        self._sleep = sleep
        self._objects = {}
        self.cybos = self._obj("CpUtil.CpCybos")
        if self.cybos.IsConnect != 1:
            raise BrokerError("CYBOS Plus 가 연결되어 있지 않습니다. CYBOS Plus 를 실행해 로그인한 뒤 다시 시도하세요")
        self._account = account.replace("-", "").strip()
        self._goods = None
        self._trade_ready = False

    def _obj(self, prog_id: str):
        if prog_id not in self._objects:
            self._objects[prog_id] = self._dispatch(prog_id)
        return self._objects[prog_id]

    # ---- 공통 -----------------------------------------------------------
    def _wait_limit(self, kind: int) -> None:
        """조회 15초 60건 / 주문 15초 20건 제한. 남은 횟수가 없으면 풀릴 때까지 기다린다."""
        for _ in range(100):
            if self.cybos.GetLimitRemainCount(kind) > 0:
                return
            self._sleep(max(self.cybos.LimitRequestRemainTime, 100) / 1000.0)

    def _request(self, obj, kind: int = LT_NONTRADE_REQUEST, label: str = "") -> None:
        self._wait_limit(kind)
        obj.BlockRequest()
        status = obj.GetDibStatus()
        if status != 0:
            raise BrokerError(f"대신 {label} 실패 [{status}] {str(obj.GetDibMsg1()).strip()}")

    def _init_trade(self) -> None:
        """주문/계좌 조회 전 1회: 주문 비밀번호 확인(TradeInit) + 계좌·상품구분 결정."""
        if self._trade_ready:
            return
        util = self._obj("CpTrade.CpTdUtil")
        if util.TradeInit(0) != 0:
            raise BrokerError("CYBOS 주문 초기화 실패 (계좌 비밀번호 확인 창에서 비밀번호를 저장했는지 확인하세요)")
        accounts = [str(a) for a in util.AccountNumber]
        if not accounts:
            raise BrokerError("CYBOS 에 등록된 계좌가 없습니다")
        if self._account and self._account not in accounts:
            raise BrokerError(f"DAISHIN_ACCOUNT {self._account} 가 로그인한 계좌 목록({', '.join(accounts)})에 없습니다")
        self._account = self._account or accounts[0]
        goods = util.GoodsList(self._account, 1)  # 1: 주식
        if not goods:
            raise BrokerError(f"계좌 {self._account} 에 주식 상품이 없습니다")
        self._goods = goods[0]
        self._trade_ready = True

    # ---- 시세 -----------------------------------------------------------
    def get_quote(self, symbol: str) -> Quote:
        mst = self._obj("DsCbo1.StockMst")
        mst.SetInputValue(0, _code(symbol))
        self._request(mst, label="현재가")
        price = float(mst.GetHeaderValue(11))
        ask, bid = float(mst.GetHeaderValue(16)), float(mst.GetHeaderValue(17))
        return Quote(symbol, price, bid or None, ask or None)

    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        minutes = parse_interval(interval)
        chart = self._obj("CpSysDib.StockChart")
        chart.SetInputValue(0, _code(symbol))
        chart.SetInputValue(1, ord("2"))              # 개수로 요청
        chart.SetInputValue(4, min(max(count, 1), 2000))
        chart.SetInputValue(5, CHART_FIELDS)
        chart.SetInputValue(6, ord("D") if minutes is None else ord("m"))
        if minutes is not None:
            chart.SetInputValue(7, minutes)          # 분 주기
        chart.SetInputValue(9, ord("1"))              # 수정주가
        self._request(chart, label="차트")
        candles = {}
        for i in range(int(chart.GetHeaderValue(3))):  # 최신 → 과거 순서로 온다
            date = str(int(chart.GetDataValue(0, i)))
            if minutes is None:
                t = datetime.strptime(date, "%Y%m%d")
            else:
                hhmm = int(chart.GetDataValue(1, i))
                t = datetime.strptime(f"{date}{hhmm:04d}", "%Y%m%d%H%M")
            t = t.replace(tzinfo=KST)
            candles[t] = Candle(t, float(chart.GetDataValue(2, i)), float(chart.GetDataValue(3, i)),
                                float(chart.GetDataValue(4, i)), float(chart.GetDataValue(5, i)),
                                float(chart.GetDataValue(6, i)))
        return [candles[k] for k in sorted(candles)][-count:]

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        self._init_trade()
        cash_obj = self._obj("CpTrade.CpTdNew5331A")
        cash_obj.SetInputValue(0, self._account)
        cash_obj.SetInputValue(1, self._goods)
        self._request(cash_obj, label="주문가능금액")
        cash = float(cash_obj.GetHeaderValue(10))    # 증거금 100% 주문가능금액

        bal = self._obj("CpTrade.CpTd6033")
        bal.SetInputValue(0, self._account)
        bal.SetInputValue(1, self._goods)
        bal.SetInputValue(2, 50)
        self._request(bal, label="잔고")
        total = float(bal.GetHeaderValue(3))         # 총평가금액
        positions = []
        for _ in range(20):
            for i in range(int(bal.GetHeaderValue(7))):  # 수신 개수
                qty = int(bal.GetDataValue(7, i))         # 체결잔고수량
                if qty <= 0:
                    continue
                eval_amt = float(bal.GetDataValue(9, i))  # 평가금액
                positions.append(Position(str(bal.GetDataValue(12, i)).lstrip("A"), qty,
                                          float(bal.GetDataValue(17, i)),   # 체결장부단가
                                          str(bal.GetDataValue(0, i)).strip(), eval_amt / qty))
            if not bal.Continue:
                break
            self._request(bal, label="잔고(연속)")
        return Balance(cash=cash, total_eval=total, positions=positions)

    # ---- 주문 -----------------------------------------------------------
    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        try:
            self._init_trade()
            order = self._obj("CpTrade.CpTd0311")
            is_market = order_type == OrderType.MARKET
            order.SetInputValue(0, "2" if side == Side.BUY else "1")  # 1 매도, 2 매수
            order.SetInputValue(1, self._account)
            order.SetInputValue(2, self._goods)
            order.SetInputValue(3, _code(symbol))
            order.SetInputValue(4, int(qty))
            order.SetInputValue(5, 0 if is_market else int(price))
            order.SetInputValue(7, "0")                                # 주문조건 없음
            order.SetInputValue(8, "03" if is_market else "01")        # 03 시장가, 01 보통(지정가)
            self._request(order, LT_TRADE_REQUEST, "주문")
        except BrokerError as e:
            return OrderResult(False, message=str(e), symbol=symbol, side=side, qty=qty, price=price)
        return OrderResult(True, str(order.GetHeaderValue(8)), str(order.GetDibMsg1()).strip(),
                           symbol, side, qty, price)
