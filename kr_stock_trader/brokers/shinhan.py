"""신한투자증권 신한i indi 클라이언트 (Windows 전용).

indi 는 ActiveX 컨트롤(GIEXPERTCONTROL.GiExpertControlCtrl.1)을 PyQt5 로 띄워 쓰는 방식이다.
요청은 SetQueryName → SetSingleData(순번, 값) → RequestData() 로 보내고, 결과는 ReceiveData 이벤트로
돌아오면 GetSingleData(순번) / GetMultiRowCount() / GetMultiData(행, 순번) 으로 읽는다.
실행 조건: Windows + 32비트 Python + PyQt5, 신한i indi 설치 및 API 사용 신청, 관리자 권한.

⚠️ 필드 순번(FIELDS)은 공개 자료로 일부만 확인했다(TR_SCHART 출력 순서, SABA200QB 입력).
   나머지는 indi 프로그램의 TR 도움말과 대조해야 하므로, windows/shinhan_probe.py 로 원시 응답을 확인하고
   다르면 SHINHAN_FIELDS_FILE(JSON)로 덮어쓴다. 확인 전에는 주문이 나가지 않도록
   SHINHAN_ORDER_ENABLED=1 이 있어야만 주문한다.
"""

import json
import os
import sys
from datetime import datetime
from typing import Callable, Dict, List, Optional, Sequence

from .base import Broker, BrokerError, parse_interval
from ..market import KST
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side

PROG_ID = "GIEXPERTCONTROL.GiExpertControlCtrl.1"

# TR 이름과 입출력 순번. 파일로 덮어쓸 수 있다 (SHINHAN_FIELDS_FILE).
FIELDS = {
    "chart": {   # 확인됨: 출력 DATE, TIME, OPEN, HIGH, LOW, CLOSE, 수정주가계수, 수정거래량계수, 락구분, 거래량
        "tr": "TR_SCHART",
        "in": {"code": 0, "kind": 1, "interval": 2, "start": 3, "end": 4, "count": 5},
        "out": {"date": 0, "time": 1, "open": 2, "high": 3, "low": 4, "close": 5, "volume": 9},
    },
    "balance": {  # 입력 확인됨(계좌, 상품구분, 비밀번호). 출력 순번은 확인 필요
        "tr": "SABA200QB",
        "in": {"account": 0, "product": 1, "password": 2},
        "out": {"code": 0, "name": 1, "qty": 2, "avg_price": 6, "price": 5},
    },
    "cash": {     # 확인 필요
        "tr": "SABA655Q1",
        "in": {"account": 0, "product": 1, "password": 2},
        "single": {"orderable": 0},
    },
    "order": {    # 확인 필요
        "tr": "SABA101U1",
        "in": {"account": 0, "product": 1, "password": 2, "side": 5, "code": 6, "qty": 7, "price": 8,
               "session": 9, "price_type": 10, "condition": 11},
        "values": {"buy": "2", "sell": "1", "market": "1", "limit": "2", "regular_session": "1", "no_condition": "0"},
        "single": {"order_no": 0},
    },
}


def load_fields(path: str = None) -> dict:
    fields = json.loads(json.dumps(FIELDS))
    path = path or os.environ.get("SHINHAN_FIELDS_FILE", "")
    if path:
        with open(path, encoding="utf-8") as f:
            for key, override in json.load(f).items():
                for part, value in override.items():
                    if isinstance(value, dict):
                        fields.setdefault(key, {}).setdefault(part, {}).update(value)
                    else:
                        fields.setdefault(key, {})[part] = value
    return fields


class IndiResult:
    def __init__(self, single: Dict[int, str], rows: List[Dict[int, str]]):
        self.single, self.rows = single, rows


class QtIndiSession:
    """PyQt5 로 indi ActiveX 를 띄우고, 비동기 이벤트를 동기 호출처럼 감싼다."""

    def __init__(self, user_id: str = "", password: str = "", cert_password: str = "",
                 starter_path: str = r"C:\SHINHAN-i\indi\GiExpertStarter.exe", timeout: float = 15.0):
        if sys.platform != "win32":
            raise BrokerError("신한 indi 는 Windows 에서만 사용할 수 있습니다")
        try:
            from PyQt5.QAxContainer import QAxWidget
            from PyQt5.QtCore import QEventLoop, QTimer
            from PyQt5.QtWidgets import QApplication
        except ImportError:
            raise BrokerError("PyQt5 가 필요합니다: 32비트 Python 에서 pip install PyQt5")
        self._QEventLoop, self._QTimer = QEventLoop, QTimer
        self.app = QApplication.instance() or QApplication(sys.argv)
        self.ctrl = QAxWidget(PROG_ID)
        self.timeout_ms = int(timeout * 1000)
        self._done: Dict[int, bool] = {}
        self._sys_msgs: List[int] = []
        self._loop = None
        self.ctrl.ReceiveData.connect(self._on_receive)
        self.ctrl.ReceiveSysMsg.connect(self._on_sys_msg)
        if user_id:
            ok = self.ctrl.dynamicCall("StartIndi(QString, QString, QString, QString)",
                                       user_id, password, cert_password, starter_path)
            if not ok:
                raise BrokerError("indi 실행(StartIndi) 실패: 설치 경로(SHINHAN_STARTER)를 확인하세요")
            self._wait(lambda: 3 in self._sys_msgs, 60_000, "indi 로그인")

    def _on_receive(self, rqid):
        self._done[int(rqid)] = True
        if self._loop:
            self._loop.quit()

    def _on_sys_msg(self, msg_id):
        self._sys_msgs.append(int(msg_id))
        if self._loop:
            self._loop.quit()

    def _wait(self, cond: Callable[[], bool], timeout_ms: int, what: str) -> None:
        loop = self._QEventLoop()
        self._loop = loop
        timer = self._QTimer()
        timer.setSingleShot(True)
        timer.timeout.connect(loop.quit)
        timer.start(timeout_ms)
        while not cond() and timer.isActive():
            loop.exec_()
        self._loop = None
        if not cond():
            raise BrokerError(f"{what} 응답 시간 초과")

    def request(self, tr: str, inputs: Dict[int, str], single: Sequence[int] = (),
                multi: Sequence[int] = ()) -> IndiResult:
        c = self.ctrl
        c.dynamicCall("SetQueryName(QString)", tr)
        for idx, value in sorted(inputs.items()):
            c.dynamicCall("SetSingleData(int, QString)", idx, str(value))
        rqid = int(c.dynamicCall("RequestData()"))
        if rqid <= 0:
            raise BrokerError(f"indi {tr} 요청 실패: {c.dynamicCall('GetErrorMessage()')}")
        self._wait(lambda: self._done.pop(rqid, False), self.timeout_ms, f"indi {tr}")
        if c.dynamicCall("GetErrorState()"):
            raise BrokerError(f"indi {tr} 오류 [{c.dynamicCall('GetErrorCode()')}] {c.dynamicCall('GetErrorMessage()')}")
        single_vals = {i: str(c.dynamicCall("GetSingleData(int)", i)).strip() for i in single}
        rows = []
        for r in range(int(c.dynamicCall("GetMultiRowCount()") or 0)):
            rows.append({i: str(c.dynamicCall("GetMultiData(int, int)", r, i)).strip() for i in multi})
        return IndiResult(single_vals, rows)


def _num(v, default=0.0) -> float:
    try:
        return abs(float(str(v).replace(",", "").strip())) if str(v or "").strip() else default
    except ValueError:
        return default


class ShinhanBroker(Broker):
    name = "shinhan"

    def __init__(self, account: str, account_password: str, env: str = "demo", product: str = "01",
                 session=None, fields: dict = None, orders_enabled: Optional[bool] = None):
        if env not in ("demo", "real"):
            raise ValueError("env 는 demo 또는 real")
        if not account or not account_password:
            raise BrokerError("SHINHAN_ACCOUNT / SHINHAN_ACCOUNT_PASSWORD 가 필요합니다")
        self.env = env
        self.account, self.password, self.product = account.replace("-", "").strip(), account_password, product
        self.fields = fields or load_fields()
        self.orders_enabled = (os.environ.get("SHINHAN_ORDER_ENABLED") == "1") if orders_enabled is None else orders_enabled
        self.session = session or QtIndiSession(
            os.environ.get("SHINHAN_ID", ""), os.environ.get("SHINHAN_PASSWORD", ""),
            os.environ.get("SHINHAN_CERT_PASSWORD", ""),
            os.environ.get("SHINHAN_STARTER", r"C:\SHINHAN-i\indi\GiExpertStarter.exe"))

    def _account_inputs(self, spec: dict) -> Dict[int, str]:
        i = spec["in"]
        return {i["account"]: self.account, i["product"]: self.product, i["password"]: self.password}

    # ---- 시세 -----------------------------------------------------------
    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        minutes = parse_interval(interval)
        spec = self.fields["chart"]
        i, o = spec["in"], spec["out"]
        res = self.session.request(spec["tr"], {
            i["code"]: symbol, i["kind"]: "D" if minutes is None else "1",
            i["interval"]: "1" if minutes is None else str(minutes),
            i["start"]: "00000000", i["end"]: "99999999", i["count"]: str(min(max(count, 1), 2000)),
        }, multi=sorted(o.values()))
        candles = {}
        for r in res.rows:
            date = r[o["date"]]
            if not date or not date.isdigit():
                continue
            if minutes is None:
                t = datetime.strptime(date[:8], "%Y%m%d")
            else:
                t = datetime.strptime(date[:8] + r[o["time"]].rjust(6, "0")[:6], "%Y%m%d%H%M%S")
            t = t.replace(tzinfo=KST)
            candles[t] = Candle(t, _num(r[o["open"]]), _num(r[o["high"]]), _num(r[o["low"]]),
                                _num(r[o["close"]]), _num(r[o["volume"]]))
        return [candles[k] for k in sorted(candles)][-count:]

    def get_quote(self, symbol: str) -> Quote:
        """indi 는 확인된 호가 TR 이 없어 1분봉 마지막 종가를 현재가로 쓴다 (스프레드 필터는 생략됨)."""
        candles = self.get_candles(symbol, "1m", 1)
        if not candles:
            raise BrokerError(f"신한 {symbol} 시세 없음")
        return Quote(symbol, candles[-1].close)

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        spec = self.fields["balance"]
        o = spec["out"]
        res = self.session.request(spec["tr"], self._account_inputs(spec), multi=sorted(set(o.values())))
        positions, total = [], 0.0
        for r in res.rows:
            qty = int(_num(r[o["qty"]]))
            if qty > 0:
                price = _num(r[o["price"]])
                positions.append(Position(r[o["code"]].lstrip("A"), qty, _num(r[o["avg_price"]]), r[o["name"]], price))
                total += price * qty
        cash_spec = self.fields["cash"]
        cash_res = self.session.request(cash_spec["tr"], self._account_inputs(cash_spec),
                                        single=sorted(cash_spec["single"].values()))
        cash = _num(cash_res.single.get(cash_spec["single"]["orderable"]))
        return Balance(cash=cash, total_eval=cash + total, positions=positions)

    # ---- 주문 -----------------------------------------------------------
    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        if not self.orders_enabled:
            return OrderResult(False, symbol=symbol, side=side, qty=qty, price=price,
                               message="신한 주문 비활성화: windows/shinhan_probe.py 로 필드 순번을 확인한 뒤 "
                                       "SHINHAN_ORDER_ENABLED=1 로 켜세요")
        spec = self.fields["order"]
        i, v = spec["in"], spec["values"]
        is_market = order_type == OrderType.MARKET
        inputs = self._account_inputs(spec)
        inputs.update({
            i["side"]: v["buy"] if side == Side.BUY else v["sell"],
            i["code"]: symbol, i["qty"]: str(int(qty)), i["price"]: "0" if is_market else str(int(price)),
            i["session"]: v["regular_session"], i["price_type"]: v["market"] if is_market else v["limit"],
            i["condition"]: v["no_condition"],
        })
        try:
            res = self.session.request(spec["tr"], inputs, single=sorted(spec["single"].values()))
        except BrokerError as e:
            return OrderResult(False, message=str(e), symbol=symbol, side=side, qty=qty, price=price)
        order_no = res.single.get(spec["single"]["order_no"], "")
        if not order_no or not order_no.strip("0"):
            return OrderResult(False, message="주문번호가 오지 않았습니다", symbol=symbol, side=side, qty=qty, price=price)
        return OrderResult(True, order_no, "주문 접수", symbol, side, qty, price)
