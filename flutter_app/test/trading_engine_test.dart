import 'package:flutter_test/flutter_test.dart';
import 'package:global_futures_terminal/trading_engine.dart';

Candle _c(double close, {double? open, double? high, double? low}) {
  return Candle(
    openTime: DateTime.utc(2026),
    open: open ?? close,
    high: high ?? close,
    low: low ?? close,
    close: close,
    volume: 1,
  );
}

void main() {
  group('marginBasedQuantity', () {
    test('margin * leverage / price', () {
      expect(
        marginBasedQuantity(marginPerTradeUsdt: 100, leverage: 10, price: 50),
        20,
      );
    });

    test('non-positive price returns 0', () {
      expect(
        marginBasedQuantity(marginPerTradeUsdt: 100, leverage: 10, price: 0),
        0,
      );
    });
  });

  group('positionPnl', () {
    test('long profits when price rises', () {
      expect(
        positionPnl(
            position: StrategyPosition.long, entryPrice: 100, qty: 2, currentPrice: 110),
        20,
      );
    });

    test('short profits when price falls', () {
      expect(
        positionPnl(
            position: StrategyPosition.short, entryPrice: 100, qty: 2, currentPrice: 90),
        20,
      );
    });

    test('none is always 0', () {
      expect(
        positionPnl(
            position: StrategyPosition.none, entryPrice: 100, qty: 2, currentPrice: 200),
        0,
      );
    });
  });

  group('MovingAverageCrossoverStrategy', () {
    const strategy = MovingAverageCrossoverStrategy(fastPeriod: 2, slowPeriod: 4);

    test('returns null when not enough candles', () {
      final candles = List.generate(3, (i) => _c(100.0 + i));
      expect(strategy.evaluate(candles), isNull);
    });

    test('detects a golden cross (enterLong)', () {
      // 하락하다가 마지막 두 캔들에서 급등 -> 단기 평균이 장기 평균을 상향 돌파.
      final closes = [100.0, 98.0, 96.0, 94.0, 92.0, 130.0];
      final candles = closes.map(_c).toList();
      final signal = strategy.evaluate(candles);
      expect(signal, isNotNull);
      expect(signal!.enterLong, isTrue);
      expect(signal.enterShort, isFalse);
    });

    test('detects a dead cross (enterShort)', () {
      final closes = [100.0, 102.0, 104.0, 106.0, 108.0, 70.0];
      final candles = closes.map(_c).toList();
      final signal = strategy.evaluate(candles);
      expect(signal, isNotNull);
      expect(signal!.enterShort, isTrue);
      expect(signal.enterLong, isFalse);
    });

    test('flat prices produce no signal', () {
      final candles = List.generate(6, (_) => _c(100.0));
      final signal = strategy.evaluate(candles);
      expect(signal, isNotNull);
      expect(signal!.enterLong, isFalse);
      expect(signal.enterShort, isFalse);
    });
  });

  group('AutoTradeEngine._selectCandidate via public behavior', () {
    test('single-symbol engine starts with that symbol as active', () {
      final engine = AutoTradeEngine(
        symbols: const ['BTCUSDT'],
        leverage: 10,
        marginPerTradeUsdt: 50,
        onUpdate: (_) {},
      );
      expect(engine.symbol, 'BTCUSDT');
      expect(engine.position, StrategyPosition.none);
    });

    test('multi-symbol engine starts on the first candidate', () {
      final engine = AutoTradeEngine(
        symbols: const ['BTCUSDT', 'ETHUSDT', 'BNBUSDT'],
        leverage: 10,
        marginPerTradeUsdt: 50,
        onUpdate: (_) {},
      );
      expect(engine.symbol, 'BTCUSDT');
    });
  });
}
