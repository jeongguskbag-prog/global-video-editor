// 자동매매 엔진 (Python kr_stock_trader/engine.py 와 같은 규칙).
//
// 매 주기 감시 종목마다
//  1) 보유 중: 손절/익절/트레일링/전략 매도/마감 전 청산/물타기 1회
//  2) 미보유: 일일 손실 한도·연속 손실 쿨다운·최대 보유 수·상위 추세·스프레드 통과 시 매수
// 감시 종목만 관리하고 계좌의 다른 보유 종목은 건드리지 않는다.
import '../brokers/broker.dart';
import 'config.dart';
import 'history.dart';
import 'market.dart';
import 'risk.dart';
import 'strategies.dart';

typedef Clock = DateTime Function(); // KST 시각을 돌려준다
typedef Notify = void Function(String message);

class AutoTradeEngine {
  final AppConfig cfg;
  final Broker broker;
  final Strategy strategy;
  final TradeHistory history;
  final RiskManager risk;
  final Clock clock;
  final Notify? notify;
  final bool respectMarketHours;

  final Map<String, double> peaks = {};
  final Set<String> averaged = {};
  final Map<String, DateTime> lastOrderAt = {};
  final Map<String, String> status = {};
  final List<String> events = [];
  String? _dayKey;
  double _startEquity = 0;
  bool halted = false;
  final Map<String, (String, bool)> _trendCache = {};

  AutoTradeEngine({
    required this.cfg,
    required this.broker,
    required this.strategy,
    required this.history,
    Clock? clock,
    this.notify,
    this.respectMarketHours = true,
  })  : risk = RiskManager(cfg.risk),
        clock = clock ?? (() => nowKst());

  void _emit(String msg) {
    events.add(msg);
    if (events.length > 200) events.removeAt(0);
    notify?.call(msg);
  }

  Future<List<String>> tick() async {
    final start = events.length;
    final now = clock();
    if (respectMarketHours && !isMarketOpen(now, cfg.holidays.toSet())) {
      status['*'] = '장 운영시간 아님 (평일 09:00~15:30)';
      return [];
    }
    status.remove('*');

    final balance = await broker.getBalance();
    final watch = cfg.symbols.toSet();
    final positions = {for (final p in balance.positions.where((p) => watch.contains(p.symbol))) p.symbol: p};
    final equity = balance.totalEval > 0 ? balance.totalEval : balance.cash;

    final today = ymd(now);
    if (today != _dayKey) {
      _dayKey = today;
      _startEquity = equity;
      halted = false;
      _trendCache.clear();
    }
    if (!halted && risk.dailyLimitHit(history.realizedOn(now), _startEquity)) {
      halted = true;
      _emit('일일 손실 한도 도달 → 감시 종목 전량 청산, 오늘은 신규 진입 중단');
    }
    final closingSoon = cfg.risk.exitMinutesBeforeClose != null &&
        respectMarketHours &&
        minutesToClose(now) <= cfg.risk.exitMinutesBeforeClose!;
    final (lossCount, lastLoss) = history.consecutiveLosses();
    final cooldown = risk.cooldownUntil(lossCount, lastLoss);
    final inCooldown = cooldown != null && now.isBefore(cooldown);

    var cash = balance.cash;
    var held = positions.length;
    for (final symbol in cfg.symbols) {
      final last = lastOrderAt[symbol];
      if (last != null && now.difference(last).inSeconds < cfg.orderCooldownSeconds) continue;
      try {
        final quote = await broker.getQuote(symbol);
        final pos = positions[symbol];
        if (pos != null) {
          cash -= await _manage(pos, quote, closingSoon, cash);
        } else if (halted) {
          status[symbol] = '일일 손실 한도로 진입 중단';
        } else if (closingSoon) {
          status[symbol] = '장 마감 임박, 신규 진입 안 함';
        } else if (inCooldown) {
          status[symbol] = '연속 $lossCount회 손실 쿨다운 (~${_hm(cooldown)})';
        } else if (held >= cfg.risk.maxPositions) {
          status[symbol] = '최대 보유 종목 수(${cfg.risk.maxPositions}) 도달';
        } else {
          final spent = await _enter(symbol, quote, equity, cash, now);
          if (spent > 0) {
            cash -= spent;
            held++;
          }
        }
      } on BrokerException catch (e) {
        status[symbol] = '오류: $e';
      }
    }
    return events.sublist(start);
  }

  Future<double> _manage(Position pos, Quote q, bool closingSoon, double cash) async {
    final price = q.price;
    final peak = [peaks[pos.symbol] ?? pos.avgPrice, price].reduce((a, b) => a > b ? a : b);
    peaks[pos.symbol] = peak;
    final pnl = pos.avgPrice > 0 ? (price / pos.avgPrice - 1) * 100 : 0.0;

    String? reason;
    if (halted) {
      reason = '일일 손실 한도';
    } else if (closingSoon) {
      reason = '장 마감 전 청산';
    } else {
      reason = risk.checkExit(pos.avgPrice, price, peak);
    }

    if (reason == null && !averaged.contains(pos.symbol) && risk.shouldAverageDown(pos.avgPrice, price)) {
      final cost = buyCost(q.ask ?? price, pos.qty, cfg.risk.feeRate);
      if (cost <= cash && await _order(pos.symbol, Side.buy, pos.qty, q, '물타기 (${pnl.toStringAsFixed(2)}%)')) {
        averaged.add(pos.symbol);
        return cost;
      }
    }

    if (reason == null) {
      final candles = await broker.getCandles(pos.symbol, cfg.interval, cfg.candles);
      final r = strategy.evaluate(candles);
      if (r.signal == Signal.sell) {
        reason = '전략 매도: ${r.reason}';
      } else {
        status[pos.symbol] =
            '보유 ${pos.qty}주 @ ${_won(pos.avgPrice)} (${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}%) · ${r.reason}';
        return 0;
      }
    }
    if (await _order(pos.symbol, Side.sell, pos.qty, q, reason, avgPrice: pos.avgPrice)) {
      peaks.remove(pos.symbol);
      averaged.remove(pos.symbol);
    }
    return 0;
  }

  Future<double> _enter(String symbol, Quote q, double equity, double cash, DateTime now) async {
    final candles = await broker.getCandles(symbol, cfg.interval, cfg.candles);
    final r = strategy.evaluate(candles);
    if (r.signal != Signal.buy) {
      status[symbol] = r.reason;
      return 0;
    }
    final tf = cfg.trendFilterPeriod;
    if (tf != null && tf > 0 && !await _trendOk(symbol, tf, now)) {
      status[symbol] = '진입 보류: 일봉 $tf일선 아래 (하락 추세)';
      return 0;
    }
    if (!risk.spreadOk(q.spreadPct)) {
      status[symbol] = '진입 보류: 호가 스프레드 과대 (${q.spreadPct!.toStringAsFixed(2)}%)';
      return 0;
    }
    final entry = q.ask ?? q.price;
    final qty = risk.positionSize(entry, equity, cash);
    if (qty <= 0) {
      status[symbol] = '매수 신호지만 주문가능금액 부족 (${_won(cash)})';
      return 0;
    }
    if (await _order(symbol, Side.buy, qty, q, r.reason)) {
      peaks[symbol] = entry;
      return buyCost(entry, qty, cfg.risk.feeRate);
    }
    return 0;
  }

  Future<bool> _trendOk(String symbol, int period, DateTime now) async {
    final key = ymd(now);
    final cached = _trendCache[symbol];
    if (cached != null && cached.$1 == key) return cached.$2;
    final ok = trendFilterOk(await broker.getCandles(symbol, 'D', period + 5), period);
    _trendCache[symbol] = (key, ok);
    return ok;
  }

  Future<bool> _order(String symbol, Side side, int qty, Quote q, String reason, {double? avgPrice}) async {
    OrderType type;
    double price;
    if (cfg.marketOrder) {
      type = OrderType.market;
      price = 0;
    } else {
      type = OrderType.limit;
      final ref = (side == Side.buy ? q.ask : q.bid) ?? q.price;
      price = roundToTick(ref, side == Side.buy ? 'up' : 'down').toDouble();
    }
    final result = await broker.placeOrder(symbol, side, qty, type, price);
    final now = clock();
    lastOrderAt[symbol] = now;
    final label = side == Side.buy ? '매수' : '매도';
    if (!result.ok) {
      status[symbol] = '$label 주문 실패: ${result.message}';
      _emit('❌ $symbol $label $qty주 실패 - ${result.message}');
      return false;
    }
    final fill = result.price > 0 ? result.price : (price > 0 ? price : ((side == Side.buy ? q.ask : q.bid) ?? q.price));
    double? pnl;
    if (side == Side.sell && avgPrice != null) {
      final rc = cfg.risk;
      pnl = sellProceeds(fill, qty, rc.feeRate, rc.taxRate) - buyCost(avgPrice, qty, rc.feeRate);
    }
    history.add(TradeRecord(
      time: now,
      symbol: symbol,
      side: side.name,
      qty: qty,
      price: fill,
      reason: reason,
      pnl: pnl,
      orderId: result.orderId,
      broker: '${broker.name}/${broker.live ? '실전' : '모의'}',
    ));
    status[symbol] = '$label $qty주 @ ${_won(fill)} ($reason)';
    final pnlText = pnl == null ? '' : ', 손익 ${pnl >= 0 ? '+' : ''}${_won(pnl)}';
    _emit('✅ $symbol $label $qty주 @ ${_won(fill)} · $reason$pnlText');
    return true;
  }
}

String _won(double v) {
  final s = v.abs().round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${v < 0 ? '-' : ''}$s원';
}

String _hm(DateTime t) =>
    '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String formatWon(double v) => _won(v);
