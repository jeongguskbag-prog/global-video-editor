"""과거 캔들로 전략 + 손절/익절 규칙을 검증하는 간단한 백테스터.

- 전략 신호는 봉 마감에 판단하고 다음 봉 시가에 체결한다 (미래 참조 방지).
- 손절/익절은 봉 내부 고가/저가로 판단하며, 같은 봉에서 둘 다 닿으면 보수적으로 손절 처리한다.
- 상위 추세 필터와 스프레드 필터는 적용하지 않는다.
"""

from dataclasses import dataclass, field
from typing import List

from .config import RiskConfig
from .market import buy_cost, sell_proceeds
from .models import Candle
from .risk import RiskManager
from .strategies import Signal, Strategy


@dataclass
class BacktestTrade:
    entry_time: str
    exit_time: str
    qty: int
    entry: float
    exit: float
    pnl: float
    reason: str


@dataclass
class BacktestResult:
    initial_cash: float
    final_equity: float
    trades: List[BacktestTrade] = field(default_factory=list)
    max_drawdown_pct: float = 0.0
    buy_and_hold_pct: float = 0.0

    @property
    def return_pct(self) -> float:
        return (self.final_equity / self.initial_cash - 1) * 100

    @property
    def win_rate(self) -> float:
        return (sum(t.pnl > 0 for t in self.trades) / len(self.trades) * 100) if self.trades else 0.0


def run_backtest(candles: List[Candle], strategy: Strategy, risk_cfg: RiskConfig,
                 initial_cash: float = 10_000_000) -> BacktestResult:
    risk = RiskManager(risk_cfg)
    cash, qty, avg, peak, entry_time = initial_cash, 0, 0.0, 0.0, ""
    pending = None  # 다음 봉 시가에 실행할 신호
    trades: List[BacktestTrade] = []
    peak_equity, mdd = initial_cash, 0.0
    start = strategy.min_candles()

    def close_position(price, when, reason):
        nonlocal cash, qty
        pnl = sell_proceeds(price, qty, risk_cfg.fee_rate, risk_cfg.tax_rate) - buy_cost(avg, qty, risk_cfg.fee_rate)
        cash += sell_proceeds(price, qty, risk_cfg.fee_rate, risk_cfg.tax_rate)
        trades.append(BacktestTrade(entry_time, when, qty, avg, price, pnl, reason))
        qty = 0

    for i in range(start, len(candles)):
        bar = candles[i]
        when = bar.time.strftime("%Y-%m-%d %H:%M")

        # 1) 직전 봉에서 나온 신호를 이번 봉 시가에 체결
        if pending == Signal.BUY and qty == 0:
            equity = cash
            n = risk.position_size(bar.open, equity, cash)
            if n > 0:
                cash -= buy_cost(bar.open, n, risk_cfg.fee_rate)
                qty, avg, peak, entry_time = n, bar.open, bar.open, when
        elif pending == Signal.SELL and qty > 0:
            close_position(bar.open, when, "전략 매도")
        pending = None

        # 2) 봉 내부 손절/익절/트레일링
        if qty > 0:
            sl = avg * (1 - risk_cfg.stop_loss_pct / 100) if risk_cfg.stop_loss_pct else None
            tp = avg * (1 + risk_cfg.take_profit_pct / 100) if risk_cfg.take_profit_pct else None
            if sl and bar.low <= sl:
                close_position(min(bar.open, sl), when, "손절")
            elif tp and bar.high >= tp:
                close_position(max(bar.open, tp), when, "익절")
            else:
                peak = max(peak, bar.high)
                decision = risk.check_exit(avg, bar.close, peak) if risk_cfg.trailing_stop_pct else None
                if decision:
                    close_position(bar.close, when, decision.reason)

        # 3) 봉 마감 신호
        result = strategy.evaluate(candles[: i + 1])
        if result.signal in (Signal.BUY, Signal.SELL):
            pending = result.signal

        equity = cash + qty * bar.close
        peak_equity = max(peak_equity, equity)
        mdd = max(mdd, (1 - equity / peak_equity) * 100)

    if qty > 0:
        close_position(candles[-1].close, candles[-1].time.strftime("%Y-%m-%d %H:%M"), "백테스트 종료")

    bh = (candles[-1].close / candles[start].close - 1) * 100 if len(candles) > start else 0.0
    return BacktestResult(initial_cash, cash, trades, mdd, bh)
