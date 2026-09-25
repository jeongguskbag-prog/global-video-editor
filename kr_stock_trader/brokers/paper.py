"""로컬 모의매매 브로커. 증권사 계좌 없이 전략/엔진을 시험할 때 쓴다.

시세는 SyntheticMarket(가상 랜덤워크) 또는 실제 브로커(KIS/키움)의 시세 조회를 빌려 쓰고,
주문은 1호가(없으면 현재가)에 즉시 전량 체결된 것으로 처리한다. 수수료·거래세 반영.
"""

import json
import os
import random
from datetime import timedelta
from typing import Dict, List, Optional

from .base import Broker, parse_interval
from ..market import buy_cost, now_kst, round_to_tick, sell_proceeds, tick_size
from ..models import Balance, Candle, OrderResult, OrderType, Position, Quote, Side


class SyntheticMarket:
    """종목별로 재현 가능한 가상 시세를 만든다 (오프라인 데모/테스트용)."""

    def __init__(self, seed: int = 42, start_price: float = 70_000, volatility: float = 0.012):
        self.seed, self.start_price, self.volatility = seed, start_price, volatility
        self._series: Dict[str, List[Candle]] = {}
        self._rng = random.Random(seed)

    def _generate(self, symbol: str, n: int, minutes: Optional[int]) -> List[Candle]:
        rng = random.Random(f"{self.seed}-{symbol}-{minutes}")
        price = self.start_price * (0.5 + rng.random())
        step = timedelta(minutes=minutes) if minutes else timedelta(days=1)
        t = now_kst().replace(second=0, microsecond=0)
        if not minutes:
            t = t.replace(hour=0, minute=0)
        t -= step * n
        out = []
        for _ in range(n):
            o = price
            c = max(o * (1 + rng.gauss(0.0003, self.volatility)), 100)
            h = max(o, c) * (1 + abs(rng.gauss(0, self.volatility / 3)))
            l = min(o, c) * (1 - abs(rng.gauss(0, self.volatility / 3)))
            t += step
            out.append(Candle(t, round_to_tick(o), round_to_tick(h, "up"), round_to_tick(l, "down"),
                              round_to_tick(c), rng.randint(10_000, 500_000)))
            price = c
        return out

    def candles(self, symbol: str, interval: str, count: int) -> List[Candle]:
        minutes = parse_interval(interval)
        key = f"{symbol}:{interval}"
        if key not in self._series or len(self._series[key]) < count:
            self._series[key] = self._generate(symbol, max(count, 300), minutes)
        return self._series[key][-count:]

    def advance(self, symbol: str, interval: str) -> None:
        """다음 봉 하나를 추가한다 (데모 루프에서 시간이 흐르는 효과)."""
        series = self.candles(symbol, interval, 300)
        rng = self._rng
        last = series[-1]
        c = max(last.close * (1 + rng.gauss(0.0003, self.volatility)), 100)
        step = series[-1].time - series[-2].time
        self._series[f"{symbol}:{interval}"].append(
            Candle(last.time + step, last.close, round_to_tick(max(last.close, c), "up"),
                   round_to_tick(min(last.close, c), "down"), round_to_tick(c), rng.randint(10_000, 500_000)))

    def quote(self, symbol: str, interval: str = "D") -> Quote:
        price = self.candles(symbol, interval, 1)[-1].close
        tick = tick_size(price)
        return Quote(symbol, price, price - tick, price + tick)


class PaperBroker(Broker):
    name = "paper"

    def __init__(self, cash: float = 10_000_000, fee_rate: float = 0.00015, tax_rate: float = 0.0020,
                 data_source: Broker = None, market: SyntheticMarket = None,
                 state_file: str = None, quote_interval: str = "D"):
        self.fee_rate, self.tax_rate = fee_rate, tax_rate
        self.data_source = data_source
        self.market = market or SyntheticMarket()
        self.quote_interval = quote_interval
        self.state_file = state_file
        self.cash = cash
        self.positions: Dict[str, Position] = {}
        self._order_seq = 0
        self._load()

    # ---- 상태 저장 --------------------------------------------------------
    def _load(self):
        if not self.state_file or not os.path.exists(self.state_file):
            return
        with open(self.state_file, encoding="utf-8") as f:
            data = json.load(f)
        self.cash = data["cash"]
        self._order_seq = data.get("order_seq", 0)
        self.positions = {p["symbol"]: Position(**p) for p in data.get("positions", [])}

    def _save(self):
        if not self.state_file:
            return
        data = {"cash": self.cash, "order_seq": self._order_seq,
                "positions": [vars(p) for p in self.positions.values()]}
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    # ---- 시세 -----------------------------------------------------------
    def get_quote(self, symbol: str) -> Quote:
        if self.data_source:
            return self.data_source.get_quote(symbol)
        return self.market.quote(symbol, self.quote_interval)

    def get_candles(self, symbol, interval="D", count=100):
        if self.data_source:
            return self.data_source.get_candles(symbol, interval, count)
        return self.market.candles(symbol, interval, count)

    # ---- 계좌 -----------------------------------------------------------
    def get_balance(self) -> Balance:
        positions, total = [], self.cash
        for p in self.positions.values():
            p.current_price = self.get_quote(p.symbol).price
            total += p.current_price * p.qty
            positions.append(Position(p.symbol, p.qty, p.avg_price, p.name, p.current_price))
        return Balance(cash=self.cash, total_eval=total, positions=positions)

    def place_order(self, symbol, side, qty, order_type=OrderType.MARKET, price=0) -> OrderResult:
        if qty <= 0:
            return OrderResult(False, message="수량이 0입니다", symbol=symbol, side=side)
        q = self.get_quote(symbol)
        if side == Side.BUY:
            fill = q.ask or q.price
            if order_type == OrderType.LIMIT and price < fill:
                return OrderResult(False, message="지정가가 매도호가보다 낮아 미체결 (paper 는 미체결 주문을 보관하지 않음)",
                                   symbol=symbol, side=side, qty=qty, price=price)
            cost = buy_cost(fill, qty, self.fee_rate)
            if cost > self.cash:
                return OrderResult(False, message=f"주문가능금액 부족 (필요 {cost:,.0f}원, 보유 {self.cash:,.0f}원)",
                                   symbol=symbol, side=side, qty=qty, price=fill)
            self.cash -= cost
            pos = self.positions.get(symbol)
            if pos:
                pos.avg_price = (pos.avg_price * pos.qty + fill * qty) / (pos.qty + qty)
                pos.qty += qty
            else:
                self.positions[symbol] = Position(symbol, qty, fill, current_price=fill)
        else:
            pos = self.positions.get(symbol)
            if not pos or pos.qty < qty:
                return OrderResult(False, message="매도 가능 수량 부족", symbol=symbol, side=side, qty=qty)
            fill = q.bid or q.price
            if order_type == OrderType.LIMIT and price > fill:
                return OrderResult(False, message="지정가가 매수호가보다 높아 미체결",
                                   symbol=symbol, side=side, qty=qty, price=price)
            self.cash += sell_proceeds(fill, qty, self.fee_rate, self.tax_rate)
            pos.qty -= qty
            if pos.qty == 0:
                del self.positions[symbol]
        self._order_seq += 1
        self._save()
        return OrderResult(True, f"P{self._order_seq:06d}", "모의 체결", symbol, side, qty, fill)
