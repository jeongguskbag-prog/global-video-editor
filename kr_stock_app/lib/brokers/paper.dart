// 로컬 모의매매 브로커 + 가상 시세. 계좌 없이 앱을 체험할 때 쓴다.
import 'dart:convert';
import 'dart:math';

import '../core/config.dart';
import '../core/market.dart';
import 'broker.dart';

class SyntheticMarket {
  final int seed;
  final double volatility;
  final Map<String, List<Candle>> _series = {};
  final Random _rng;
  SyntheticMarket({this.seed = 42, this.volatility = 0.012}) : _rng = Random(seed);

  List<Candle> _generate(String symbol, int n, int? minutes) {
    final rng = Random(symbol.hashCode ^ seed ^ (minutes ?? 0));
    var price = 20000 + rng.nextDouble() * 180000;
    final step = minutes == null ? const Duration(days: 1) : Duration(minutes: minutes);
    final now = nowKst();
    var t = (minutes == null ? DateTime(now.year, now.month, now.day) : DateTime(now.year, now.month, now.day, now.hour, now.minute))
        .subtract(step * n);
    final out = <Candle>[];
    for (var i = 0; i < n; i++) {
      final o = price;
      final c = max(o * (1 + _gauss(rng) * volatility + 0.0003), 100.0);
      final h = max(o, c) * (1 + (_gauss(rng) * volatility / 3).abs());
      final l = min(o, c) * (1 - (_gauss(rng) * volatility / 3).abs());
      t = t.add(step);
      out.add(Candle(t, roundToTick(o).toDouble(), roundToTick(h, 'up').toDouble(), roundToTick(l, 'down').toDouble(),
          roundToTick(c).toDouble(), 10000 + rng.nextInt(490000).toDouble()));
      price = c;
    }
    return out;
  }

  List<Candle> candles(String symbol, String interval, int count) {
    final key = '$symbol:$interval';
    final s = _series[key];
    if (s == null || s.length < count) _series[key] = _generate(symbol, max(count, 300), parseInterval(interval));
    final list = _series[key]!;
    return list.sublist(max(0, list.length - count));
  }

  /// 다음 봉 하나 추가 (시간이 흐르는 효과)
  void advance(String symbol, String interval) {
    if (!_series.containsKey('$symbol:$interval')) candles(symbol, interval, 300);
    final list = _series['$symbol:$interval']!;
    final last = list.last;
    final c = max(last.close * (1 + _gauss(_rng) * volatility + 0.0003), 100.0);
    final step = list.length > 1 ? last.time.difference(list[list.length - 2].time) : const Duration(minutes: 1);
    list.add(Candle(last.time.add(step), last.close, roundToTick(max(last.close, c), 'up').toDouble(),
        roundToTick(min(last.close, c), 'down').toDouble(), roundToTick(c).toDouble(), 10000 + _rng.nextInt(490000).toDouble()));
  }

  Quote quote(String symbol, String interval) {
    final p = candles(symbol, interval, 1).last.close;
    final t = tickSize(p);
    return Quote(symbol, p, bid: p - t, ask: p + t);
  }

  static double _gauss(Random r) {
    final u1 = max(r.nextDouble(), 1e-12), u2 = r.nextDouble();
    return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
  }
}

class PaperBroker implements Broker {
  final double feeRate, taxRate;
  final Broker? dataSource;
  final SyntheticMarket market;
  final String quoteInterval;
  final KeyValueStore? store;
  double cash;
  final Map<String, Position> positions = {};
  int _seq = 0;

  PaperBroker({
    this.cash = 10000000,
    this.feeRate = 0.00015,
    this.taxRate = 0.002,
    this.dataSource,
    SyntheticMarket? market,
    this.quoteInterval = 'D',
    this.store,
  }) : market = market ?? SyntheticMarket();

  @override
  String get name => 'paper';
  @override
  bool get live => false;

  Future<void> load() async {
    final raw = await store?.read('paper_state');
    if (raw == null || raw.isEmpty) return;
    final j = jsonDecode(raw) as Map;
    cash = (j['cash'] as num).toDouble();
    _seq = (j['seq'] as num?)?.toInt() ?? 0;
    positions.clear();
    for (final p in (j['positions'] as List)) {
      final m = (p as Map).cast<String, dynamic>();
      positions[m['s'] as String] = Position(m['s'] as String, (m['q'] as num).toInt(), (m['a'] as num).toDouble());
    }
  }

  Future<void> _save() async => store?.write(
      'paper_state',
      jsonEncode({
        'cash': cash,
        'seq': _seq,
        'positions': positions.values.map((p) => {'s': p.symbol, 'q': p.qty, 'a': p.avgPrice}).toList(),
      }));

  Future<void> reset(double newCash) async {
    cash = newCash;
    positions.clear();
    await _save();
  }

  @override
  Future<Quote> getQuote(String symbol) async =>
      dataSource != null ? dataSource!.getQuote(symbol) : market.quote(symbol, quoteInterval);

  @override
  Future<List<Candle>> getCandles(String symbol, String interval, int count) async =>
      dataSource != null ? dataSource!.getCandles(symbol, interval, count) : market.candles(symbol, interval, count);

  @override
  Future<Balance> getBalance() async {
    var total = cash;
    final list = <Position>[];
    for (final p in positions.values) {
      final price = (await getQuote(p.symbol)).price;
      total += price * p.qty;
      list.add(Position(p.symbol, p.qty, p.avgPrice, currentPrice: price));
    }
    return Balance(cash, total, list);
  }

  @override
  Future<OrderResult> placeOrder(String symbol, Side side, int qty, OrderType type, double price) async {
    if (qty <= 0) return const OrderResult(false, message: '수량이 0입니다');
    final q = await getQuote(symbol);
    double fill;
    if (side == Side.buy) {
      fill = q.ask ?? q.price;
      if (type == OrderType.limit && price < fill) {
        return const OrderResult(false, message: '지정가가 매도호가보다 낮아 미체결 (모의는 미체결 주문을 보관하지 않음)');
      }
      final cost = buyCost(fill, qty, feeRate);
      if (cost > cash) return OrderResult(false, message: '주문가능금액 부족 (필요 ${cost.round()}원)');
      cash -= cost;
      final p = positions[symbol];
      positions[symbol] = p == null
          ? Position(symbol, qty, fill)
          : Position(symbol, p.qty + qty, (p.avgPrice * p.qty + fill * qty) / (p.qty + qty));
    } else {
      final p = positions[symbol];
      if (p == null || p.qty < qty) return const OrderResult(false, message: '매도 가능 수량 부족');
      fill = q.bid ?? q.price;
      if (type == OrderType.limit && price > fill) return const OrderResult(false, message: '지정가가 매수호가보다 높아 미체결');
      cash += sellProceeds(fill, qty, feeRate, taxRate);
      if (p.qty == qty) {
        positions.remove(symbol);
      } else {
        positions[symbol] = Position(symbol, p.qty - qty, p.avgPrice);
      }
    }
    _seq++;
    await _save();
    return OrderResult(true, orderId: 'P${_seq.toString().padLeft(6, '0')}', message: '모의 체결', price: fill);
  }
}
