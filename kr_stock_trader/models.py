from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional


class Side(str, Enum):
    BUY = "buy"
    SELL = "sell"


class OrderType(str, Enum):
    LIMIT = "limit"    # 지정가
    MARKET = "market"  # 시장가


@dataclass
class Candle:
    time: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float = 0.0


@dataclass
class Quote:
    symbol: str
    price: float
    bid: Optional[float] = None  # 매수 1호가
    ask: Optional[float] = None  # 매도 1호가

    @property
    def spread_pct(self) -> Optional[float]:
        if not self.bid or not self.ask or self.bid <= 0:
            return None
        return (self.ask - self.bid) / self.bid * 100.0


@dataclass
class Position:
    symbol: str
    qty: int
    avg_price: float
    name: str = ""
    current_price: float = 0.0

    @property
    def unrealized_pnl(self) -> float:
        return (self.current_price - self.avg_price) * self.qty


@dataclass
class Balance:
    cash: float                 # 주문가능현금 (없으면 예수금)
    total_eval: float = 0.0     # 총평가금액
    positions: list = field(default_factory=list)


@dataclass
class OrderResult:
    ok: bool
    order_id: str = ""
    message: str = ""
    symbol: str = ""
    side: Optional[Side] = None
    qty: int = 0
    price: float = 0.0
    raw: Optional[dict] = None
