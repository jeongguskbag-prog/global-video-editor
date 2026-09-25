"""자동매매 엔진.

매 주기마다 감시 종목별로
  1) 보유 중이면: 손절/익절/트레일링/전략 매도/마감 전 청산/물타기 판단
  2) 미보유면  : 일일 손실 한도·연속 손실 쿨다운·최대 보유 종목 수·상위 추세·스프레드를 통과한
                 매수 신호에만 진입
엔진은 config.symbols 에 있는 종목만 관리하고, 계좌의 다른 보유 종목은 건드리지 않는다.
"""

import logging
import time
from datetime import datetime
from typing import Callable, Dict, List, Optional

from .brokers.base import Broker, BrokerError
from .config import AppConfig
from .history import TradeHistoryStore, TradeRecord
from .market import buy_cost, is_market_open, minutes_to_close, now_kst, round_to_tick, sell_proceeds
from .models import OrderType, Position, Quote, Side
from .notifier import TelegramNotifier
from .risk import RiskManager
from .strategies import Signal, Strategy, trend_filter_ok

log = logging.getLogger(__name__)


class AutoTradeEngine:
    def __init__(self, cfg: AppConfig, broker: Broker, strategy: Strategy,
                 history: TradeHistoryStore, notifier: TelegramNotifier = None,
                 clock: Callable[[], datetime] = now_kst, respect_market_hours: bool = True):
        self.cfg, self.broker, self.strategy = cfg, broker, strategy
        self.risk = RiskManager(cfg.risk)
        self.history = history
        self.notifier = notifier or TelegramNotifier()
        self.clock = clock
        self.respect_market_hours = respect_market_hours
        self.peaks: Dict[str, float] = {}
        self.averaged: set = set()
        self.last_order_at: Dict[str, float] = {}
        self.status: Dict[str, str] = {}
        self._day_key: Optional[str] = None
        self._start_equity = 0.0
        self._halted = False
        self._trend_cache: Dict[str, tuple] = {}
        self._events: List[str] = []

    # ---- 루프 -----------------------------------------------------------
    def run(self, max_cycles: int = None, sleep: Callable[[float], None] = time.sleep) -> None:
        self._notify(f"[{self.broker.name}/{self.broker.env}] 자동매매 시작: {', '.join(self.cfg.symbols)} "
                     f"(전략 {self.strategy.name}, {self.cfg.strategy.interval})")
        cycles = 0
        try:
            while max_cycles is None or cycles < max_cycles:
                try:
                    self.tick()
                except BrokerError as e:
                    log.error("주기 실행 실패: %s", e)
                cycles += 1
                if max_cycles is None or cycles < max_cycles:
                    sleep(self.cfg.poll_seconds)
        except KeyboardInterrupt:
            pass
        finally:
            self._notify("자동매매 중지")

    def tick(self) -> List[str]:
        self._events = []
        now = self.clock()
        if self.respect_market_hours and not is_market_open(now, set(self.cfg.holidays)):
            self.status["*"] = "장 운영시간 아님 (평일 09:00~15:30)"
            return self._events

        balance = self.broker.get_balance()
        watch = set(self.cfg.symbols)
        positions = {p.symbol: p for p in balance.positions if p.symbol in watch}
        equity = balance.total_eval or balance.cash

        today = now.strftime("%Y-%m-%d")
        if today != self._day_key:
            self._day_key, self._start_equity, self._halted = today, equity, False
            self._trend_cache.clear()

        if not self._halted and self.risk.daily_limit_hit(self.history.realized_pnl_on(now), self._start_equity):
            self._halted = True
            self._notify(f"일일 손실 한도 도달 → 감시 종목 전량 청산, 오늘은 신규 진입 중단")

        closing_soon = (self.cfg.risk.exit_minutes_before_close is not None and self.respect_market_hours
                        and minutes_to_close(now) <= self.cfg.risk.exit_minutes_before_close)

        count, last_loss = self.history.consecutive_losses()
        cooldown_until = self.risk.cooldown_until(count, last_loss)
        in_cooldown = cooldown_until is not None and now < cooldown_until

        cash = balance.cash
        for symbol in self.cfg.symbols:
            if self._recently_ordered(symbol):
                continue
            try:
                quote = self.broker.get_quote(symbol)
                pos = positions.get(symbol)
                if pos:
                    cash -= self._manage_position(pos, quote, closing_soon, cash)
                elif self._halted:
                    self.status[symbol] = "일일 손실 한도로 진입 중단"
                elif closing_soon:
                    self.status[symbol] = "장 마감 임박, 신규 진입 안 함"
                elif in_cooldown:
                    self.status[symbol] = f"연속 {count}회 손실 쿨다운 (~{cooldown_until:%m-%d %H:%M})"
                elif len(positions) >= self.cfg.risk.max_positions:
                    self.status[symbol] = f"최대 보유 종목 수({self.cfg.risk.max_positions}) 도달"
                else:
                    spent = self._consider_entry(symbol, quote, equity, cash, now)
                    if spent:
                        cash -= spent
                        positions[symbol] = Position(symbol, 0, quote.price)  # 이번 주기 보유 수 계산용
            except BrokerError as e:
                self.status[symbol] = f"오류: {e}"
                log.warning("%s 처리 실패: %s", symbol, e)
        return self._events

    # ---- 보유 종목 --------------------------------------------------------
    def _manage_position(self, pos: Position, quote: Quote, closing_soon: bool, cash: float) -> float:
        price = quote.price
        peak = max(self.peaks.get(pos.symbol, pos.avg_price), price)
        self.peaks[pos.symbol] = peak
        pnl_pct = (price / pos.avg_price - 1) * 100 if pos.avg_price else 0.0

        reason = None
        if self._halted:
            reason = "일일 손실 한도"
        elif closing_soon:
            reason = "장 마감 전 청산"
        else:
            decision = self.risk.check_exit(pos.avg_price, price, peak)
            if decision:
                reason = decision.reason

        if reason is None and pos.symbol not in self.averaged and self.risk.should_average_down(pos.avg_price, price):
            cost = buy_cost(quote.ask or price, pos.qty, self.cfg.risk.fee_rate)
            if cost <= cash and self._order(pos.symbol, Side.BUY, pos.qty, quote, f"물타기 ({pnl_pct:.2f}%)"):
                self.averaged.add(pos.symbol)
                return cost

        if reason is None:
            candles = self.broker.get_candles(pos.symbol, self.cfg.strategy.interval, self.cfg.strategy.candles)
            result = self.strategy.evaluate(candles)
            if result.signal == Signal.SELL:
                reason = f"전략 매도: {result.reason}"
            else:
                self.status[pos.symbol] = f"보유 {pos.qty}주 @ {pos.avg_price:,.0f} ({pnl_pct:+.2f}%) · {result.reason}"
                return 0.0

        if self._order(pos.symbol, Side.SELL, pos.qty, quote, reason, avg_price=pos.avg_price):
            self.peaks.pop(pos.symbol, None)
            self.averaged.discard(pos.symbol)
        return 0.0

    # ---- 신규 진입 --------------------------------------------------------
    def _consider_entry(self, symbol: str, quote: Quote, equity: float, cash: float, now: datetime) -> float:
        sc = self.cfg.strategy
        candles = self.broker.get_candles(symbol, sc.interval, sc.candles)
        result = self.strategy.evaluate(candles)
        if result.signal != Signal.BUY:
            self.status[symbol] = result.reason
            return 0.0
        if sc.trend_filter_period and not self._trend_ok(symbol, now):
            self.status[symbol] = f"진입 보류: 일봉 {sc.trend_filter_period}일선 아래 (하락 추세)"
            return 0.0
        if not self.risk.spread_ok(quote.spread_pct):
            self.status[symbol] = f"진입 보류: 호가 스프레드 과대 ({quote.spread_pct:.2f}%)"
            return 0.0
        entry_price = quote.ask or quote.price
        qty = self.risk.position_size(entry_price, equity, cash)
        if qty <= 0:
            self.status[symbol] = f"매수 신호지만 주문가능금액 부족 ({cash:,.0f}원)"
            return 0.0
        if self._order(symbol, Side.BUY, qty, quote, result.reason):
            self.peaks[symbol] = entry_price
            return buy_cost(entry_price, qty, self.cfg.risk.fee_rate)
        return 0.0

    def _trend_ok(self, symbol: str, now: datetime) -> bool:
        key = now.strftime("%Y%m%d")
        cached = self._trend_cache.get(symbol)
        if cached and cached[0] == key:
            return cached[1]
        period = self.cfg.strategy.trend_filter_period
        ok = trend_filter_ok(self.broker.get_candles(symbol, "D", period + 5), period)
        self._trend_cache[symbol] = (key, ok)
        return ok

    # ---- 주문 공통 --------------------------------------------------------
    def _order(self, symbol: str, side: Side, qty: int, quote: Quote, reason: str,
               avg_price: float = None) -> bool:
        if self.cfg.order_type == "limit":
            order_type = OrderType.LIMIT
            ref = (quote.ask if side == Side.BUY else quote.bid) or quote.price
            price = round_to_tick(ref, "up" if side == Side.BUY else "down")
        else:
            order_type, price = OrderType.MARKET, 0
        result = self.broker.place_order(symbol, side, qty, order_type, price)
        self.last_order_at[symbol] = self.clock().timestamp()
        label = "매수" if side == Side.BUY else "매도"
        if not result.ok:
            self.status[symbol] = f"{label} 주문 실패: {result.message}"
            self._notify(f"❌ {symbol} {label} {qty}주 실패 - {result.message}")
            return False

        fill = result.price or price or ((quote.ask if side == Side.BUY else quote.bid) or quote.price)
        pnl = None
        if side == Side.SELL and avg_price:
            rc = self.cfg.risk
            pnl = sell_proceeds(fill, qty, rc.fee_rate, rc.tax_rate) - buy_cost(avg_price, qty, rc.fee_rate)
        self.history.append(TradeRecord(
            time=self.clock().isoformat(timespec="seconds"), symbol=symbol, side=side.value, qty=qty,
            price=fill, reason=reason, pnl=pnl, order_id=result.order_id,
            broker=f"{self.broker.name}/{self.broker.env}",
        ))
        pnl_text = f", 손익 {pnl:+,.0f}원" if pnl is not None else ""
        self.status[symbol] = f"{label} {qty}주 @ {fill:,.0f} ({reason})"
        self._notify(f"✅ {symbol} {label} {qty}주 @ {fill:,.0f}원 · {reason}{pnl_text}")
        return True

    def _recently_ordered(self, symbol: str) -> bool:
        t = self.last_order_at.get(symbol)
        return t is not None and self.clock().timestamp() - t < self.cfg.order_cooldown_seconds

    def _notify(self, text: str) -> None:
        log.info(text)
        self._events.append(text)
        self.notifier.send(text)
