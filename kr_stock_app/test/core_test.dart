import 'package:flutter_test/flutter_test.dart';
import 'package:kr_stock_app/brokers/paper.dart';
import 'package:kr_stock_app/core/config.dart';
import 'package:kr_stock_app/core/engine.dart';
import 'package:kr_stock_app/core/history.dart';
import 'package:kr_stock_app/core/indicators.dart';
import 'package:kr_stock_app/core/market.dart';
import 'package:kr_stock_app/core/models.dart';
import 'package:kr_stock_app/core/risk.dart';
import 'package:kr_stock_app/core/strategies.dart';

List<Candle> candlesFrom(List<double> closes) => [
      for (var i = 0; i < closes.length; i++)
        Candle(DateTime(2026, 1, 1).add(Duration(days: i)), closes[i], closes[i] * 1.01, closes[i] * 0.99, closes[i], 1000)
    ];

class ScriptedStrategy implements Strategy {
  Signal signal = Signal.hold;
  @override
  String get name => 'scripted';
  @override
  String get label => 'scripted';
  @override
  int get minCandles => 1;
  @override
  StrategyResult evaluate(List<Candle> candles) => StrategyResult(signal, '테스트 신호');
}

/// PaperBroker 에 끼우는 고정 시세
class FixedMarket extends SyntheticMarket {
  double price = 10000;
  @override
  List<Candle> candles(String symbol, String interval, int count) => candlesFrom(List.filled(count, price));
  @override
  Quote quote(String symbol, String interval) => Quote(symbol, price, bid: price - 10, ask: price + 10);
}

void main() {
  group('market', () {
    test('tick size & rounding', () {
      expect(tickSize(1999), 1);
      expect(tickSize(2000), 5);
      expect(tickSize(49950), 50);
      expect(tickSize(500000), 1000);
      expect(roundToTick(70123), 70100);
      expect(roundToTick(70123, 'up'), 70200);
      expect(roundToTick(1999.6, 'up'), 2000);
      expect(roundToTick(19996, 'up'), 20000);
    });
    test('market hours in KST', () {
      expect(isMarketOpen(DateTime(2026, 9, 25, 9, 0)), isTrue);
      expect(isMarketOpen(DateTime(2026, 9, 25, 15, 30)), isFalse);
      expect(isMarketOpen(DateTime(2026, 9, 26, 10)), isFalse); // 토요일
      expect(isMarketOpen(DateTime(2026, 9, 25, 10), {'20260925'}), isFalse);
      expect(nowKst(DateTime.utc(2026, 9, 25, 0, 30)).hour, 9);
    });
    test('costs', () {
      expect(buyCost(10000, 10, 0.00015), closeTo(100015, 1e-6));
      expect(sellProceeds(10000, 10, 0.00015, 0.002), closeTo(100000 - 15 - 200, 1e-6));
    });
  });

  group('indicators & strategies', () {
    test('sma / ema / rsi', () {
      expect(sma([1, 2, 3, 4], 2), [null, 1.5, 2.5, 3.5]);
      expect(ema([1, 2, 3, 4, 5], 3)[4], closeTo(4.0, 1e-9));
      expect(rsi(List.generate(30, (i) => i + 1.0)).last, 100);
    });
    test('MA cross emits buy after reversal', () {
      final closes = <double>[for (var i = 0; i < 20; i++) 100.0 - i, 81, 84, 87];
      final s = MaCrossStrategy(short: 3, long: 6);
      final signals = [for (var n = 10; n <= closes.length; n++) s.evaluate(candlesFrom(closes.sublist(0, n))).signal];
      expect(signals, contains(Signal.buy));
    });
  });

  group('risk', () {
    test('sizing & exits', () {
      final r = RiskManager(RiskConfig(budgetPerTrade: 1000000, stopLossPct: 3, takeProfitPct: 6));
      expect(r.positionSize(70000, 1e7, 1e7), 14);
      expect(r.positionSize(70000, 1e7, 500000), 7);
      expect(r.checkExit(70000, 67900, 70000), startsWith('손절'));
      expect(r.checkExit(70000, 74200, 74200), startsWith('익절'));
      expect(r.checkExit(70000, 71000, 71000), isNull);
      final byRisk = RiskManager(RiskConfig(riskPerTradePct: 1, stopLossPct: 2));
      expect(byRisk.positionSize(50000, 1e7, 1e7), 100);
    });
    test('config validation', () {
      expect(RiskConfig(stopLossPct: 3, averageDownPct: 5).validate(), isNotNull);
      expect(AppConfig(symbols: ['5930']).validate(), isNotNull);
      expect(AppConfig().validate(), isNull);
      final round = AppConfig.decode(AppConfig(symbols: ['035420'], live: true).encode());
      expect(round.symbols, ['035420']);
      expect(round.live, isTrue);
    });
  });

  group('engine', () {
    late DateTime now;
    late FixedMarket market;
    late PaperBroker broker;
    late ScriptedStrategy strategy;
    late TradeHistory history;

    AutoTradeEngine make(RiskConfig risk) {
      now = DateTime(2026, 9, 25, 10);
      market = FixedMarket();
      broker = PaperBroker(cash: 1000000, market: market);
      strategy = ScriptedStrategy();
      history = TradeHistory();
      final cfg = AppConfig(symbols: ['005930'], orderCooldownSeconds: 0, interval: 'D', trendFilterPeriod: null, risk: risk);
      return AutoTradeEngine(cfg: cfg, broker: broker, strategy: strategy, history: history, clock: () => now);
    }

    test('entry then take-profit with pnl recorded', () async {
      final e = make(RiskConfig(budgetPerTrade: 200000, stopLossPct: 3, takeProfitPct: 5));
      strategy.signal = Signal.buy;
      await e.tick();
      expect(broker.positions['005930']!.qty, 19);
      strategy.signal = Signal.hold;
      market.price = 10600;
      await e.tick();
      expect(broker.positions, isEmpty);
      final closed = history.closed.toList();
      expect(closed.single.pnl, greaterThan(0));
      expect(closed.single.reason, startsWith('익절'));
    });

    test('closed on weekend', () async {
      final e = make(RiskConfig(budgetPerTrade: 200000));
      now = DateTime(2026, 9, 26, 10);
      strategy.signal = Signal.buy;
      await e.tick();
      expect(broker.positions, isEmpty);
    });

    test('daily loss limit blocks new entries', () async {
      final e = make(RiskConfig(budgetPerTrade: 200000, stopLossPct: 3, dailyLossLimitPct: 0.1));
      strategy.signal = Signal.buy;
      await e.tick();
      market.price = 9000;
      await e.tick();
      expect(broker.positions, isEmpty);
      await e.tick();
      expect(broker.positions, isEmpty);
      expect(e.status['005930'], contains('일일 손실 한도'));
    });

    test('cooldown after consecutive losses', () async {
      final e = make(RiskConfig(budgetPerTrade: 200000, maxConsecutiveLosses: 2, cooldownHours: 2));
      for (var i = 0; i < 2; i++) {
        history.add(TradeRecord(time: now, symbol: '005930', side: 'sell', qty: 1, price: 1, pnl: -100));
      }
      strategy.signal = Signal.buy;
      await e.tick();
      expect(broker.positions, isEmpty);
      expect(e.status['005930'], contains('쿨다운'));
      now = now.add(const Duration(hours: 3));
      await e.tick();
      expect(broker.positions, isNotEmpty);
    });

    test('average down only once', () async {
      final e = make(RiskConfig(budgetPerTrade: 200000, stopLossPct: 10, averageDownPct: 4));
      strategy.signal = Signal.buy;
      await e.tick();
      strategy.signal = Signal.hold;
      market.price = 9500;
      await e.tick();
      expect(broker.positions['005930']!.qty, 38);
      market.price = 9000;
      await e.tick();
      expect(broker.positions['005930']!.qty, 38);
    });

    test('force exit before close', () async {
      final e = make(RiskConfig(budgetPerTrade: 200000, exitMinutesBeforeClose: 10));
      strategy.signal = Signal.buy;
      await e.tick();
      now = DateTime(2026, 9, 25, 15, 25);
      strategy.signal = Signal.hold;
      await e.tick();
      expect(broker.positions, isEmpty);
    });
  });

  test('history stats & encode round trip', () {
    final h = TradeHistory();
    h.add(TradeRecord(time: DateTime(2026, 9, 25, 10), symbol: 'A', side: 'sell', qty: 1, price: 1, pnl: 300));
    h.add(TradeRecord(time: DateTime(2026, 9, 25, 11), symbol: 'A', side: 'sell', qty: 1, price: 1, pnl: -100));
    final s = h.stats();
    expect(s.trades, 2);
    expect(s.winRate, 50);
    expect(s.profitFactor, 3);
    expect(h.realizedOn(DateTime(2026, 9, 25, 15)), 200);
    expect(TradeHistory.decode(h.encode()).length, 2);
  });
}
