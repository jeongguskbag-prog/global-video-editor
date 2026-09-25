"""리스크 관리: 수량 계산, 청산 조건, 진입 차단 조건."""

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

from .config import RiskConfig
from .market import buy_cost


@dataclass
class ExitDecision:
    reason: str


class RiskManager:
    def __init__(self, cfg: RiskConfig):
        self.cfg = cfg

    # ---- 수량 ---------------------------------------------------------
    def position_size(self, price: float, equity: float, cash: float) -> int:
        """매수 수량(주). 현금 한도와 1회 예산/위험 한도 중 작은 쪽."""
        if price <= 0:
            return 0
        if self.cfg.risk_per_trade_pct is not None and self.cfg.stop_loss_pct:
            max_loss = equity * self.cfg.risk_per_trade_pct / 100.0
            qty = int(max_loss / (price * self.cfg.stop_loss_pct / 100.0))
        else:
            qty = int(self.cfg.budget_per_trade // price)
        while qty > 0 and buy_cost(price, qty, self.cfg.fee_rate) > cash:
            qty -= 1
        return max(qty, 0)

    # ---- 청산 ---------------------------------------------------------
    def check_exit(self, avg_price: float, price: float, peak: float) -> Optional[ExitDecision]:
        if avg_price <= 0:
            return None
        pnl_pct = (price / avg_price - 1.0) * 100.0
        c = self.cfg
        if c.stop_loss_pct is not None and pnl_pct <= -c.stop_loss_pct:
            return ExitDecision(f"손절 {pnl_pct:.2f}%")
        if c.take_profit_pct is not None and pnl_pct >= c.take_profit_pct:
            return ExitDecision(f"익절 {pnl_pct:.2f}%")
        if c.trailing_stop_pct is not None and peak > avg_price:
            drop = (1.0 - price / peak) * 100.0
            if drop >= c.trailing_stop_pct:
                return ExitDecision(f"트레일링 스탑 (고점 {peak:,.0f} 대비 -{drop:.2f}%)")
        return None

    def should_average_down(self, avg_price: float, price: float) -> bool:
        if self.cfg.average_down_pct is None or avg_price <= 0:
            return False
        return (price / avg_price - 1.0) * 100.0 <= -self.cfg.average_down_pct

    # ---- 진입 차단 ------------------------------------------------------
    def daily_limit_hit(self, realized_today: float, start_equity: float) -> bool:
        if self.cfg.daily_loss_limit_pct is None or start_equity <= 0:
            return False
        return realized_today <= -start_equity * self.cfg.daily_loss_limit_pct / 100.0

    def cooldown_until(self, consecutive_losses: int, last_loss_time: Optional[datetime]) -> Optional[datetime]:
        n = self.cfg.max_consecutive_losses
        if not n or consecutive_losses < n or last_loss_time is None:
            return None
        return last_loss_time + timedelta(hours=self.cfg.cooldown_hours)

    def spread_ok(self, spread_pct: Optional[float]) -> bool:
        if self.cfg.max_spread_pct is None or spread_pct is None:
            return True
        return spread_pct <= self.cfg.max_spread_pct
