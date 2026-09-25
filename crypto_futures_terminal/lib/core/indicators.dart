import 'dart:math' as math;

import 'models.dart';

List<double> closes(List<Candle> c) => [for (final x in c) x.close];

/// 단순 이동평균. 값이 부족한 앞부분은 NaN.
List<double> sma(List<double> v, int period) {
  final out = List<double>.filled(v.length, double.nan);
  double sum = 0;
  for (var i = 0; i < v.length; i++) {
    sum += v[i];
    if (i >= period) sum -= v[i - period];
    if (i >= period - 1) out[i] = sum / period;
  }
  return out;
}

/// 지수 이동평균. 첫 값은 SMA 로 시드한다.
List<double> ema(List<double> v, int period) {
  final out = List<double>.filled(v.length, double.nan);
  if (v.length < period) return out;
  final k = 2 / (period + 1);
  double prev = v.take(period).reduce((a, b) => a + b) / period;
  out[period - 1] = prev;
  for (var i = period; i < v.length; i++) {
    prev = v[i] * k + prev * (1 - k);
    out[i] = prev;
  }
  return out;
}

/// Wilder 방식 RSI.
List<double> rsi(List<double> v, [int period = 14]) {
  final out = List<double>.filled(v.length, double.nan);
  if (v.length <= period) return out;
  double gain = 0, loss = 0;
  for (var i = 1; i <= period; i++) {
    final d = v[i] - v[i - 1];
    if (d >= 0) {
      gain += d;
    } else {
      loss -= d;
    }
  }
  gain /= period;
  loss /= period;
  out[period] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss);
  for (var i = period + 1; i < v.length; i++) {
    final d = v[i] - v[i - 1];
    gain = (gain * (period - 1) + math.max(d, 0)) / period;
    loss = (loss * (period - 1) + math.max(-d, 0)) / period;
    out[i] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss);
  }
  return out;
}

double lastValid(List<double> v) {
  for (var i = v.length - 1; i >= 0; i--) {
    if (!v[i].isNaN) return v[i];
  }
  return double.nan;
}

/// 격리 마진 기준 예상 강제청산가 (유지증거금률 0.5% 가정, 수수료 무시).
double estimateLiquidationPrice(double entry, int leverage, Side side,
    {double maintenanceMarginRate = 0.005}) {
  if (leverage <= 0) return double.nan;
  final move = 1 / leverage - maintenanceMarginRate;
  return side == Side.long ? entry * (1 - move) : entry * (1 + move);
}

/// 매수/매도 게이지: -100(강한 매도) ~ +100(강한 매수).
/// RSI, 단기/장기 이평 위치, 최근 모멘텀을 합산한 참고용 점수.
double buySellScore(List<Candle> candles) {
  if (candles.length < 30) return 0;
  final c = closes(candles);
  final r = lastValid(rsi(c));
  final f = lastValid(ema(c, 9));
  final s = lastValid(ema(c, 21));
  final last = c.last;
  double score = 0;
  if (!r.isNaN) score += ((50 - r) / 50).clamp(-1.0, 1.0) * -40; // RSI 높을수록 매수 우위
  if (!f.isNaN && !s.isNaN && s > 0) {
    score += ((f - s) / s * 1000).clamp(-1.0, 1.0) * 35;
  }
  final ref = c[c.length - 10];
  if (ref > 0) score += ((last - ref) / ref * 200).clamp(-1.0, 1.0) * 25;
  return score.clamp(-100.0, 100.0);
}
