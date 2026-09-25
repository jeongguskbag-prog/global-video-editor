// 매매 전략. 현금 계좌라 BUY(신규 매수) / SELL(보유분 청산) / HOLD 세 가지 신호만 낸다.
import 'indicators.dart';
import 'models.dart';

enum Signal { buy, sell, hold }

class StrategyResult {
  final Signal signal;
  final String reason;
  const StrategyResult(this.signal, this.reason);
}

abstract class Strategy {
  String get name;
  String get label;
  int get minCandles;
  StrategyResult evaluate(List<Candle> candles);
}

class MaCrossStrategy implements Strategy {
  final int short, long;
  MaCrossStrategy({this.short = 9, this.long = 21}) {
    if (short >= long) throw ArgumentError('short 기간은 long 기간보다 작아야 합니다');
  }
  @override
  String get name => 'ma_cross';
  @override
  String get label => 'MA 크로스 ($short/$long)';
  @override
  int get minCandles => long + 2;

  @override
  StrategyResult evaluate(List<Candle> candles) {
    if (candles.length < minCandles) return const StrategyResult(Signal.hold, '캔들 부족');
    final c = candles.map((e) => e.close).toList();
    final s = ema(c, short), l = ema(c, long);
    final prev = s[s.length - 2]! - l[l.length - 2]!, cur = s.last! - l.last!;
    if (prev <= 0 && cur > 0) return StrategyResult(Signal.buy, '골든크로스 EMA$short/$long');
    if (prev >= 0 && cur < 0) return StrategyResult(Signal.sell, '데드크로스 EMA$short/$long');
    return StrategyResult(Signal.hold, '대기 (EMA 차이 ${cur.toStringAsFixed(1)})');
  }
}

class RsiStrategy implements Strategy {
  final int period;
  final double oversold, overbought;
  RsiStrategy({this.period = 14, this.oversold = 30, this.overbought = 70});
  @override
  String get name => 'rsi';
  @override
  String get label => 'RSI 과매수/과매도';
  @override
  int get minCandles => period + 3;

  @override
  StrategyResult evaluate(List<Candle> candles) {
    if (candles.length < minCandles) return const StrategyResult(Signal.hold, '캔들 부족');
    final r = rsi(candles.map((e) => e.close).toList(), period);
    final prev = r[r.length - 2]!, cur = r.last!;
    if (prev < oversold && cur >= oversold) {
      return StrategyResult(Signal.buy, 'RSI 과매도 탈출 (${prev.toStringAsFixed(1)}→${cur.toStringAsFixed(1)})');
    }
    if (prev > overbought && cur <= overbought) {
      return StrategyResult(Signal.sell, 'RSI 과매수 이탈 (${prev.toStringAsFixed(1)}→${cur.toStringAsFixed(1)})');
    }
    return StrategyResult(Signal.hold, '대기 (RSI ${cur.toStringAsFixed(1)})');
  }
}

class MaRsiStrategy implements Strategy {
  final int short, long, rsiPeriod;
  final double rsiEntryMax, rsiExit;
  MaRsiStrategy({this.short = 9, this.long = 21, this.rsiPeriod = 14, this.rsiEntryMax = 60, this.rsiExit = 75});
  @override
  String get name => 'ma_rsi';
  @override
  String get label => 'MA + RSI 결합';
  @override
  int get minCandles => (long + 2) > (rsiPeriod + 3) ? long + 2 : rsiPeriod + 3;

  @override
  StrategyResult evaluate(List<Candle> candles) {
    if (candles.length < minCandles) return const StrategyResult(Signal.hold, '캔들 부족');
    final c = candles.map((e) => e.close).toList();
    final s = ema(c, short), l = ema(c, long);
    final r = rsi(c, rsiPeriod).last!;
    final up = s.last! > l.last!, prevUp = s[s.length - 2]! > l[l.length - 2]!;
    if (up && !prevUp && r <= rsiEntryMax) {
      return StrategyResult(Signal.buy, '골든크로스 + RSI ${r.toStringAsFixed(1)}');
    }
    if ((prevUp && !up) || r >= rsiExit) {
      return StrategyResult(Signal.sell, '추세 이탈/과열 (RSI ${r.toStringAsFixed(1)})');
    }
    return StrategyResult(Signal.hold, '대기 (RSI ${r.toStringAsFixed(1)})');
  }
}

const strategyNames = {'ma_cross': 'MA 크로스 (9/21)', 'rsi': 'RSI 과매수/과매도', 'ma_rsi': 'MA + RSI 결합'};

Strategy buildStrategy(String name) => switch (name) {
      'ma_cross' => MaCrossStrategy(),
      'rsi' => RsiStrategy(),
      _ => MaRsiStrategy(),
    };

/// 종가가 장기 이동평균 위에 있을 때만 신규 매수 허용. 데이터가 모자라면 통과.
bool trendFilterOk(List<Candle> candles, int period) {
  final m = sma(candles.map((e) => e.close).toList(), period);
  if (m.isEmpty || m.last == null) return true;
  return candles.last.close >= m.last!;
}
