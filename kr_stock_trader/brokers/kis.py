"""한국투자증권(KIS Developers) Open API 국내주식 클라이언트.

공식 문서/샘플: https://github.com/koreainvestment/open-trading-api
- 실전: https://openapi.koreainvestment.com:9443
- 모의: https://openapivts.koreainvestment.com:29443
"""

import time
from datetime import datetime, timedelta
from typing import List

import requests

from . import _token_cache
from .base import Broker, BrokerError, RateLimiter, parse_interval, resample_minutes
from ..market import KST, now_kst
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side

BASE_URLS = {
    "real": "https://openapi.koreainvestment.com:9443",
    "demo": "https://openapivts.koreainvestment.com:29443",
}

# 현금 매수/매도 주문 TR (2024 신규 TR)
ORDER_TR = {
    ("real", Side.BUY): "TTTC0012U",
    ("real", Side.SELL): "TTTC0011U",
    ("demo", Side.BUY): "VTTC0012U",
    ("demo", Side.SELL): "VTTC0011U",
}
BALANCE_TR = {"real": "TTTC8434R", "demo": "VTTC8434R"}


def _num(v, default=0.0) -> float:
    try:
        return float(str(v).replace(",", "")) if v not in (None, "") else default
    except ValueError:
        return default


class KisBroker(Broker):
    name = "kis"

    def __init__(self, app_key: str, app_secret: str, account: str, env: str = "demo",
                 session: requests.Session = None, rate_interval: float = None):
        if env not in BASE_URLS:
            raise ValueError("env 는 demo 또는 real")
        if not app_key or not app_secret:
            raise BrokerError("KIS_APP_KEY / KIS_APP_SECRET 가 필요합니다")
        cano, _, prdt = account.replace(" ", "").partition("-")
        if len(cano) == 10 and not prdt:
            cano, prdt = cano[:8], cano[8:]
        if len(cano) != 8 or len(prdt) != 2:
            raise BrokerError("KIS_ACCOUNT 는 '12345678-01' 형식이어야 합니다")
        self.app_key, self.app_secret = app_key, app_secret
        self.cano, self.prdt = cano, prdt
        self.env = env
        self.base_url = BASE_URLS[env]
        self.session = session or requests.Session()
        # 모의투자 초당 약 2건, 실전 초당 약 20건 제한
        self.limiter = RateLimiter(rate_interval if rate_interval is not None else (0.55 if env == "demo" else 0.06))
        self._token = None
        self._minute_cache = {}  # symbol → (날짜, {시각: Candle})

    # ---- 인증/공통 ---------------------------------------------------------
    def _access_token(self) -> str:
        if self._token:
            return self._token
        ns = f"kis_{self.env}"
        cached = _token_cache.load(ns, self.app_key)
        if cached:
            self._token = cached
            return cached
        r = self.session.post(f"{self.base_url}/oauth2/tokenP", json={
            "grant_type": "client_credentials", "appkey": self.app_key, "appsecret": self.app_secret,
        }, timeout=10)
        data = r.json() if r.content else {}
        token = data.get("access_token")
        if not token:
            raise BrokerError(f"KIS 토큰 발급 실패: {data.get('error_description') or data or r.status_code}")
        _token_cache.save(ns, self.app_key, token, time.time() + int(data.get("expires_in", 86400)))
        self._token = token
        return token

    def _request(self, method: str, path: str, tr_id: str, params: dict = None,
                 body: dict = None, tr_cont: str = "", _retried: bool = False):
        self.limiter.wait()
        headers = {
            "content-type": "application/json; charset=utf-8",
            "authorization": f"Bearer {self._access_token()}",
            "appkey": self.app_key,
            "appsecret": self.app_secret,
            "tr_id": tr_id,
            "tr_cont": tr_cont,
            "custtype": "P",
        }
        r = self.session.request(method, self.base_url + path, headers=headers,
                                 params=params, json=body, timeout=10)
        try:
            data = r.json()
        except ValueError:
            raise BrokerError(f"KIS 응답 오류 HTTP {r.status_code}: {r.text[:200]}")
        if str(data.get("rt_cd")) != "0":
            if data.get("msg_cd") == "EGW00123" and not _retried:  # 토큰 만료 → 한 번만 재발급 후 재시도
                self._token = None
                _token_cache.save(f"kis_{self.env}", self.app_key, "", 0)
                return self._request(method, path, tr_id, params, body, tr_cont, _retried=True)
            raise BrokerError(f"KIS {tr_id} 실패 [{data.get('msg_cd')}] {data.get('msg1', '').strip()}")
        return data, r.headers.get("tr_cont", "")

    # ---- 시세 -----------------------------------------------------------
    def get_quote(self, symbol: str) -> Quote:
        base = {"FID_COND_MRKT_DIV_CODE": "J", "FID_INPUT_ISCD": symbol}
        price_data, _ = self._request("GET", "/uapi/domestic-stock/v1/quotations/inquire-price",
                                      "FHKST01010100", params=base)
        price = _num(price_data["output"]["stck_prpr"])
        bid = ask = None
        try:
            book, _ = self._request("GET", "/uapi/domestic-stock/v1/quotations/inquire-asking-price-exp-ccn",
                                    "FHKST01010200", params=base)
            out = book.get("output1") or {}
            bid, ask = _num(out.get("bidp1")) or None, _num(out.get("askp1")) or None
        except BrokerError:
            pass  # 호가 조회 실패 시 스프레드 필터만 생략
        return Quote(symbol, price, bid, ask)

    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        minutes = parse_interval(interval)
        if minutes is None:
            return self._daily_candles(symbol, count)
        ones = self._minute_candles(symbol, count * minutes)
        return resample_minutes(ones, minutes)[-count:]

    def _daily_candles(self, symbol: str, count: int) -> List[Candle]:
        rows, end = [], now_kst().date()
        for _ in range(20):
            start = end - timedelta(days=150)  # 1회 최대 100건
            data, _ = self._request("GET", "/uapi/domestic-stock/v1/quotations/inquire-daily-itemchartprice",
                                    "FHKST03010100", params={
                                        "FID_COND_MRKT_DIV_CODE": "J", "FID_INPUT_ISCD": symbol,
                                        "FID_INPUT_DATE_1": start.strftime("%Y%m%d"),
                                        "FID_INPUT_DATE_2": end.strftime("%Y%m%d"),
                                        "FID_PERIOD_DIV_CODE": "D", "FID_ORG_ADJ_PRC": "0",
                                    })
            chunk = [r for r in data.get("output2") or [] if r.get("stck_bsop_date")]
            if not chunk:
                break
            rows.extend(chunk)
            if len(rows) >= count:
                break
            oldest = datetime.strptime(chunk[-1]["stck_bsop_date"], "%Y%m%d").date()
            end = oldest - timedelta(days=1)
        candles = {}
        for r in rows:
            d = datetime.strptime(r["stck_bsop_date"], "%Y%m%d").replace(tzinfo=KST)
            candles[d] = Candle(d, _num(r["stck_oprc"]), _num(r["stck_hgpr"]), _num(r["stck_lwpr"]),
                                _num(r["stck_clpr"]), _num(r.get("acml_vol")))
        return [candles[k] for k in sorted(candles)][-count:]

    def _minute_page(self, symbol: str, cursor: datetime) -> dict:
        """cursor 시각 이전 1분봉 최대 30개."""
        data, _ = self._request("GET", "/uapi/domestic-stock/v1/quotations/inquire-time-itemchartprice",
                                "FHKST03010200", params={
                                    "FID_ETC_CLS_CODE": "", "FID_COND_MRKT_DIV_CODE": "J",
                                    "FID_INPUT_ISCD": symbol,
                                    "FID_INPUT_HOUR_1": cursor.strftime("%H%M%S"),
                                    "FID_PW_DATA_INCU_YN": "N",
                                })
        page = {}
        for r in data.get("output2") or []:
            if not r.get("stck_cntg_hour"):
                continue
            t = datetime.strptime(r["stck_bsop_date"] + r["stck_cntg_hour"], "%Y%m%d%H%M%S").replace(tzinfo=KST)
            page[t] = Candle(t, _num(r["stck_oprc"]), _num(r["stck_hgpr"]), _num(r["stck_lwpr"]),
                             _num(r["stck_prpr"]), _num(r.get("cntg_vol")))
        return page

    def _minute_candles(self, symbol: str, count: int) -> List[Candle]:
        """당일 1분봉. 처음엔 30개씩 과거로 이어 받고, 이후엔 최신 페이지만 받아 캐시에 합친다."""
        now = now_kst()
        cursor = min(now, now.replace(hour=15, minute=30, second=0, microsecond=0))
        opening = now.replace(hour=9, minute=0, second=0, microsecond=0)
        day, candles = self._minute_cache.get(symbol, (None, {}))
        if day != now.date():
            candles = {}

        latest = self._minute_page(symbol, cursor)
        # 캐시와 이어지면 최신 페이지만으로 충분 (이미 받은 과거 봉은 바뀌지 않는다)
        if candles and latest and min(latest) <= max(candles) + timedelta(minutes=1):
            candles.update(latest)
        else:
            candles = dict(latest)
            for _ in range(14):
                if not candles or len(candles) >= count:
                    break
                cursor = min(candles) - timedelta(minutes=1)
                if cursor < opening:
                    break
                page = self._minute_page(symbol, cursor)
                if not page:
                    break
                candles.update(page)
        self._minute_cache[symbol] = (now.date(), candles)
        return [candles[k] for k in sorted(candles)][-count:]

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        positions, summary = [], {}
        fk = nk = tr_cont = ""
        for _ in range(10):
            data, next_cont = self._request("GET", "/uapi/domestic-stock/v1/trading/inquire-balance",
                                            BALANCE_TR[self.env], tr_cont=tr_cont, params={
                                                "CANO": self.cano, "ACNT_PRDT_CD": self.prdt,
                                                "AFHR_FLPR_YN": "N", "OFL_YN": "", "INQR_DVSN": "02",
                                                "UNPR_DVSN": "01", "FUND_STTL_ICLD_YN": "N",
                                                "FNCG_AMT_AUTO_RDPT_YN": "N", "PRCS_DVSN": "00",
                                                "CTX_AREA_FK100": fk, "CTX_AREA_NK100": nk,
                                            })
            for r in data.get("output1") or []:
                qty = int(_num(r.get("hldg_qty")))
                if qty > 0:
                    positions.append(Position(r["pdno"], qty, _num(r.get("pchs_avg_pric")),
                                              r.get("prdt_name", ""), _num(r.get("prpr"))))
            out2 = data.get("output2") or []
            if out2:
                summary = out2[0] if isinstance(out2, list) else out2
            if next_cont not in ("F", "M"):
                break
            fk, nk, tr_cont = data.get("ctx_area_fk100", ""), data.get("ctx_area_nk100", ""), "N"
        # D+2 예수금이 실제 주문가능 현금에 가깝다
        cash = _num(summary.get("prvs_rcdl_excc_amt"), _num(summary.get("dnca_tot_amt")))
        return Balance(cash=cash, total_eval=_num(summary.get("tot_evlu_amt")), positions=positions)

    # ---- 주문 -----------------------------------------------------------
    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        is_market = order_type == OrderType.MARKET
        body = {
            "CANO": self.cano, "ACNT_PRDT_CD": self.prdt, "PDNO": symbol,
            "ORD_DVSN": "01" if is_market else "00",
            "ORD_QTY": str(int(qty)),
            "ORD_UNPR": "0" if is_market else str(int(price)),
            "EXCG_ID_DVSN_CD": "KRX",
            "SLL_TYPE": "01" if side == Side.SELL else "",
            "CNDT_PRIC": "",
        }
        try:
            data, _ = self._request("POST", "/uapi/domestic-stock/v1/trading/order-cash",
                                    ORDER_TR[(self.env, side)], body=body)
        except BrokerError as e:
            return OrderResult(False, message=str(e), symbol=symbol, side=side, qty=qty, price=price)
        out = data.get("output") or {}
        return OrderResult(True, out.get("ODNO", ""), data.get("msg1", "").strip(),
                           symbol, side, qty, price, raw=data)
