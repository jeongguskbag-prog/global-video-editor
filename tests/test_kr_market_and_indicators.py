from datetime import datetime

import pytest

from kr_stock_trader.indicators import ema, rsi, sma
from kr_stock_trader.market import KST, buy_cost, is_market_open, round_to_tick, sell_proceeds, tick_size


@pytest.mark.parametrize("price,tick", [
    (1_999, 1), (2_000, 5), (4_995, 5), (5_000, 10), (19_990, 10), (20_000, 50),
    (49_950, 50), (50_000, 100), (199_900, 100), (200_000, 500), (499_500, 500), (500_000, 1_000),
])
def test_tick_size(price, tick):
    assert tick_size(price) == tick


def test_round_to_tick():
    assert round_to_tick(70_123) == 70_100
    assert round_to_tick(70_123, "up") == 70_200
    assert round_to_tick(70_199, "down") == 70_100
    assert round_to_tick(1_999.6, "up") == 2_000
    assert round_to_tick(2_001, "down") == 2_000
    assert round_to_tick(19_996, "up") == 20_000


def test_market_hours():
    assert is_market_open(datetime(2026, 9, 25, 9, 0, tzinfo=KST))        # 금요일
    assert not is_market_open(datetime(2026, 9, 25, 15, 30, tzinfo=KST))
    assert not is_market_open(datetime(2026, 9, 26, 10, 0, tzinfo=KST))    # 토요일
    assert not is_market_open(datetime(2026, 9, 25, 10, 0, tzinfo=KST), {"20260925"})


def test_costs():
    assert buy_cost(10_000, 10, 0.00015) == pytest.approx(100_015)
    assert sell_proceeds(10_000, 10, 0.00015, 0.002) == pytest.approx(100_000 - 15 - 200)


def test_sma_ema():
    assert sma([1, 2, 3, 4], 2) == [None, 1.5, 2.5, 3.5]
    out = ema([1, 2, 3, 4, 5], 3)
    assert out[:2] == [None, None] and out[2] == 2
    assert out[4] == pytest.approx(4.0)


def test_rsi_bounds():
    up = list(range(1, 30))
    assert rsi(up, 14)[-1] == 100.0
    down = list(range(30, 1, -1))
    assert rsi(down, 14)[-1] == pytest.approx(0.0)
