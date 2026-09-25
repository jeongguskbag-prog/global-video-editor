"""진입/청산 신호 전략.

국내 현금 계좌는 공매도가 불가하므로 신호는 BUY(신규 매수) / SELL(보유분 청산) / HOLD 세 가지다.
"""

from dataclasses import dataclass
from enum import Enum
from typing import List

from .indicators import ema, rsi, sma
from .models import Candle


class Signal(str, Enum):
    BUY = "BUY"
    SELL = "SELL"
    HOLD = "HOLD"


@dataclass
class StrategyResult:
    signal: Signal
    reason: str


class Strategy:
    name = "base"

    def min_candles(self) -> int:
        raise NotImplementedError

    def evaluate(self, candles: List[Candle]) -> StrategyResult:
        raise NotImplementedError


class MovingAverageCrossoverStrategy(Strategy):
    """단기 EMA 가 장기 EMA 를 상향 돌파하면 매수, 하향 돌파하면 매도 (기본 9/21)."""

    name = "ma_cross"

    def __init__(self, short: int = 9, long: int = 21):
        if short >= long:
            raise ValueError("short 기간은 long 기간보다 작아야 합니다")
        self.short, self.long = short, long

    def min_candles(self) -> int:
        return self.long + 2

    def evaluate(self, candles):
        closes = [c.close for c in candles]
        if len(closes) < self.min_candles():
            return StrategyResult(Signal.HOLD, "캔들 부족")
        s, l = ema(closes, self.short), ema(closes, self.long)
        prev_diff, diff = s[-2] - l[-2], s[-1] - l[-1]
        if prev_diff <= 0 < diff:
            return StrategyResult(Signal.BUY, f"골든크로스 EMA{self.short}/{self.long}")
        if prev_diff >= 0 > diff:
            return StrategyResult(Signal.SELL, f"데드크로스 EMA{self.short}/{self.long}")
        return StrategyResult(Signal.HOLD, f"대기 (EMA{self.short}-EMA{self.long}={diff:,.1f})")


class RsiStrategy(Strategy):
    """RSI 가 과매도선을 아래에서 위로 회복하면 매수, 과매수선을 위에서 아래로 이탈하면 매도."""

    name = "rsi"

    def __init__(self, period: int = 14, oversold: float = 30, overbought: float = 70):
        self.period, self.oversold, self.overbought = period, oversold, overbought

    def min_candles(self) -> int:
        return self.period + 3

    def evaluate(self, candles):
        closes = [c.close for c in candles]
        if len(closes) < self.min_candles():
            return StrategyResult(Signal.HOLD, "캔들 부족")
        r = rsi(closes, self.period)
        prev, cur = r[-2], r[-1]
        if prev < self.oversold <= cur:
            return StrategyResult(Signal.BUY, f"RSI 과매도 탈출 ({prev:.1f}→{cur:.1f})")
        if prev > self.overbought >= cur:
            return StrategyResult(Signal.SELL, f"RSI 과매수 이탈 ({prev:.1f}→{cur:.1f})")
        return StrategyResult(Signal.HOLD, f"대기 (RSI {cur:.1f})")


class CombinedMaRsiStrategy(Strategy):
    """EMA 정배열(단기>장기) 상태에서 RSI 가 과열이 아닐 때만 매수. 역배열 전환 또는 RSI 과열 시 매도."""

    name = "ma_rsi"

    def __init__(self, short: int = 9, long: int = 21, rsi_period: int = 14,
                 rsi_entry_max: float = 60, rsi_exit: float = 75):
        self.ma = MovingAverageCrossoverStrategy(short, long)
        self.rsi_period, self.rsi_entry_max, self.rsi_exit = rsi_period, rsi_entry_max, rsi_exit

    def min_candles(self) -> int:
        return max(self.ma.min_candles(), self.rsi_period + 3)

    def evaluate(self, candles):
        closes = [c.close for c in candles]
        if len(closes) < self.min_candles():
            return StrategyResult(Signal.HOLD, "캔들 부족")
        s, l = ema(closes, self.ma.short), ema(closes, self.ma.long)
        r = rsi(closes, self.rsi_period)[-1]
        uptrend, prev_uptrend = s[-1] > l[-1], s[-2] > l[-2]
        if uptrend and not prev_uptrend and r <= self.rsi_entry_max:
            return StrategyResult(Signal.BUY, f"골든크로스 + RSI {r:.1f}")
        if (prev_uptrend and not uptrend) or r >= self.rsi_exit:
            return StrategyResult(Signal.SELL, f"추세 이탈/과열 (RSI {r:.1f})")
        return StrategyResult(Signal.HOLD, f"대기 (RSI {r:.1f})")


STRATEGIES = {
    MovingAverageCrossoverStrategy.name: MovingAverageCrossoverStrategy,
    RsiStrategy.name: RsiStrategy,
    CombinedMaRsiStrategy.name: CombinedMaRsiStrategy,
}


def build_strategy(name: str, **params) -> Strategy:
    try:
        return STRATEGIES[name](**params)
    except KeyError:
        raise ValueError(f"알 수 없는 전략: {name} (가능: {', '.join(STRATEGIES)})")


def trend_filter_ok(candles: List[Candle], period: int) -> bool:
    """상위 추세 필터: 종가가 장기 이동평균 위에 있을 때만 신규 매수 허용."""
    closes = [c.close for c in candles]
    ma = sma(closes, period)
    if not ma or ma[-1] is None:
        return True  # 데이터가 모자라면 필터를 적용하지 않는다
    return closes[-1] >= ma[-1]
