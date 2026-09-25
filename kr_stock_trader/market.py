"""KRX 시장 규칙: 호가단위, 운영시간, 거래비용."""

from datetime import datetime, time, timedelta, timezone
from math import floor, ceil

KST = timezone(timedelta(hours=9))

# 2023-01-25 이후 코스피/코스닥 공통 호가가격단위 (상한 미만, 단위)
_TICK_TABLE = [
    (2_000, 1),
    (5_000, 5),
    (20_000, 10),
    (50_000, 50),
    (200_000, 100),
    (500_000, 500),
]

REGULAR_OPEN = time(9, 0)
REGULAR_CLOSE = time(15, 30)


def tick_size(price: float) -> int:
    for upper, tick in _TICK_TABLE:
        if price < upper:
            return tick
    return 1_000


def round_to_tick(price: float, direction: str = "nearest") -> int:
    """가격을 호가단위에 맞춘다. direction: 'down' | 'up' | 'nearest'."""
    if price <= 0:
        return 0
    tick = tick_size(price)
    units = price / tick
    if direction == "down":
        n = floor(units + 1e-9)
    elif direction == "up":
        n = ceil(units - 1e-9)
    else:
        n = round(units)
    result = int(n * tick)
    # 경계값(예: 1,999→2,000)에서 단위가 바뀌면 한 번 더 맞춘다
    if tick_size(result) != tick:
        return round_to_tick(result, direction)
    return result


def now_kst() -> datetime:
    return datetime.now(KST)


def is_market_open(at: datetime = None, holidays: set = frozenset()) -> bool:
    """정규장(평일 09:00~15:30 KST) 여부. holidays 는 'YYYYMMDD' 문자열 집합."""
    at = (at or now_kst()).astimezone(KST)
    if at.weekday() >= 5 or at.strftime("%Y%m%d") in holidays:
        return False
    return REGULAR_OPEN <= at.time() < REGULAR_CLOSE


def minutes_to_close(at: datetime = None) -> float:
    at = (at or now_kst()).astimezone(KST)
    close = at.replace(hour=REGULAR_CLOSE.hour, minute=REGULAR_CLOSE.minute, second=0, microsecond=0)
    return (close - at).total_seconds() / 60.0


def buy_cost(price: float, qty: int, fee_rate: float) -> float:
    """매수 체결 시 필요한 총금액 (수수료 포함)."""
    amount = price * qty
    return amount + amount * fee_rate


def sell_proceeds(price: float, qty: int, fee_rate: float, tax_rate: float) -> float:
    """매도 체결 시 실제로 들어오는 금액 (수수료 + 증권거래세 차감)."""
    amount = price * qty
    return amount - amount * fee_rate - amount * tax_rate
