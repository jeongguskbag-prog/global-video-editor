import 'package:flutter_test/flutter_test.dart';
import 'package:global_futures_terminal/core/config.dart';
import 'package:global_futures_terminal/core/indicators.dart';
import 'package:global_futures_terminal/core/models.dart';
import 'package:global_futures_terminal/core/risk.dart';
import 'package:global_futures_terminal/core/strategies.dart';

List<Candle> series(List<double> closes) => [
      for (var i = 0; i < closes.length; i++)
        Candle(
          time: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          open: i == 0 ? closes[0] : closes[i - 1],
          high: closes[i] * 1.001,
          low: closes[i] * 0.999,
          close: closes[i],
          volume: 1,
        )
    ];

void main() {
  test('sma / ema / rsi 기본값', () {
    final v = [for (var i = 1; i <= 20; i++) i.toDouble()];
    expect(sma(v, 5).last, 18);
    expect(ema(v, 5).last, closeTo(18, 1e-9)); // 선형 증가 수열은 EMA 도 2 lag
    expect(rsi(v).last, 100); // 하락이 없으면 RSI 100
  });

  test('MA 크로스: 하락 후 급반등하면 롱 신호', () {
    final c = [for (var i = 0; i < 40; i++) 100.0 - i * 0.5];
    // 마지막 완성봉에서 골든크로스가 나도록 급등 후, 진행 중인 봉 1개 추가
    var sig = const Signal.none('');
    for (var bump = 1; bump < 30 && sig.side == null; bump++) {
      final s = [...c, for (var k = 1; k <= bump; k++) 80.0 + k * 3, 0.0];
      sig = evaluateStrategy(StrategyType.maCross, series(s));
    }
    expect(sig.side, Side.long);
  });

  test('리스크: 고정 마진 / 리스크 % 수량 계산', () {
    final cfg = TradingConfig(leverage: 10, marginPerTrade: 20, stopLossPct: 2);
    final r = RiskManager(cfg);
    expect(r.entryQty(price: 100, balance: 1000), closeTo(2, 1e-9)); // 20*10/100
    cfg.riskPerTradePct = 1; // 1000 의 1% = 10 USDT 손실 한도 → 명목 500
    expect(r.entryQty(price: 100, balance: 1000), closeTo(5, 1e-9));
    expect(r.stopLossPrice(Side.long, 100), closeTo(98, 1e-9));
    expect(r.takeProfitPrice(Side.short, 100), closeTo(96, 1e-9));
  });

  test('물타기 발동 조건', () {
    final cfg = TradingConfig(stopLossPct: 2, averageDownEnabled: true, averageDownPct: 1.8);
    final r = RiskManager(cfg);
    const p = Position(coin: 'BTC', side: Side.short, entryPrice: 100, qty: 1, leverage: 5);
    expect(r.shouldAverageDown(p, 101, false), isFalse);
    expect(r.shouldAverageDown(p, 101.9, false), isTrue);
    expect(r.shouldAverageDown(p, 101.9, true), isFalse);
  });

  test('설정 검증', () {
    expect(TradingConfig().validate(), isNull);
    expect(TradingConfig(averageDownEnabled: true, averageDownPct: 3, stopLossPct: 2).validate(),
        isNotNull);
    expect(TradingConfig(riskPerTradePct: 1, stopLossPct: null).validate(), isNotNull);
    final round = TradingConfig.fromJson(TradingConfig(coin: 'SOL', leverage: 7).toJson());
    expect(round.coin, 'SOL');
    expect(round.leverage, 7);
  });

  test('연속 손절 쿨다운 / 일일 손실 한도', () {
    final cfg = TradingConfig(cooldownLosses: 2, cooldownHours: 1, dailyLossLimitPct: 5);
    final s = RiskState()..rollDay(1000);
    s.onClosed(-10, cfg);
    expect(s.cooldownRemaining(), isNull);
    s.onClosed(-10, cfg);
    expect(s.cooldownRemaining(), isNotNull);
    expect(s.exceedsDailyLimit(cfg, -29), isFalse); // -20 실현 -29 미실현 = -49
    expect(s.exceedsDailyLimit(cfg, -30), isTrue);
  });

  test('예상 강제청산가', () {
    expect(estimateLiquidationPrice(100, 10, Side.long), closeTo(90.5, 1e-9));
    expect(estimateLiquidationPrice(100, 10, Side.short), closeTo(109.5, 1e-9));
  });
}
