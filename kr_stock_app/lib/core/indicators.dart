// 기술적 지표 (오래된 값 → 최신 값 순서).
List<double?> sma(List<double> v, int period) {
  final out = List<double?>.filled(v.length, null);
  if (period <= 0) return out;
  var sum = 0.0;
  for (var i = 0; i < v.length; i++) {
    sum += v[i];
    if (i >= period) sum -= v[i - period];
    if (i >= period - 1) out[i] = sum / period;
  }
  return out;
}

List<double?> ema(List<double> v, int period) {
  final out = List<double?>.filled(v.length, null);
  if (period <= 0 || v.length < period) return out;
  final k = 2.0 / (period + 1);
  var prev = v.sublist(0, period).reduce((a, b) => a + b) / period;
  out[period - 1] = prev;
  for (var i = period; i < v.length; i++) {
    prev = v[i] * k + prev * (1 - k);
    out[i] = prev;
  }
  return out;
}

/// Wilder RSI
List<double?> rsi(List<double> v, [int period = 14]) {
  final out = List<double?>.filled(v.length, null);
  if (v.length <= period) return out;
  var gains = 0.0, losses = 0.0;
  for (var i = 1; i <= period; i++) {
    final d = v[i] - v[i - 1];
    if (d > 0) {
      gains += d;
    } else {
      losses -= d;
    }
  }
  var ag = gains / period, al = losses / period;
  out[period] = _rsi(ag, al);
  for (var i = period + 1; i < v.length; i++) {
    final d = v[i] - v[i - 1];
    ag = (ag * (period - 1) + (d > 0 ? d : 0)) / period;
    al = (al * (period - 1) + (d < 0 ? -d : 0)) / period;
    out[i] = _rsi(ag, al);
  }
  return out;
}

double _rsi(double ag, double al) {
  if (al == 0) return ag > 0 ? 100 : 50;
  return 100 - 100 / (1 + ag / al);
}
