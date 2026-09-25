"""명령줄 인터페이스.

    python -m kr_stock_trader quote 005930
    python -m kr_stock_trader balance
    python -m kr_stock_trader order buy 005930 1
    python -m kr_stock_trader run --config config.json
    python -m kr_stock_trader backtest 005930 --interval D --count 500
"""

import argparse
import logging
import sys
import time
from datetime import timedelta

from .backtest import run_backtest
from .brokers import Broker, BrokerError, DbBroker, KisBroker, KiwoomBroker, LsBroker, PaperBroker
from .config import AppConfig, env
from .engine import AutoTradeEngine
from .history import TradeHistoryStore
from .market import now_kst
from .models import OrderType, Side
from .notifier import TelegramNotifier
from .strategies import STRATEGIES, build_strategy


BROKERS = ["paper", "kis", "kiwoom", "ls", "db"]


def make_broker(name: str, cfg: AppConfig) -> Broker:
    if name == "kis":
        return KisBroker(env("KIS_APP_KEY"), env("KIS_APP_SECRET"), env("KIS_ACCOUNT"), cfg.env)
    if name == "kiwoom":
        return KiwoomBroker(env("KIWOOM_APP_KEY"), env("KIWOOM_SECRET_KEY"), cfg.env)
    if name == "ls":
        return LsBroker(env("LS_APP_KEY"), env("LS_APP_SECRET"), cfg.env)
    if name == "db":
        return DbBroker(env("DB_APP_KEY"), env("DB_APP_SECRET"), cfg.env)
    if name == "paper":
        source = None if cfg.paper_data == "synthetic" else make_broker(cfg.paper_data, cfg)
        return PaperBroker(cfg.paper_cash, cfg.risk.fee_rate, cfg.risk.tax_rate, data_source=source,
                           state_file=env("PAPER_STATE_FILE", "paper_state.json"),
                           quote_interval=cfg.strategy.interval)
    raise ValueError(f"알 수 없는 브로커: {name} ({' | '.join(BROKERS)})")


def _guard_live(broker: Broker, args) -> None:
    if broker.env == "real" and broker.name != "paper" and not args.live:
        sys.exit("실전(real) 계좌 주문은 --live 옵션을 붙여야 실행됩니다. 먼저 env=demo(모의투자)로 충분히 검증하세요.")


def cmd_quote(broker, cfg, args):
    q = broker.get_quote(args.symbol)
    spread = f"{q.spread_pct:.2f}%" if q.spread_pct is not None else "-"
    print(f"{q.symbol}  현재가 {q.price:,.0f}  매수1호가 {q.bid or 0:,.0f}  매도1호가 {q.ask or 0:,.0f}  스프레드 {spread}")


def cmd_candles(broker, cfg, args):
    for c in broker.get_candles(args.symbol, args.interval, args.count):
        print(f"{c.time:%Y-%m-%d %H:%M}  O {c.open:>10,.0f}  H {c.high:>10,.0f}  "
              f"L {c.low:>10,.0f}  C {c.close:>10,.0f}  V {c.volume:>12,.0f}")


def cmd_balance(broker, cfg, args):
    b = broker.get_balance()
    print(f"[{broker.name}/{broker.env}] 주문가능현금 {b.cash:,.0f}원 · 총평가 {b.total_eval:,.0f}원")
    for p in b.positions:
        pct = (p.current_price / p.avg_price - 1) * 100 if p.avg_price else 0
        print(f"  {p.symbol} {p.name:<12} {p.qty:>6}주  평단 {p.avg_price:>10,.0f}  "
              f"현재 {p.current_price:>10,.0f}  {pct:+.2f}%  {p.unrealized_pnl:+,.0f}원")


def cmd_order(broker, cfg, args):
    _guard_live(broker, args)
    side = Side(args.side)
    order_type = OrderType.LIMIT if args.price else OrderType.MARKET
    desc = f"{args.symbol} {'매수' if side == Side.BUY else '매도'} {args.qty}주 " + \
           (f"지정가 {args.price:,.0f}원" if args.price else "시장가")
    if not args.yes and input(f"[{broker.name}/{broker.env}] {desc} 주문할까요? (y/N) ").strip().lower() != "y":
        print("취소했습니다.")
        return
    r = broker.place_order(args.symbol, side, args.qty, order_type, args.price or 0)
    print(("주문 완료 #" + r.order_id if r.ok else "주문 실패") + f" - {r.message}")


def cmd_run(broker, cfg, args):
    _guard_live(broker, args)
    strategy = build_strategy(cfg.strategy.name, **cfg.strategy.params)
    notifier = TelegramNotifier(env("TELEGRAM_BOT_TOKEN"), env("TELEGRAM_CHAT_ID"))
    synthetic = isinstance(broker, PaperBroker) and broker.data_source is None
    fast = synthetic and args.fast
    sim = {"now": now_kst()}
    clock = (lambda: sim["now"]) if fast else now_kst  # --fast: 한 주기 = poll_seconds 만큼 가상 시간 진행
    engine = AutoTradeEngine(cfg, broker, strategy, TradeHistoryStore(cfg.history_file), notifier,
                             clock=clock, respect_market_hours=not (args.ignore_hours or synthetic))

    def sleep_and_print(seconds):
        for sym in ["*"] + cfg.symbols:
            if sym in engine.status:
                print(f"  {sym}: {engine.status[sym]}")
        if synthetic:  # 가상 시세는 한 주기마다 봉 하나씩 진행
            for sym in cfg.symbols:
                broker.market.advance(sym, cfg.strategy.interval)
        if fast:
            sim["now"] += timedelta(seconds=seconds)
        else:
            time.sleep(seconds)

    engine.run(max_cycles=args.cycles, sleep=sleep_and_print)


def cmd_backtest(broker, cfg, args):
    params = cfg.strategy.params if args.strategy == cfg.strategy.name else {}
    strategy = build_strategy(args.strategy, **params)
    candles = broker.get_candles(args.symbol, args.interval, args.count)
    if len(candles) <= strategy.min_candles():
        sys.exit(f"캔들이 부족합니다 ({len(candles)}개)")
    r = run_backtest(candles, strategy, cfg.risk, args.cash)
    print(f"{args.symbol} {args.interval} {len(candles)}봉 · 전략 {strategy.name}")
    print(f"  최종자산 {r.final_equity:,.0f}원 ({r.return_pct:+.2f}%) · 단순보유 {r.buy_and_hold_pct:+.2f}%")
    print(f"  거래 {len(r.trades)}회 · 승률 {r.win_rate:.1f}% · 최대낙폭 {r.max_drawdown_pct:.2f}%")
    for t in r.trades[-args.show:]:
        print(f"  {t.entry_time} → {t.exit_time}  {t.qty}주  {t.entry:,.0f} → {t.exit:,.0f}  "
              f"{t.pnl:+,.0f}원  {t.reason}")


def cmd_history(broker, cfg, args):
    store = TradeHistoryStore(cfg.history_file)
    for r in store.load()[-args.show:]:
        pnl = f"{r.pnl:+,.0f}원" if r.pnl is not None else ""
        print(f"{r.time}  {r.symbol}  {r.side:<4} {r.qty:>6}주 @ {r.price:>10,.0f}  {pnl:>12}  {r.reason}")
    s = store.stats()
    pf = f"{s['profit_factor']:.2f}" if s["profit_factor"] else "-"
    print(f"청산 {s['trades']}회 · 승률 {s['win_rate']:.1f}% · 누적손익 {s['total_pnl']:+,.0f}원 · PF {pf}")


def cmd_init_config(broker, cfg, args):
    with open(args.path, "w", encoding="utf-8") as f:
        f.write(AppConfig().to_json() + "\n")
    print(f"{args.path} 생성 완료")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="kr_stock_trader", description="국내 주식(KRX) 자동매매 터미널")
    p.add_argument("--config", "-c", help="설정 JSON 경로")
    p.add_argument("--broker", choices=BROKERS, help="설정의 broker 덮어쓰기")
    p.add_argument("--env", choices=["demo", "real"], help="설정의 env 덮어쓰기")
    p.add_argument("--verbose", "-v", action="store_true")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("quote", help="현재가/호가")
    s.add_argument("symbol")
    s.set_defaults(func=cmd_quote)

    s = sub.add_parser("candles", help="캔들 조회")
    s.add_argument("symbol")
    s.add_argument("--interval", default="D")
    s.add_argument("--count", type=int, default=20)
    s.set_defaults(func=cmd_candles)

    s = sub.add_parser("balance", help="잔고")
    s.set_defaults(func=cmd_balance)

    s = sub.add_parser("order", help="수동 주문 (가격 생략 시 시장가)")
    s.add_argument("side", choices=["buy", "sell"])
    s.add_argument("symbol")
    s.add_argument("qty", type=int)
    s.add_argument("--price", type=float)
    s.add_argument("--yes", "-y", action="store_true", help="확인 질문 생략")
    s.add_argument("--live", action="store_true", help="실전 계좌 주문 허용")
    s.set_defaults(func=cmd_order)

    s = sub.add_parser("run", help="자동매매 실행")
    s.add_argument("--cycles", type=int, help="N 주기만 실행 (기본: 무한)")
    s.add_argument("--live", action="store_true", help="실전 계좌 주문 허용")
    s.add_argument("--ignore-hours", action="store_true", help="장 운영시간 검사 생략")
    s.add_argument("--fast", action="store_true", help="가상 시세 모드에서 대기 없이 진행")
    s.set_defaults(func=cmd_run)

    s = sub.add_parser("backtest", help="백테스트")
    s.add_argument("symbol")
    s.add_argument("--strategy", choices=list(STRATEGIES), default=None)
    s.add_argument("--interval", default="D")
    s.add_argument("--count", type=int, default=500)
    s.add_argument("--cash", type=float, default=10_000_000)
    s.add_argument("--show", type=int, default=10)
    s.set_defaults(func=cmd_backtest)

    s = sub.add_parser("history", help="체결 기록/통계")
    s.add_argument("--show", type=int, default=20)
    s.set_defaults(func=cmd_history)

    s = sub.add_parser("init-config", help="기본 설정 파일 만들기")
    s.add_argument("path", nargs="?", default="config.json")
    s.set_defaults(func=cmd_init_config)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    try:
        cfg = AppConfig.load(args.config)
        if args.env:
            cfg.env = args.env
        if getattr(args, "strategy", "x") is None:
            args.strategy = cfg.strategy.name
        broker = None if args.command == "init-config" else make_broker(args.broker or cfg.broker, cfg)
        args.func(broker, cfg, args)
    except (BrokerError, ValueError) as e:
        print(f"오류: {e}", file=sys.stderr)
        return 1
    return 0
