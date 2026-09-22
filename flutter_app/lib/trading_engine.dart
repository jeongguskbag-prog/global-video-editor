import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

// ==========================================
// 캔들 데이터 + 시세 조회
//
// 바이낸스 선물 공개 REST(klines)는 인증 없이 호출 가능하고 모든 거래소
// 공통으로 취급할 수 있는 표준 캔들을 준다. 자동매매 신호 계산은 항상 이
// 데이터를 쓰고, 화면에 보이는 실시간 틱(웹소켓)은 기존처럼 선택된
// 거래소에서 받는다 — 두 값이 약간 다를 수 있음(전략 계산용 vs 표시용).
// ==========================================
class Candle {
  final DateTime openTime;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });
}

class MarketData {
  static Future<List<Candle>> fetchKlines({
    required String symbol,
    String interval = '5m',
    int limit = 100,
  }) async {
    final uri = Uri.parse(
        'https://fapi.binance.com/fapi/v1/klines?symbol=$symbol&interval=$interval&limit=$limit');
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('캔들 조회 실패 ($symbol, HTTP ${res.statusCode})');
    }
    final rows = jsonDecode(res.body) as List;
    return rows.map((row) {
      final r = row as List;
      return Candle(
        openTime: DateTime.fromMillisecondsSinceEpoch(r[0] as int),
        open: double.parse(r[1] as String),
        high: double.parse(r[2] as String),
        low: double.parse(r[3] as String),
        close: double.parse(r[4] as String),
        volume: double.parse(r[5] as String),
      );
    }).toList();
  }
}

// ==========================================
// 매매 전략 — 순수 함수: candles만 보고 신호를 계산하며 틱 사이의 상태를
// 갖지 않는다. 그래서 여러 코인을 매 틱마다 독립적으로 병렬 평가할 수 있다.
// ==========================================
enum StrategyPosition { none, long, short }

class StrategySignal {
  final bool enterLong;
  final bool enterShort;
  const StrategySignal({this.enterLong = false, this.enterShort = false});
}

abstract class TradingStrategy {
  const TradingStrategy();
  int get warmupCandles;
  StrategySignal? evaluate(List<Candle> candles);
}

/// 단순 이동평균(SMA) 골든/데드 크로스 전략.
class MovingAverageCrossoverStrategy extends TradingStrategy {
  final int fastPeriod;
  final int slowPeriod;

  const MovingAverageCrossoverStrategy({this.fastPeriod = 5, this.slowPeriod = 20});

  @override
  int get warmupCandles => slowPeriod + 2;

  @override
  StrategySignal? evaluate(List<Candle> candles) {
    if (candles.length < slowPeriod + 2) return null;
    final n = candles.length - 1;
    final fastNow = _sma(candles, fastPeriod, n);
    final slowNow = _sma(candles, slowPeriod, n);
    final fastPrev = _sma(candles, fastPeriod, n - 1);
    final slowPrev = _sma(candles, slowPeriod, n - 1);

    final crossedUp = fastPrev <= slowPrev && fastNow > slowNow;
    final crossedDown = fastPrev >= slowPrev && fastNow < slowNow;
    return StrategySignal(enterLong: crossedUp, enterShort: crossedDown);
  }

  double _sma(List<Candle> candles, int period, int endIndex) {
    double sum = 0;
    for (var i = endIndex - period + 1; i <= endIndex; i++) {
      sum += candles[i].close;
    }
    return sum / period;
  }
}

// ==========================================
// 포지션 손익 계산 — 순수 함수 (단위 테스트 대상)
// ==========================================
double marginBasedQuantity({
  required double marginPerTradeUsdt,
  required double leverage,
  required double price,
}) {
  if (price <= 0) return 0;
  return (marginPerTradeUsdt * leverage) / price;
}

double positionPnl({
  required StrategyPosition position,
  required double entryPrice,
  required double qty,
  required double currentPrice,
}) {
  switch (position) {
    case StrategyPosition.long:
      return (currentPrice - entryPrice) * qty;
    case StrategyPosition.short:
      return (entryPrice - currentPrice) * qty;
    case StrategyPosition.none:
      return 0;
  }
}

// ==========================================
// 자동매매 엔진 (데모/페이퍼트레이딩 전용)
//
// 주의: 이 엔진은 실제 거래소에 주문을 보내지 않는다. main.dart의
// _executeSecureOrder()와 마찬가지로 이 프로토타입에는 인증된 거래소 주문
// API 연동이 없다 — 여기서는 실시간 시세로 가상 잔고를 시뮬레이션만 한다.
// 실전 자동매매로 확장하려면 거래소별 인증 REST 주문 클라이언트가 별도로
// 필요하다.
// ==========================================
enum AutoTradeEvent { tick, opened, closed, error }

class AutoTradeStatus {
  final AutoTradeEvent event;
  final String symbol;
  final StrategyPosition position;
  final double? entryPrice;
  final double price;
  final double? unrealizedPnl;
  final double demoBalance;
  final String? message;

  const AutoTradeStatus({
    required this.event,
    required this.symbol,
    required this.position,
    this.entryPrice,
    required this.price,
    this.unrealizedPnl,
    required this.demoBalance,
    this.message,
  });
}

class AutoTradeEngine {
  // 매매 후보 심볼 목록. 1개면 단일 코인 자동매매, 여러 개면 포지션이 없는
  // 동안 매 틱마다 전부 스캔해서 신호(진입 방향)가 뜬 코인 중 하나를 골라
  // 진입한다(다중 코인 감시). 진입한 뒤에는 그 포지션이 청산될 때까지
  // activeSymbol을 그 코인으로 고정하고 다른 후보는 보지 않는다 — 한 번에
  // 포지션 하나만 유지한다.
  final List<String> symbols;
  final double leverage;
  final double marginPerTradeUsdt;
  final double? stopLossPercent;
  final double? takeProfitPercent;
  final TradingStrategy strategy;
  final String interval;
  final void Function(AutoTradeStatus status) onUpdate;

  String _activeSymbol;
  String get symbol => _activeSymbol;

  StrategyPosition _position = StrategyPosition.none;
  StrategyPosition get position => _position;

  double _entryPrice = 0;
  double _positionQty = 0;
  double _demoBalance;
  double get demoBalance => _demoBalance;

  Timer? _timer;
  bool _busy = false;

  AutoTradeEngine({
    required this.symbols,
    required this.leverage,
    required this.marginPerTradeUsdt,
    required this.onUpdate,
    this.strategy = const MovingAverageCrossoverStrategy(),
    this.stopLossPercent,
    this.takeProfitPercent,
    this.interval = '5m',
    double demoBalance = 5000,
  })  : assert(symbols.isNotEmpty, 'symbols는 최소 1개 이상이어야 합니다'),
        _activeSymbol = symbols.first,
        _demoBalance = demoBalance;

  Future<void> start({Duration tickInterval = const Duration(seconds: 30)}) async {
    await _tick();
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<List<Candle>> _fetchCandles(String sym) {
    return MarketData.fetchKlines(
        symbol: sym, interval: interval, limit: strategy.warmupCandles);
  }

  // 이번 틱에 볼 심볼과 그 캔들을 정한다. 포지션이 있거나 후보가 1개뿐이면
  // 지금 심볼(_activeSymbol) 하나만 조회한다 — 이 경로는 실패 시 예외를
  // 그대로 위로 전파해 _tick()의 catch가 기존과 동일하게 에러 상태를
  // 보고하게 한다. 후보가 여러 개이고 포지션이 없을 때만(다중 코인 감시)
  // 전부 병렬로 스캔해서 진입 신호가 뜬 것 중 하나를 고른다 — 이 경로는
  // 한 코인의 일시적 조회 실패가 나머지 후보 평가를 막지 않도록 심볼별로
  // 예외를 삼킨다.
  Future<({String symbol, List<Candle> candles})?> _selectCandidate() async {
    if (_position != StrategyPosition.none || symbols.length == 1) {
      final candles = await _fetchCandles(_activeSymbol);
      if (candles.isEmpty) return null;
      return (symbol: _activeSymbol, candles: candles);
    }

    final fetched = <String, List<Candle>>{};
    await Future.wait(symbols.map((sym) async {
      try {
        final c = await _fetchCandles(sym);
        if (c.isNotEmpty) fetched[sym] = c;
      } catch (_) {
        // 이 후보 하나만 건너뛴다.
      }
    }));

    for (final sym in symbols) {
      final c = fetched[sym];
      if (c == null) continue;
      final s = strategy.evaluate(c);
      if (s != null && (s.enterLong || s.enterShort)) {
        return (symbol: sym, candles: c);
      }
    }
    // 진입 신호가 뜬 후보가 없으면, 상태 표시용으로 조회에 성공한 첫 후보를 쓴다.
    for (final sym in symbols) {
      final c = fetched[sym];
      if (c != null) return (symbol: sym, candles: c);
    }
    return null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final candidate = await _selectCandidate();
      if (candidate == null) return;
      _activeSymbol = candidate.symbol;
      final candles = candidate.candles;
      final price = candles.last.close;

      if (_position != StrategyPosition.none) {
        final pnlPercent = _position == StrategyPosition.long
            ? (price - _entryPrice) / _entryPrice * 100
            : (_entryPrice - price) / _entryPrice * 100;
        if (stopLossPercent != null && pnlPercent <= -stopLossPercent!) {
          _close(price, '손절');
          return;
        }
        if (takeProfitPercent != null && pnlPercent >= takeProfitPercent!) {
          _close(price, '익절');
          return;
        }
      }

      final signal = strategy.evaluate(candles);
      if (_position == StrategyPosition.none && signal != null) {
        if (signal.enterLong) {
          _open(StrategyPosition.long, price);
          return;
        } else if (signal.enterShort) {
          _open(StrategyPosition.short, price);
          return;
        }
      } else if (_position != StrategyPosition.none && signal != null) {
        // 반대 방향 신호가 뜨면 청산만 한다(다음 틱에 다시 스캔해서 진입 여부 판단).
        final oppositeSignal =
            (_position == StrategyPosition.long && signal.enterShort) ||
                (_position == StrategyPosition.short && signal.enterLong);
        if (oppositeSignal) {
          _close(price, '반대 신호');
          return;
        }
      }

      onUpdate(AutoTradeStatus(
        event: AutoTradeEvent.tick,
        symbol: _activeSymbol,
        position: _position,
        entryPrice: _position == StrategyPosition.none ? null : _entryPrice,
        price: price,
        unrealizedPnl: _position == StrategyPosition.none
            ? null
            : positionPnl(
                position: _position,
                entryPrice: _entryPrice,
                qty: _positionQty,
                currentPrice: price),
        demoBalance: _demoBalance,
      ));
    } catch (e) {
      onUpdate(AutoTradeStatus(
        event: AutoTradeEvent.error,
        symbol: _activeSymbol,
        position: _position,
        price: 0,
        demoBalance: _demoBalance,
        message: '$e',
      ));
    } finally {
      _busy = false;
    }
  }

  void _open(StrategyPosition side, double price) {
    _position = side;
    _entryPrice = price;
    _positionQty = marginBasedQuantity(
        marginPerTradeUsdt: marginPerTradeUsdt, leverage: leverage, price: price);
    onUpdate(AutoTradeStatus(
      event: AutoTradeEvent.opened,
      symbol: _activeSymbol,
      position: _position,
      entryPrice: _entryPrice,
      price: price,
      unrealizedPnl: 0,
      demoBalance: _demoBalance,
    ));
  }

  void _close(double price, String reason) {
    final pnl = positionPnl(
        position: _position,
        entryPrice: _entryPrice,
        qty: _positionQty,
        currentPrice: price);
    _demoBalance += pnl;
    final closedSide = _position;
    _position = StrategyPosition.none;
    onUpdate(AutoTradeStatus(
      event: AutoTradeEvent.closed,
      symbol: _activeSymbol,
      position: closedSide,
      entryPrice: _entryPrice,
      price: price,
      unrealizedPnl: pnl,
      demoBalance: _demoBalance,
      message: reason,
    ));
    _entryPrice = 0;
    _positionQty = 0;
  }
}
