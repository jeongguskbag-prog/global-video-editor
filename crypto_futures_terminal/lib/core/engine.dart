import 'dart:async';

import '../exchanges/exchange.dart';
import '../services/telegram.dart';
import 'config.dart';
import 'history.dart';
import 'market.dart';
import 'models.dart';
import 'risk.dart';
import 'strategies.dart';

/// 자동매매 엔진. 주기적으로 시세를 읽고, 포지션이 있으면 관리하고, 없으면 신호를 찾아 진입한다.
///
/// 자동매매가 꺼져 있어도 [refresh] 로 잔고/포지션/시세를 갱신해 대시보드에 보여준다.
class TradingEngine {
  final TradingConfig cfg;
  final ExchangeClient ex;
  final MarketData market;
  final TradeHistoryStore history;
  final TelegramNotifier telegram;
  final RiskState state;
  final void Function() onChanged;
  final RiskManager risk;

  TradingEngine({
    required this.cfg,
    required this.ex,
    required this.market,
    required this.history,
    required this.telegram,
    required this.state,
    required this.onChanged,
  }) : risk = RiskManager(cfg);

  // ---- 화면에 보여줄 상태 ----
  bool running = false;
  double balance = 0;
  Position? position;
  String activeCoin = '';
  Ticker? ticker;
  double? stopLoss, takeProfit;
  String status = '자동매매가 꺼져 있습니다.';
  final Map<String, String> signals = {};
  final List<LogEntry> logs = [];

  // ---- 내부 상태 ----
  Timer? _timer;
  bool _busy = false;
  bool _averaged = false;
  double _baseQty = 0;
  DateTime? _openedAt;

  String get _tag => cfg.live ? '[실전] ' : '[데모] ';
  List<String> get _watchCoins => cfg.multiCoinScan ? kCoins : [cfg.coin];

  void log(String msg) {
    logs.insert(0, LogEntry(msg));
    if (logs.length > 300) logs.removeLast();
    onChanged();
  }

  // ------------------------------------------------------------------ 제어

  Future<void> start() async {
    if (running) return;
    final err = cfg.validate();
    if (err != null) throw ExchangeException(err);
    log('$_tag자동매매 시작 중... (${cfg.exchange.label}, ${cfg.strategy.label})');
    // 레버리지/마진 모드 설정 + 기존 포지션 인수
    for (final coin in _watchCoins) {
      await ex.prepare(coin, cfg.leverage);
      if (position == null) {
        final p = await ex.position(coin, cfg.leverage);
        if (p != null) {
          _adopt(p);
          log('기존 $coin ${p.side.label} 포지션을 발견해 관리를 시작합니다.');
          await _protect(p);
        }
      }
    }
    running = true;
    status = '자동매매 실행 중';
    _timer = Timer.periodic(Duration(seconds: cfg.pollSeconds), (_) => tick());
    await telegram.send('$_tag자동매매 시작: ${cfg.exchange.label} / '
        '${cfg.multiCoinScan ? '다중 코인 감시' : cfg.coin} / ${cfg.strategy.label}');
    await tick();
  }

  Future<void> stop({String reason = '자동매매가 중지되었습니다.'}) async {
    _timer?.cancel();
    _timer = null;
    if (!running) return;
    running = false;
    status = '자동매매가 꺼져 있습니다.';
    log(reason);
    await telegram.send('$_tag$reason');
  }

  void dispose() {
    _timer?.cancel();
    ex.dispose();
  }

  // ------------------------------------------------------------------ 주기 처리

  /// 잔고·포지션·시세만 갱신 (매매 없음).
  Future<void> refresh() => _guard(() => _sync());

  Future<void> tick() => _guard(() async {
        await _sync();
        if (!running) return;
        if (position != null) {
          await _manage(position!);
        } else {
          await _scan();
        }
      });

  Future<void> _guard(Future<void> Function() body) async {
    if (_busy) return;
    _busy = true;
    try {
      await body();
    } catch (e) {
      log('오류: $e');
    } finally {
      _busy = false;
      onChanged();
    }
  }

  Future<void> _sync() async {
    final coin = position?.coin ?? (activeCoin.isEmpty ? cfg.coin : activeCoin);
    ticker = await market.ticker(cfg.exchange, coin);
    balance = await ex.availableBalance();
    final prev = position;
    final now = await ex.position(coin, cfg.leverage);
    if (prev != null && now == null) {
      await _onClosedExternally(prev);
    } else if (now != null) {
      if (prev == null) _adopt(now);
      position = now;
    }
    state.rollDay(balance + (position?.margin ?? 0));
  }

  void _adopt(Position p) {
    position = p;
    activeCoin = p.coin;
    _baseQty = p.qty;
    _averaged = false;
    _openedAt ??= DateTime.now();
    stopLoss = risk.stopLossPrice(p.side, p.entryPrice);
    takeProfit = risk.takeProfitPrice(p.side, p.entryPrice);
  }

  /// 손절/익절 주문이 거래소에서 체결되어 포지션이 사라진 경우.
  Future<void> _onClosedExternally(Position p) async {
    final price = ticker?.mid ?? p.entryPrice;
    final long = p.side == Side.long;
    double exit = price;
    String reason = '거래소에서 청산됨';
    if (stopLoss != null && (long ? price <= stopLoss! * 1.002 : price >= stopLoss! * 0.998)) {
      exit = stopLoss!;
      reason = '손절';
    } else if (takeProfit != null &&
        (long ? price >= takeProfit! * 0.998 : price <= takeProfit! * 1.002)) {
      exit = takeProfit!;
      reason = '익절';
    }
    await _record(p, exit, reason);
  }

  // ------------------------------------------------------------------ 포지션 관리

  Future<void> _manage(Position p) async {
    final price = ticker!.mid;
    if (state.exceedsDailyLimit(cfg, p.unrealizedPnl(price))) {
      state.dailyLimitHit = true;
      log('일일 손실 한도 도달 - 전량 청산 후 신규 진입 중단');
      await closePosition(reason: '일일 손실 한도');
      return;
    }
    if (risk.shouldAverageDown(p, price, _averaged)) {
      _averaged = true;
      try {
        await ex.marketOrder(p.coin, p.side, _baseQty);
        final np = await ex.position(p.coin, cfg.leverage) ?? p;
        position = np;
        await _protect(np);
        log('물타기 추가 진입 @ ${price.toStringAsFixed(4)} → 새 평단 ${np.entryPrice.toStringAsFixed(4)}');
        await telegram.send('$_tag${p.coin} 물타기 추가 진입 @ $price, 새 평단 ${np.entryPrice}');
      } catch (e) {
        log('물타기 주문 실패: $e');
      }
    }
    status = '${p.coin} ${p.side.label} 포지션 관리 중';
  }

  Future<void> _protect(Position p) async {
    stopLoss = risk.stopLossPrice(p.side, p.entryPrice);
    takeProfit = risk.takeProfitPrice(p.side, p.entryPrice);
    await ex.setProtection(p.coin, p, stopLoss, takeProfit);
  }

  // ------------------------------------------------------------------ 진입

  Future<void> _scan() async {
    if (state.dailyLimitHit) {
      status = '일일 손실 한도 도달 - 매매 중단';
      return;
    }
    final cd = state.cooldownRemaining();
    if (cd != null) {
      status = '연속 손절 쿨다운 중 (남은 시간 ${cd.inHours}시간 ${cd.inMinutes % 60}분)';
      return;
    }
    for (final coin in _watchCoins) {
      final candles = await market.candles(cfg.exchange, coin, cfg.interval);
      final sig = evaluateStrategy(cfg.strategy, candles);
      signals[coin] = sig.reason;
      final side = sig.side;
      if (side == null) continue;

      if (cfg.trendFilter) {
        final hourly = await market.candles(cfg.exchange, coin, '1h', limit: 250);
        if (!trendAllows(side, hourly)) {
          log('$coin 진입 보류: 상위 타임프레임 추세와 반대 방향 (${side.label})');
          continue;
        }
      }
      final t = await market.ticker(cfg.exchange, coin);
      final maxSpread = cfg.maxSpreadPct;
      if (maxSpread != null && t.spreadPct > maxSpread) {
        log('$coin 진입 보류: 매수/매도 스프레드가 너무 넓음 (${t.spreadPct.toStringAsFixed(3)}%)');
        continue;
      }
      await openPosition(coin, side, reason: sig.reason, ticker: t);
      return;
    }
    status = cfg.multiCoinScan
        ? '대기 중 (${_watchCoins.length}개 코인 감시)'
        : signals[cfg.coin] ?? '대기 중';
  }

  /// 신호 진입과 데모 "테스트 롱/숏 진입" 에서 공통으로 사용.
  Future<void> openPosition(String coin, Side side, {required String reason, Ticker? ticker}) async {
    if (position != null) throw ExchangeException('이미 열린 포지션이 있습니다.');
    final t = ticker ?? await market.ticker(cfg.exchange, coin);
    final price = side == Side.long ? t.ask : t.bid;
    final bal = await ex.availableBalance();
    final qty = risk.entryQty(price: price > 0 ? price : t.last, balance: bal);
    await ex.prepare(coin, cfg.leverage);
    final filled = await ex.marketOrder(coin, side, qty);
    final p = await ex.position(coin, cfg.leverage) ??
        Position(coin: coin, side: side, entryPrice: price, qty: filled, leverage: cfg.leverage);
    _openedAt = DateTime.now();
    _adopt(p);
    this.ticker = t;
    try {
      await _protect(p);
    } catch (e) {
      log('손절 주문 실패(포지션 무방비): $e — 안전을 위해 즉시 청산합니다.');
      await closePosition(reason: '손절 주문 실패');
      return;
    }
    final msg = '$coin ${side.label} 진입 @ ${p.entryPrice} × ${p.qty} (${cfg.leverage}x) — $reason';
    log(msg);
    await telegram.send('$_tag$msg');
  }

  Future<void> closePosition({String reason = '수동 청산'}) async {
    final p = position;
    if (p == null) return;
    final t = await market.ticker(cfg.exchange, p.coin);
    await ex.closePosition(p.coin, p);
    await _record(p, p.side == Side.long ? t.bid : t.ask, reason);
  }

  Future<void> _record(Position p, double exit, String reason) async {
    final fee = PaperFee.estimate(p, exit);
    final pnl = p.unrealizedPnl(exit) - fee;
    await history.add(TradeRecord(
      coin: p.coin,
      side: p.side,
      entryPrice: p.entryPrice,
      exitPrice: exit,
      qty: p.qty,
      leverage: p.leverage,
      pnl: pnl,
      reason: reason,
      live: cfg.live,
      exchange: cfg.exchange,
      openedAt: _openedAt ?? DateTime.now(),
      closedAt: DateTime.now(),
    ));
    state.onClosed(pnl, cfg);
    position = null;
    stopLoss = takeProfit = null;
    _openedAt = null;
    if (!cfg.multiCoinScan) activeCoin = cfg.coin;
    final msg = '${p.coin} ${p.side.label} 청산 ($reason) @ ${exit.toStringAsFixed(4)}, '
        '손익 ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)} USDT';
    log(msg);
    await telegram.send('$_tag$msg');
    if (state.cooldownRemaining() != null) {
      log('연속 손절 ${cfg.cooldownLosses}회 — ${cfg.cooldownHours}시간 동안 신규 진입을 쉽니다.');
    }
  }
}

/// 손익 기록용 왕복 수수료 추정 (테이커 0.05% × 2).
class PaperFee {
  static double estimate(Position p, double exit) => (p.entryPrice + exit) * p.qty * 0.0005;
}
