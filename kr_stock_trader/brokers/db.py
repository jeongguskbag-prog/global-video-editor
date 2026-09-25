"""DB증권(구 DB금융투자) Open API 국내주식 클라이언트.

- REST: https://openapi.dbsec.co.kr:8443 (실전·모의 같은 주소, 모의투자용 App Key 로 구분)
- 모든 요청 POST, 바디 {"In": {...}}, 응답 {"Out": ..., "rsp_cd": "00000"}; 계좌는 토큰(App Key)에 묶여 있음
공식 샘플: https://github.com/DBsecurities/dbsec-open-api
"""

import time
from datetime import datetime, timedelta
from typing import List

import requests

from . import _token_cache
from .base import Broker, BrokerError, RateLimiter, parse_interval
from ..market import KST, now_kst
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side

BASE_URL = "https://openapi.dbsec.co.kr:8443"
TOKEN_ERRORS = {"IGW00121", "IGW00122", "IGW00123"}


def _num(v, default=0.0) -> float:
    try:
        return abs(float(str(v).replace(",", ""))) if v not in (None, "") else default
    except ValueError:
        return default


class DbBroker(Broker):
    name = "db"

    def __init__(self, app_key: str, app_secret: str, env: str = "demo",
                 session: requests.Session = None, rate_interval: float = 0.55):
        if env not in ("demo", "real"):
            raise ValueError("env 는 demo 또는 real")
        if not app_key or not app_secret:
            raise BrokerError("DB_APP_KEY / DB_APP_SECRET 가 필요합니다 (모의투자는 모의투자용 키)")
        self.app_key, self.app_secret, self.env = app_key, app_secret, env
        self.base_url = BASE_URL
        self.session = session or requests.Session()
        self.limiter = RateLimiter(rate_interval)  # 잔고조회 2 TPS, 예수금 1 TPS 기준
        self._token = None

    def _access_token(self) -> str:
        if self._token:
            return self._token
        ns = f"db_{self.env}"
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
            raise BrokerError(f"DB 토큰 발급 실패: {data.get('rsp_msg') or data.get('error_description') or data or r.status_code}")
        _token_cache.save(ns, self.app_key, token, time.time() + int(data.get("expires_in", 86400) or 86400))
        self._token = token
        return token

    def _call(self, path: str, in_block: dict, cont_yn: str = "N", cont_key: str = "", _retried: bool = False):
        self.limiter.wait()
        headers = {
            "content-type": "application/json; charset=utf-8",
            "authorization": f"Bearer {self._access_token()}",
            "cont_yn": cont_yn, "cont_key": cont_key,
        }
        r = self.session.post(self.base_url + path, headers=headers, json={"In": in_block}, timeout=10)
        try:
            data = r.json()
        except ValueError:
            raise BrokerError(f"DB 응답 오류 HTTP {r.status_code}: {r.text[:200]}")
        code = str(data.get("rsp_cd", "")).strip()
        if code in TOKEN_ERRORS and not _retried:
            self._token = None
            _token_cache.save(f"db_{self.env}", self.app_key, "", 0)
            return self._call(path, in_block, cont_yn, cont_key, _retried=True)
        if code and not (code.isdigit() and code.startswith("0") and int(code) < 1000):
            raise BrokerError(f"DB {path.rsplit('/', 1)[-1]} 실패 [{code}] {str(data.get('rsp_msg', '')).strip()}")
        return data, r.headers.get("cont_yn", "N"), r.headers.get("cont_key", "")

    # ---- 시세 -----------------------------------------------------------
    def get_quote(self, symbol: str) -> Quote:
        data, _, _ = self._call("/api/v1/quote/kr-stock/inquiry/price",
                                {"InputIscd1": symbol, "InputCondMrktDivCode": "J"})
        out = data.get("Out") or {}
        return Quote(symbol, _num(out.get("Prpr")), _num(out.get("Bidp1")) or None, _num(out.get("Askp1")) or None)

    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        minutes = parse_interval(interval)
        today = now_kst()
        if minutes is None:
            start = today - timedelta(days=int(count * 1.6) + 10)
            data, _, _ = self._call("/api/v1/quote/kr-chart/day", {
                "InputOrgAdjPrc": "1", "InputCondMrktDivCode": "J", "InputIscd1": symbol,
                "InputDate1": start.strftime("%Y%m%d"), "InputDate2": today.strftime("%Y%m%d"),
            })
        else:
            data, _, _ = self._call("/api/v1/quote/kr-chart/min", {
                "dataCnt": str(min(max(count, 1), 2000)), "InputCondMrktDivCode": "J", "InputIscd1": symbol,
                "InputDate1": today.strftime("%Y%m%d"), "InputDivXtick": str(60 * minutes),
                "InputOrgAdjPrc": "1",
            })
        candles = {}
        for r in data.get("Out") or []:
            date = str(r.get("Date", "")).strip()
            if not date:
                continue
            hour = str(r.get("Hour", "")).strip().ljust(6, "0")[:6]
            t = datetime.strptime(date + (hour if minutes else ""), "%Y%m%d%H%M%S" if minutes else "%Y%m%d")
            t = t.replace(tzinfo=KST)
            candles[t] = Candle(t, _num(r.get("Oprc")), _num(r.get("Hprc")), _num(r.get("Lprc")),
                                _num(r.get("Prpr")), _num(r.get("CntgVol")))
        return [candles[k] for k in sorted(candles)][-count:]

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        dep, _, _ = self._call("/api/v1/trading/kr-stock/inquiry/acnt-deposit", {})
        d = dep.get("Out1") or {}
        cash = _num(d.get("PrsmptDpsD2"), _num(d.get("DpsBalAmt")))

        positions, total, cont, key = [], 0.0, "N", ""
        for _ in range(10):
            data, cont, key = self._call("/api/v1/trading/kr-stock/inquiry/balance",
                                         {"QryTpCode0": "0"}, cont, key)
            head = data.get("Out") or {}
            total = _num(head.get("DpsastAmt"), total)
            for r in data.get("Out1") or []:
                qty = int(_num(r.get("BalQty0"), _num(r.get("BalQty"))))
                if qty > 0:
                    avg = _num(r.get("ExecPrc")) or _num(r.get("PchsAmt")) / qty
                    positions.append(Position(str(r.get("IsuNo", "")).strip().lstrip("A"), qty, avg,
                                              str(r.get("IsuNm", "")).strip(), _num(r.get("NowPrc"))))
            if cont != "Y" or not key:
                break
        return Balance(cash=cash, total_eval=total, positions=positions)

    # ---- 주문 -----------------------------------------------------------
    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        is_market = order_type == OrderType.MARKET
        block = {
            "IsuNo": "A" + symbol, "OrdQty": int(qty), "OrdPrc": 0 if is_market else int(price),
            "BnsTpCode": "2" if side == Side.BUY else "1",
            "OrdprcPtnCode": "03" if is_market else "00",
            "MgntrnCode": "000", "LoanDt": "00000000", "OrdCndiTpCode": "0", "TrchNo": 1,
        }
        try:
            data, _, _ = self._call("/api/v1/trading/kr-stock/order", block)
        except BrokerError as e:
            return OrderResult(False, message=str(e), symbol=symbol, side=side, qty=qty, price=price)
        order_no = str((data.get("Out") or {}).get("OrdNo", "")).strip()
        if not order_no or order_no == "0":
            return OrderResult(False, message=str(data.get("rsp_msg", "주문번호 없음")).strip(),
                               symbol=symbol, side=side, qty=qty, price=price, raw=data)
        return OrderResult(True, order_no, str(data.get("rsp_msg", "")).strip(), symbol, side, qty, price, raw=data)
