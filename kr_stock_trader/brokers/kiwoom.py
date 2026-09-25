"""키움증권 REST API 국내주식 클라이언트 (2025년 공개된 REST 방식, 영웅문 OCX 불필요).

- 실전: https://api.kiwoom.com
- 모의: https://mockapi.kiwoom.com
문서: https://openapi.kiwoom.com (API ID 기준: ka10001, ka10004, ka10080, ka10081, kt00001, kt00018, kt10000, kt10001)
"""

from datetime import datetime
from typing import List

import requests

from . import _token_cache
from .base import Broker, BrokerError, RateLimiter, parse_interval, resample_minutes
from ..market import KST, now_kst
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side

BASE_URLS = {"real": "https://api.kiwoom.com", "demo": "https://mockapi.kiwoom.com"}
NATIVE_MINUTES = (1, 3, 5, 10, 15, 30, 45, 60)


def _num(v, default=0.0) -> float:
    """키움은 '+70000', '-70000', '000000070000' 같은 문자열로 준다. 가격 부호는 등락 표시라 절댓값."""
    if v in (None, ""):
        return default
    try:
        return abs(float(str(v).replace(",", "")))
    except ValueError:
        return default


def _signed(v, default=0.0) -> float:
    try:
        return float(str(v).replace(",", "")) if v not in (None, "") else default
    except ValueError:
        return default


class KiwoomBroker(Broker):
    name = "kiwoom"

    def __init__(self, app_key: str, secret_key: str, env: str = "demo",
                 session: requests.Session = None, rate_interval: float = 0.25):
        if env not in BASE_URLS:
            raise ValueError("env 는 demo 또는 real")
        if not app_key or not secret_key:
            raise BrokerError("KIWOOM_APP_KEY / KIWOOM_SECRET_KEY 가 필요합니다")
        self.app_key, self.secret_key, self.env = app_key, secret_key, env
        self.base_url = BASE_URLS[env]
        self.session = session or requests.Session()
        self.limiter = RateLimiter(rate_interval)
        self._token = None

    def _access_token(self) -> str:
        if self._token:
            return self._token
        ns = f"kiwoom_{self.env}"
        cached = _token_cache.load(ns, self.app_key)
        if cached:
            self._token = cached
            return cached
        r = self.session.post(f"{self.base_url}/oauth2/token", json={
            "grant_type": "client_credentials", "appkey": self.app_key, "secretkey": self.secret_key,
        }, headers={"content-type": "application/json;charset=UTF-8"}, timeout=10)
        data = r.json() if r.content else {}
        token = data.get("token")
        if not token:
            raise BrokerError(f"키움 토큰 발급 실패: {data.get('return_msg') or data or r.status_code}")
        try:
            expires = datetime.strptime(data["expires_dt"], "%Y%m%d%H%M%S").replace(tzinfo=KST).timestamp()
        except (KeyError, ValueError):
            expires = now_kst().timestamp() + 12 * 3600
        _token_cache.save(ns, self.app_key, token, expires)
        self._token = token
        return token

    def _post(self, path: str, api_id: str, body: dict, cont_yn: str = "N", next_key: str = ""):
        self.limiter.wait()
        headers = {
            "content-type": "application/json;charset=UTF-8",
            "authorization": f"Bearer {self._access_token()}",
            "api-id": api_id, "cont-yn": cont_yn, "next-key": next_key,
        }
        r = self.session.post(self.base_url + path, headers=headers, json=body, timeout=10)
        try:
            data = r.json()
        except ValueError:
            raise BrokerError(f"키움 응답 오류 HTTP {r.status_code}: {r.text[:200]}")
        if str(data.get("return_code", "0")) != "0":
            raise BrokerError(f"키움 {api_id} 실패 [{data.get('return_code')}] {data.get('return_msg', '')}")
        return data, r.headers.get("cont-yn", "N"), r.headers.get("next-key", "")

    # ---- 시세 -----------------------------------------------------------
    def get_quote(self, symbol: str) -> Quote:
        info, _, _ = self._post("/api/dostk/stkinfo", "ka10001", {"stk_cd": symbol})
        price = _num(info.get("cur_prc"))
        bid = ask = None
        try:
            book, _, _ = self._post("/api/dostk/mrkcond", "ka10004", {"stk_cd": symbol})
            ask, bid = _num(book.get("sel_fpr_bid")) or None, _num(book.get("buy_fpr_bid")) or None
        except BrokerError:
            pass
        return Quote(symbol, price, bid, ask)

    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        minutes = parse_interval(interval)
        if minutes is None:
            return self._chart(symbol, "ka10081", {"base_dt": now_kst().strftime("%Y%m%d")},
                               "stk_dt_pole_chart_qry", "dt", "%Y%m%d", count)
        native = minutes if minutes in NATIVE_MINUTES else 1
        candles = self._chart(symbol, "ka10080", {"tic_scope": str(native)},
                              "stk_min_pole_chart_qry", "cntr_tm", "%Y%m%d%H%M%S", count * minutes // native)
        return resample_minutes(candles, minutes if native == 1 else 1)[-count:]

    def _chart(self, symbol, api_id, extra, list_key, time_key, fmt, count):
        body = {"stk_cd": symbol, "upd_stkpc_tp": "1", **extra}
        candles, cont, key = {}, "N", ""
        for _ in range(10):
            data, cont, key = self._post("/api/dostk/chart", api_id, body, cont, key)
            for r in data.get(list_key) or []:
                if not r.get(time_key):
                    continue
                t = datetime.strptime(r[time_key], fmt).replace(tzinfo=KST)
                candles[t] = Candle(t, _num(r.get("open_pric")), _num(r.get("high_pric")),
                                    _num(r.get("low_pric")), _num(r.get("cur_prc")), _num(r.get("trde_qty")))
            if len(candles) >= count or cont != "Y" or not key:
                break
        return [candles[k] for k in sorted(candles)][-count:]

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        dep, _, _ = self._post("/api/dostk/acnt", "kt00001", {"qry_tp": "3"})
        cash = _signed(dep.get("ord_alow_amt"), _signed(dep.get("entr")))
        positions, total, cont, key = [], 0.0, "N", ""
        for _ in range(10):
            data, cont, key = self._post("/api/dostk/acnt", "kt00018",
                                         {"qry_tp": "1", "dmst_stex_tp": "KRX"}, cont, key)
            total = _signed(data.get("tot_evlt_amt"), total)
            for r in data.get("acnt_evlt_remn_indv_tot") or []:
                qty = int(_num(r.get("rmnd_qty")))
                if qty > 0:
                    code = str(r.get("stk_cd", "")).lstrip("A")
                    positions.append(Position(code, qty, _num(r.get("pur_pric")),
                                              r.get("stk_nm", "").strip(), _num(r.get("cur_prc"))))
            if cont != "Y" or not key:
                break
        return Balance(cash=cash, total_eval=total, positions=positions)

    # ---- 주문 -----------------------------------------------------------
    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        is_market = order_type == OrderType.MARKET
        body = {
            "dmst_stex_tp": "KRX", "stk_cd": symbol, "ord_qty": str(int(qty)),
            "ord_uv": "" if is_market else str(int(price)),
            "trde_tp": "3" if is_market else "0", "cond_uv": "",
        }
        api_id = "kt10000" if side == Side.BUY else "kt10001"
        try:
            data, _, _ = self._post("/api/dostk/ordr", api_id, body)
        except BrokerError as e:
            return OrderResult(False, message=str(e), symbol=symbol, side=side, qty=qty, price=price)
        return OrderResult(True, str(data.get("ord_no", "")), data.get("return_msg", ""),
                           symbol, side, qty, price, raw=data)
