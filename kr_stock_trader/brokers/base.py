import time
from abc import ABC, abstractmethod
from typing import List, Optional

from ..models import Balance, Candle, OrderResult, OrderType, Quote, Side


class BrokerError(RuntimeError):
    pass


def parse_interval(interval: str) -> Optional[int]:
    """'D' → None(일봉), '5m' → 5(분봉)."""
    interval = interval.strip()
    if interval.upper() == "D":
        return None
    if interval.endswith("m") and interval[:-1].isdigit() and int(interval[:-1]) > 0:
        return int(interval[:-1])
    raise ValueError(f"지원하지 않는 봉 간격: {interval} (D 또는 1m, 5m ...)")


def resample_minutes(candles: List[Candle], minutes: int) -> List[Candle]:
    """1분봉(오래된→최신)을 N분봉으로 묶는다. 09:00 기준으로 구간을 나눈다."""
    if minutes <= 1:
        return candles
    out: List[Candle] = []
    bucket_key = None
    for c in candles:
        since_open = (c.time.hour * 60 + c.time.minute) - 9 * 60
        key = (c.time.date(), since_open // minutes)
        if key != bucket_key:
            bucket_key = key
            out.append(Candle(c.time, c.open, c.high, c.low, c.close, c.volume))
        else:
            b = out[-1]
            b.high, b.low = max(b.high, c.high), min(b.low, c.low)
            b.close = c.close
            b.volume += c.volume
    return out


class Broker(ABC):
    name = "base"
    env = "demo"

    @abstractmethod
    def get_quote(self, symbol: str) -> Quote: ...

    @abstractmethod
    def get_candles(self, symbol: str, interval: str = "D", count: int = 100) -> List[Candle]:
        """오래된 → 최신 순서로 반환."""

    @abstractmethod
    def get_balance(self) -> Balance: ...

    @abstractmethod
    def place_order(self, symbol: str, side: Side, qty: int,
                    order_type: OrderType = OrderType.MARKET, price: float = 0) -> OrderResult: ...


class RateLimiter:
    """초당 호출 수 제한 (모의투자 서버는 특히 엄격하다)."""

    def __init__(self, min_interval: float):
        self.min_interval = min_interval
        self._last = 0.0

    def wait(self) -> None:
        delta = time.monotonic() - self._last
        if delta < self.min_interval:
            time.sleep(self.min_interval - delta)
        self._last = time.monotonic()
