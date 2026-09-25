"""NH투자증권 NHPLUG Open API 국내주식 클라이언트 (나무·QV 계좌 공용 REST).

예전 QV Open API(wmca.dll, Windows 전용)를 대체하는 NH 공식 REST API 다. Windows 포함 어디서나 동작한다.
- 운영: https://api.nhplug.com:8443   모의투자: https://moapi.nhplug.com:8443
- 토큰은 운영 주소에서만 발급 (모의투자도 운영에서 받은 토큰 사용)
- 요청 {"Input_0": {...}}, 응답 Output_0/Output_1 + rsp_cd/rsp_msg
- NH 규약상 rsp_cd 값으로 성공을 판정하지 않는다. 기대한 출력 블록이 왔는지로 판단하고 없으면 rsp_msg 를 보여 준다.
공식 SDK·명세: https://github.com/PLUG-OpenAPI/nhplug-sdk , https://github.com/PLUG-OpenAPI/nhplug-mcp (specs/krstock.openapi.json)
"""

import time
from datetime import datetime
from typing import List

import requests

from . import _token_cache
from .base import Broker, BrokerError, RateLimiter, parse_interval
from ..market import KST, now_kst
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side

BASE_URLS = {"real": "https://api.nhplug.com:8443", "demo": "https://moapi.nhplug.com:8443"}
AUTH_URL = BASE_URLS["real"]
ACCOUNT_TYPES = {"real": ("01", "02"), "demo": ("03",)}  # /n2/acctinfo acct_type


def _num(v, default=0.0) -> float:
    try:
        return abs(float(str(v).replace(",", "").strip())) if str(v or "").strip() else default
    except ValueError:
        return default


class NhBroker(Broker):
    name = "nh"

    def __init__(self, app_key: str, app_secret: str, account: str = "", env: str = "demo",
                 session: requests.Session = None, rate_interval: float = 0.22):
        if env not in BASE_URLS:
            raise ValueError("env 는 demo 또는 real")
        if not app_key or not app_secret:
            raise BrokerError("NH_APP_KEY / NH_APP_SECRET 가 필요합니다 (NHPLUG 포털에서 발급)")
        self.app_key, self.app_secret, self.env = app_key, app_secret, env
        self.base_url = BASE_URLS[env]
        self.session = session or requests.Session()
        self.limiter = RateLimiter(rate_interval)  # 실측 초당 5회
        self._account = account.replace("-", "").strip()
        self._token = None

    # ---- 인증/공통 ---------------------------------------------------------
    def _access_token(self, force: bool = False) -> str:
        if self._token and not force:
            return self._token
        ns = "nh"  # 토큰은 운영에서만 발급되므로 환경 구분 없이 공유
        cached = None if force else _token_cache.load(ns, self.app_key)
        if cached:
            self._token = cached
            return cached
        r = self.session.post(f"{AUTH_URL}/oauth2/token", params={
            "appkey": self.app_key, "appsecretkey": self.app_secret,
            "grant_type": "client_credentials", "scope": "oob",
        }, headers={"content-type": "application/x-www-form-urlencoded"}, timeout=10)
        data = r.json() if r.content else {}
        token = data.get("access_token")
        if not token:
            raise BrokerError(f"NH 토큰 발급 실패: {data.get('rsp_msg') or data.get('error_description') or data or r.status_code}")
        _token_cache.save(ns, self.app_key, token, time.time() + int(data.get("expires_in", 86400)))
        self._token = token
        return token

    def _call(self, path: str, input_0: dict, cts: str = None, cts_flag: str = None):
        """(본문, 응답헤더) 반환. HTTP 오류만 예외로 올리고 업무 판단은 호출한 쪽에서 한다."""
        for attempt in range(2):
            headers = {
                "authorization": f"Bearer {self._access_token(force=attempt == 1)}",
                "x-client-id": self.app_key, "x-client-secret": self.app_secret,
                "content-type": "application/json; charset=UTF-8",
            }
            if cts:
                headers["cts"] = cts
            if cts_flag:
                headers["cts_flag"] = cts_flag
            self.limiter.wait()
            r = self.session.post(self.base_url + path, headers=headers, json={"Input_0": input_0}, timeout=10)
            if r.status_code == 401 and attempt == 0:  # 토큰 무효일 때만 1회 재발급
                continue
            break
        try:
            data = r.json()
        except ValueError:
            raise BrokerError(f"NH 응답 오류 HTTP {r.status_code}: {r.text[:200]}")
        if r.status_code == 429:
            raise BrokerError(f"NH 호출 한도 초과(초당 약 5회): {data.get('rsp_msg', '')}")
        if r.status_code != 200:
            raise BrokerError(f"NH {path} HTTP {r.status_code} [{data.get('rsp_cd')}] {data.get('rsp_msg', '')}")
        return data, r.headers

    @staticmethod
    def _require(data: dict, block: str, what: str):
        value = data.get(block)
        if not value:
            raise BrokerError(f"NH {what} 결과 없음: {str(data.get('rsp_msg', '')).strip() or '응답에 ' + block + ' 없음'}")
        return value

    def _account_no(self) -> str:
        if self._account:
            return self._account
        data, _ = self._call("/n2/acctinfo", {})
        wanted = ACCOUNT_TYPES[self.env]
        rows = [a for a in data.get("Output_0") or [] if str(a.get("acct_type", "")).strip() in wanted]
        if not rows:
            raise BrokerError(f"NH {'모의투자' if self.env == 'demo' else '실전'} 계좌를 찾지 못했습니다 "
                              f"(acct_type {', '.join(wanted)}). NH_ACCOUNT 로 직접 지정할 수 있습니다")
        self._account = str(rows[0]["acct_no"]).strip()
        return self._account

    # ---- 시세 -----------------------------------------------------------
    def get_quote(self, symbol: str) -> Quote:
        data, _ = self._call("/krstock/quote/v1/currentPrice", {"iem_cd": symbol, "market_cd": "KRX"})
        out = self._require(data, "Output_0", "현재가")
        ask = _num(out.get("askp1")) or _num(out.get("askp"))
        bid = _num(out.get("bidp1")) or _num(out.get("bidp"))
        return Quote(symbol, _num(out.get("stck_prpr")), bid or None, ask or None)

    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        minutes = parse_interval(interval)
        body = {
            "market_cd": "KRX", "iem_cd": symbol, "view_main_yn": "Y",
            "edate": now_kst().strftime("%Y%m%d"), "array_cnt": str(min(max(count, 1), 9999)),
            "gubun": "1" if minutes is None else "5", "today_cls_code": "0", "fake_tick": "1",
        }
        if minutes is not None:
            body["xtick"] = str(minutes)
        data, _ = self._call("/krstock/quote/v1/period", body)
        candles = {}
        for r in data.get("Output_1") or []:
            date = str(r.get("bsop_date", "")).strip()
            if not date:
                continue
            if minutes is None:
                t = datetime.strptime(date, "%Y%m%d")
            else:
                t = datetime.strptime(date + str(r.get("bsop_time", "")).strip().rjust(6, "0")[:6], "%Y%m%d%H%M%S")
            t = t.replace(tzinfo=KST)
            candles[t] = Candle(t, _num(r.get("stck_oprc")), _num(r.get("stck_hgpr")), _num(r.get("stck_lwpr")),
                                _num(r.get("stck_prpr")), _num(r.get("vol")))
        if not candles and not data.get("Output_0"):
            raise BrokerError(f"NH 차트 결과 없음: {str(data.get('rsp_msg', '')).strip()}")
        return [candles[k] for k in sorted(candles)][-count:]

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        body = {"act_no": self._account_no(), "bnc_bse_cd": "5", "ltg_aot_dit_cd": "9",
                "aet_bse": "2", "qut_dit_cd": "KRX", "aly_qut_cd": "1"}
        positions, summary, cts, flag = [], {}, None, None
        for _ in range(20):
            data, headers = self._call("/krstock/inquiry/v1/balance", body, cts, flag)
            summary = data.get("Output_0") or summary
            for r in data.get("Output_1") or []:
                qty = int(_num(r.get("itg_bnc_qty")))
                if qty > 0:
                    positions.append(Position(str(r.get("iem_cd", "")).strip().lstrip("A"), qty,
                                              _num(r.get("phs_pr")), str(r.get("iem_nm", "")).strip(),
                                              _num(r.get("now_pr"))))
            next_cts = str(headers.get("cts") or "").strip()
            flag = str(headers.get("cts_flag") or "").strip().upper() or None
            if not next_cts or next_cts == cts or flag == "N":
                break
            cts = next_cts
        if not summary:
            raise BrokerError(f"NH 잔고 결과 없음: {str(data.get('rsp_msg', '')).strip()}")
        cash = _num(summary.get("orr_pbl_amt4"), _num(summary.get("orr_pbl_amt")))  # 100% 증거금 = 현금 주문가능
        return Balance(cash=cash, total_eval=_num(summary.get("tot_aet_amt")), positions=positions)

    # ---- 주문 -----------------------------------------------------------
    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        is_market = order_type == OrderType.MARKET
        try:
            body = {
                "act_no": self._account_no(), "iem_cd": symbol, "orr_qty": int(qty),
                "nmn_pr_tp_cd": "05" if is_market else "01",   # 05 시장가, 01 보통가(지정가)
                "orr_cnd_dit_cd": "00", "ssl_nmn_pr_dit_cd": "00",
                "rmt_mkt_cd": "KRX", "sor_mkt_sli_yn": "N",
            }
            if not is_market:
                body["orr_pr"] = int(price)
            path = "/krstock/order/v1/cashBuy" if side == Side.BUY else "/krstock/order/v1/cashSell"
            data, _ = self._call(path, body)
        except BrokerError as e:
            return OrderResult(False, message=str(e), symbol=symbol, side=side, qty=qty, price=price)
        out = data.get("Output_0") or {}
        order_no = str(out.get("mkt_orr_no", "")).strip()
        msg = str(data.get("rsp_msg", "")).strip()
        if not order_no or not order_no.strip("0"):
            return OrderResult(False, message=msg or "주문번호가 오지 않았습니다", symbol=symbol, side=side,
                               qty=qty, price=price, raw=data)
        return OrderResult(True, order_no, msg, symbol, side, qty, price, raw=data)
