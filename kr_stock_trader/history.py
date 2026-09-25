"""체결 기록(JSON Lines)과 통계."""

import json
import os
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import List, Optional

from .market import KST, now_kst


@dataclass
class TradeRecord:
    time: str
    symbol: str
    side: str
    qty: int
    price: float
    reason: str = ""
    pnl: Optional[float] = None   # 매도(청산) 시 실현손익 (수수료·세금 차감)
    order_id: str = ""
    broker: str = ""


class TradeHistoryStore:
    def __init__(self, path: str):
        self.path = path

    def append(self, record: TradeRecord) -> None:
        folder = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(folder, exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(asdict(record), ensure_ascii=False) + "\n")

    def load(self) -> List[TradeRecord]:
        if not os.path.exists(self.path):
            return []
        out = []
        with open(self.path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    out.append(TradeRecord(**json.loads(line)))
        return out

    def closed_trades(self) -> List[TradeRecord]:
        return [r for r in self.load() if r.pnl is not None]

    def realized_pnl_on(self, day: datetime = None) -> float:
        key = (day or now_kst()).astimezone(KST).strftime("%Y-%m-%d")
        return sum(r.pnl for r in self.closed_trades() if r.time.startswith(key))

    def consecutive_losses(self) -> tuple:
        """(최근 연속 손실 횟수, 마지막 손실 시각)"""
        count, last_time = 0, None
        for r in reversed(self.closed_trades()):
            if r.pnl < 0:
                count += 1
                last_time = last_time or datetime.fromisoformat(r.time)
            else:
                break
        return count, last_time

    def stats(self) -> dict:
        closed = self.closed_trades()
        wins = [r for r in closed if r.pnl > 0]
        losses = [r for r in closed if r.pnl <= 0]
        gross_win = sum(r.pnl for r in wins)
        gross_loss = -sum(r.pnl for r in losses)
        return {
            "trades": len(closed),
            "wins": len(wins),
            "losses": len(losses),
            "win_rate": (len(wins) / len(closed) * 100.0) if closed else 0.0,
            "total_pnl": gross_win - gross_loss,
            "profit_factor": (gross_win / gross_loss) if gross_loss else None,
        }
