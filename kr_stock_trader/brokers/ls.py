"""LS증권(구 이베스트) Open API 국내주식 클라이언트.

- REST: https://openapi.ls-sec.co.kr:8080 (실전·모의 같은 주소, 모의투자용 App Key 로 구분)
- 모든 TR 은 POST, 헤더 tr_cd 로 TR 지정, 바디 {"<TR>InBlock": {...}}, 응답 "<TR>OutBlock"
- 사용 TR: t1101(호가), t8410(일봉), t8412(분봉), t0424(잔고), CSPAQ12200(주문가능금액), CSPAT00601(현물주문)
참고: https://openapi.ls-sec.co.kr/apiservice , https://github.com/teranum/ls-openapi-samples
"""

import time
from datetime import datetime
from typing import List

import requests

from . import _token_cache
from .base import Broker, BrokerError, RateLimiter, parse_interval
from ..market import KST
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side

BASE_URL = "https://openapi.ls-sec.co.kr:8080"
PATH_MARKET, PATH_CHART = "/stock/market-data", "/stock/chart"
PATH_ACCOUNT, PATH_ORDER = "/stock/accno", "/stock/order"
# 차트 TR 은 초당 1건 제한
CHART_TRS = {"t8410", "t8412"}


def _num(v, default=0.0) -> float:
    try:
        return float(str(v).replace(",", "")) if v not in (None, "") else default
    except ValueError:
        return default


def _ok_code(code: str) -> bool:
    """LS 는 '00000' 외에 '00039'(매도주문 완료), '00040'(매수주문 완료) 같은 0으로 시작하는 정상 코드를 준다."""
    code = str(code or "").strip()
    return code == "" or (code.isdigit() and code.startswith("0") and int(code) < 1000)


class LsBroker(Broker):
    name = "ls"

    def __init__(self, app_key: str, app_secret: str, env: str = "demo",
                 session: requests.Session = None, rate_interval: float = 0.35, chart_interval: float = 1.05):
        if env not in ("demo", "real"):
            raise ValueError("env 는 demo 또는 real")
        if not app_key or not app_secret:
            raise BrokerError("LS_APP_KEY / LS_APP_SECRET 가 필요합니다 (모의투자는 모의투자용 키)")
        self.app_key, self.app_secret, self.env = app_key, app_secret, env
        self.base_url = BASE_URL
        self.session = session or requests.Session()
        self.limiter = RateLimiter(rate_interval)
        self.chart_limiter = RateLimiter(chart_interval)
        self._token = None

    def _access_token(self) -> str:
        if self._token:
            return self._token
        ns = f"ls_{self.env}"
        cached = _token_cache.load(ns, self.app_key)
        if cached:
            self._token = cached
            return cached
        r = self.session.post(f"{self.base_url}/oauth2/token", data={
            "grant_type": "client_credentials", "appkey": self.app_key,
            "appsecretkey": self.app_secret, "scope": "oob",
        }, headers={"content-type": "application/x-www-form-urlencoded"}, timeout=10)
        data = r.json() if r.content else {}
        token = data.get("access_token")
        if not token:
            raise BrokerError(f"LS 토큰 발급 실패: {data.get('error_description') or data.get('rsp_msg') or data or r.status_code}")
        _token_cache.save(ns, self.app_key, token, time.time() + int(data.get("expires_in", 86400)))
        self._token = token
        return token

    def _call(self, path: str, tr_cd: str, in_block: dict, block_name: str = None,
              tr_cont: str = "N", tr_cont_key: str = "", _retried: bool = False):
        (self.chart_limiter if tr_cd in CHART_TRS else self.limiter).wait()
        headers = {
            "content-type": "application/json; charset=utf-8",
            "authorization": f"Bearer {self._access_token()}",
            "tr_cd": tr_cd, "tr_cont": tr_cont, "tr_cont_key": tr_cont_key,
        }
        body = {block_name or f"{tr_cd}InBlock": in_block}
        r = self.session.post(self.base_url + path, headers=headers, json=body, timeout=10)
        try:
            data = r.json()
        except ValueError:
            raise BrokerError(f"LS 응답 오류 HTTP {r.status_code}: {r.text[:200]}")
        code = str(data.get("rsp_cd", "")).strip()
        if not _ok_code(code):
            if code.startswith("IGW") and "token" in str(data.get("rsp_msg", "")).lower() and not _retried:
                self._token = None
                _token_cache.save(f"ls_{self.env}", self.app_key, "", 0)
                return self._call(path, tr_cd, in_block, block_name, tr_cont, tr_cont_key, _retried=True)
            raise BrokerError(f"LS {tr_cd} 실패 [{code}] {str(data.get('rsp_msg', '')).strip()}")
        return data, r.headers.get("tr_cont", "N"), r.headers.get("tr_cont_key", "")

    # ---- 시세 -----------------------------------------------------------
    def get_quote(self, symbol: str) -> Quote:
        data, _, _ = self._call(PATH_MARKET, "t1101", {"shcode": symbol})
        out = data.get("t1101OutBlock") or {}
        return Quote(symbol, _num(out.get("price")),
                     _num(out.get("bidho1")) or None, _num(out.get("offerho1")) or None)

    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        minutes = parse_interval(interval)
        if minutes is None:
            tr, block = "t8410", {"shcode": symbol, "gubun": "2", "sdate": "", "edate": "99999999",
                                  "cts_date": "", "comp_yn": "N", "sujung": "Y"}
        else:
            tr, block = "t8412", {"shcode": symbol, "ncnt": minutes, "nday": "0", "sdate": "",
                                  "stime": "", "edate": "99999999", "etime": "", "cts_date": "",
                                  "cts_time": "", "comp_yn": "N"}
        candles, cont, key = {}, "N", ""
        for _ in range(10):
            block["qrycnt"] = min(500, max(count - len(candles), 1))
            data, cont, key = self._call(PATH_CHART, tr, block, tr_cont=cont, tr_cont_key=key)
            for r in data.get(f"{tr}OutBlock1") or []:
                stamp = r.get("date", "") + (r.get("time", "")[:6] if minutes else "")
                if not r.get("date"):
                    continue
                t = datetime.strptime(stamp, "%Y%m%d%H%M%S" if minutes else "%Y%m%d").replace(tzinfo=KST)
                candles[t] = Candle(t, _num(r.get("open")), _num(r.get("high")), _num(r.get("low")),
                                    _num(r.get("close")), _num(r.get("jdiff_vol")))
            head = data.get(f"{tr}OutBlock") or {}
            if len(candles) >= count or cont != "Y" or not head.get("cts_date"):
                break
            block["cts_date"] = head.get("cts_date", "")
            if minutes:
                block["cts_time"] = head.get("cts_time", "")
        return [candles[k] for k in sorted(candles)][-count:]

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        cash_data, _, _ = self._call(PATH_ACCOUNT, "CSPAQ12200", {"BalCreTp": "0"}, "CSPAQ12200InBlock1")
        out2 = cash_data.get("CSPAQ12200OutBlock2") or {}
        cash = _num(out2.get("MnyOrdAbleAmt"), _num(out2.get("D2Dps")))

        positions, total, cursor = [], 0.0, ""
        cont, key = "N", ""
        for _ in range(10):
            data, cont, key = self._call(PATH_ACCOUNT, "t0424", {
                "prcgb": "1", "chegb": "2", "dangb": "0", "charge": "1", "cts_expcode": cursor,
            }, tr_cont=cont, tr_cont_key=key)
            head = data.get("t0424OutBlock") or {}
            total = _num(head.get("sunamt"), total)
            for r in data.get("t0424OutBlock1") or []:
                qty = int(_num(r.get("janqty")))
                if qty > 0:
                    positions.append(Position(str(r.get("expcode", "")).lstrip("A"), qty, _num(r.get("pamt")),
                                              str(r.get("hname", "")).strip(), _num(r.get("price"))))
            cursor = str(head.get("cts_expcode", "")).strip()
            if cont != "Y" or not cursor:
                break
        return Balance(cash=cash, total_eval=total, positions=positions)

    # ---- 주문 -----------------------------------------------------------
    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        is_market = order_type == OrderType.MARKET
        block = {
            "IsuNo": "A" + symbol,  # 모의투자는 반드시 A+종목코드, 실전도 허용
            "OrdQty": int(qty),
            "OrdPrc": 0 if is_market else float(int(price)),
            "BnsTpCode": "2" if side == Side.BUY else "1",
            "OrdprcPtnCode": "03" if is_market else "00",
            "MgntrnCode": "000", "LoanDt": "", "OrdCndiTpCode": "0",
        }
        try:
            data, _, _ = self._call(PATH_ORDER, "CSPAT00601", block, "CSPAT00601InBlock1")
        except BrokerError as e:
            return OrderResult(False, message=str(e), symbol=symbol, side=side, qty=qty, price=price)
        order_no = str((data.get("CSPAT00601OutBlock2") or {}).get("OrdNo", "")).strip()
        if not order_no or order_no == "0":
            return OrderResult(False, message=str(data.get("rsp_msg", "주문번호 없음")).strip(),
                               symbol=symbol, side=side, qty=qty, price=price, raw=data)
        return OrderResult(True, order_no, str(data.get("rsp_msg", "")).strip(), symbol, side, qty, price, raw=data)
