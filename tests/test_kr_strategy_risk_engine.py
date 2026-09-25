from datetime import datetime, timedelta

import pytest

from kr_stock_trader.backtest import run_backtest
from kr_stock_trader.brokers.paper import PaperBroker
from kr_stock_trader.config import AppConfig, RiskConfig, StrategyConfig
from kr_stock_trader.engine import AutoTradeEngine
from kr_stock_trader.history import TradeHistoryStore, TradeRecord
from kr_stock_trader.market import KST
from kr_stock_trader.models import Candle, Quote, Side
from kr_stock_trader.risk import RiskManager
from kr_stock_trader.strategies import (CombinedMaRsiStrategy, MovingAverageCrossoverStrategy, Signal,
                                        Strategy, StrategyResult)


def candles_from(closes):
    t0 = datetime(2026, 1, 1, tzinfo=KST)
    return [Candle(t0 + timedelta(days=i), c, c * 1.01, c * 0.99, c, 1000) for i, c in enumerate(closes)]


def test_ma_cross_signals():
    s = MovingAverageCrossoverStrategy(3, 6)
    down_then_up = [100 - i for i in range(20)] + [81 + 3 * i for i in range(3)]
    assert s.evaluate(candles_from(down_then_up[:-2])).signal == Signal.HOLD
    signals = [s.evaluate(candles_from(down_then_up[:n])).signal for n in range(10, len(down_then_up) + 1)]
    assert Signal.BUY in signals


def test_combined_rejects_overheated_entry():
    s = CombinedMaRsiStrategy(3, 6, rsi_entry_max=10)
    closes = [100 - i for i in range(20)] + [81 + 3 * i for i in range(3)]
    signals = [s.evaluate(candles_from(closes[:n])).signal for n in range(10, len(closes) + 1)]
    assert Signal.BUY not in signals


def test_risk_sizing_and_exits():
    r = RiskManager(RiskConfig(budget_per_trade=1_000_000, stop_loss_pct=3, take_profit_pct=6))
    assert r.position_size(70_000, 10_000_000, 10_000_000) == 14
    assert r.position_size(70_000, 10_000_000, 500_000) == 7  # 현금 한도
    assert r.check_exit(70_000, 67_900, 70_000).reason.startswith("손절")
    assert r.check_exit(70_000, 74_200, 74_200).reason.startswith("익절")
    assert r.check_exit(70_000, 71_000, 71_000) is None

    risk_based = RiskManager(RiskConfig(risk_per_trade_pct=1, stop_loss_pct=2))
    # 자본 1천만의 1% = 10만원 손실 한도, 1주당 손절 손실 = 50,000*2% = 1,000원 → 100주
    assert risk_based.position_size(50_000, 10_000_000, 10_000_000) == 100


def test_trailing_and_limits():
    r = RiskManager(RiskConfig(stop_loss_pct=None, take_profit_pct=None, trailing_stop_pct=2,
                               daily_loss_limit_pct=5, max_consecutive_losses=2, cooldown_hours=1,
                               max_spread_pct=0.3))
    assert r.check_exit(100, 107.8, 110).reason.startswith("트레일링")
    assert r.check_exit(100, 108, 110) is None
    assert r.daily_limit_hit(-500_000, 10_000_000)
    assert not r.daily_limit_hit(-499_999, 10_000_000)
    t = datetime(2026, 1, 1, 10, tzinfo=KST)
    assert r.cooldown_until(2, t) == t + timedelta(hours=1)
    assert r.cooldown_until(1, t) is None
    assert r.spread_ok(0.2) and not r.spread_ok(0.5) and r.spread_ok(None)


def test_config_validation(tmp_path):
    with pytest.raises(ValueError):
        RiskConfig(stop_loss_pct=3, average_down_pct=5).validate()
    p = tmp_path / "c.json"
    p.write_text('{"broker": "paper", "symbols": ["005930"], "risk": {"bogus": 1}}', encoding="utf-8")
    with pytest.raises(ValueError):
        AppConfig.load(str(p))
    p.write_text('{"symbols": ["5930"]}', encoding="utf-8")
    with pytest.raises(ValueError):
        AppConfig.load(str(p))


class ScriptedStrategy(Strategy):
    name = "scripted"

    def __init__(self):
        self.signal = Signal.HOLD

    def min_candles(self):
        return 1

    def evaluate(self, candles):
        return StrategyResult(self.signal, "테스트 신호")


class FakeMarket:
    """PaperBroker 에 끼워 넣는 고정 시세."""

    def __init__(self):
        self.price = 10_000

    def candles(self, symbol, interval, count):
        return candles_from([self.price] * count)

    def quote(self, symbol, interval="D"):
        return Quote(symbol, self.price, self.price - 10, self.price + 10)


def make_engine(tmp_path, **risk):
    market = FakeMarket()
    broker = PaperBroker(cash=1_000_000, market=market)
    cfg = AppConfig(symbols=["005930"], order_cooldown_seconds=0,
                    strategy=StrategyConfig(interval="D", trend_filter_period=None),
                    risk=RiskConfig(budget_per_trade=200_000, **risk),
                    history_file=str(tmp_path / "h.jsonl"))
    strategy = ScriptedStrategy()
    clock = {"now": datetime(2026, 9, 25, 10, 0, tzinfo=KST)}
    engine = AutoTradeEngine(cfg, broker, strategy, TradeHistoryStore(cfg.history_file),
                             clock=lambda: clock["now"])
    return engine, broker, market, strategy, clock


def test_engine_entry_take_profit_and_history(tmp_path):
    engine, broker, market, strategy, _ = make_engine(tmp_path, stop_loss_pct=3, take_profit_pct=5)
    strategy.signal = Signal.BUY
    engine.tick()
    pos = broker.positions["005930"]
    assert pos.qty == 19 and pos.avg_price == 10_010  # 200,000 / 10,010 매도1호가

    strategy.signal = Signal.HOLD
    market.price = 10_600
    engine.tick()
    assert "005930" not in broker.positions
    closed = engine.history.closed_trades()
    assert len(closed) == 1 and closed[0].pnl > 0 and closed[0].reason.startswith("익절")


def test_engine_respects_market_hours(tmp_path):
    engine, broker, _, strategy, clock = make_engine(tmp_path)
    clock["now"] = datetime(2026, 9, 26, 10, 0, tzinfo=KST)  # 토요일
    strategy.signal = Signal.BUY
    engine.tick()
    assert not broker.positions


def test_engine_daily_loss_limit_blocks_entries(tmp_path):
    engine, broker, market, strategy, _ = make_engine(tmp_path, stop_loss_pct=3, daily_loss_limit_pct=0.1)
    strategy.signal = Signal.BUY
    engine.tick()
    market.price = 9_000  # -10% → 손절, 손실이 자본의 0.1% 초과
    engine.tick()
    assert not broker.positions
    engine.tick()
    assert not broker.positions
    assert "일일 손실 한도" in engine.status["005930"]


def test_engine_cooldown_after_consecutive_losses(tmp_path):
    engine, broker, _, strategy, clock = make_engine(tmp_path, max_consecutive_losses=2, cooldown_hours=2)
    for i in range(2):
        engine.history.append(TradeRecord(time=clock["now"].isoformat(), symbol="005930",
                                          side="sell", qty=1, price=1, pnl=-100))
    strategy.signal = Signal.BUY
    engine.tick()
    assert not broker.positions and "쿨다운" in engine.status["005930"]
    clock["now"] += timedelta(hours=3)
    engine.tick()
    assert broker.positions


def test_engine_average_down_once(tmp_path):
    engine, broker, market, strategy, _ = make_engine(tmp_path, stop_loss_pct=10, average_down_pct=4)
    strategy.signal = Signal.BUY
    engine.tick()
    strategy.signal = Signal.HOLD
    market.price = 9_500
    engine.tick()
    assert broker.positions["005930"].qty == 38
    market.price = 9_000
    engine.tick()
    assert broker.positions["005930"].qty == 38  # 두 번째 물타기는 없음


def test_engine_force_exit_before_close(tmp_path):
    engine, broker, _, strategy, clock = make_engine(tmp_path, exit_minutes_before_close=10)
    strategy.signal = Signal.BUY
    engine.tick()
    clock["now"] = clock["now"].replace(hour=15, minute=25)
    strategy.signal = Signal.HOLD
    engine.tick()
    assert not broker.positions


def test_backtest_runs():
    closes = [100 + (i % 20) * (1 if (i // 20) % 2 == 0 else -1) for i in range(200)]
    closes = [c * 100 for c in closes]
    result = run_backtest(candles_from(closes), MovingAverageCrossoverStrategy(3, 8),
                          RiskConfig(budget_per_trade=1_000_000), 10_000_000)
    assert result.trades
    assert result.final_equity > 0
    assert 0 <= result.win_rate <= 100
