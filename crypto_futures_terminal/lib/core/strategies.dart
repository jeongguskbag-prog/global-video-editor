import 'indicators.dart';
import 'models.dart';

/// 마지막 "완성된" 봉까지만 보고 신호를 낸다 (진행 중인 봉은 제외).
Signal evaluateStrategy(StrategyType type, List<Candle> candles) {
  if (candles.length < 30) return const Signal.none('봉 데이터 부족');
  final done = candles.sublist(0, candles.length - 1);
  final c = closes(done);
  return switch (type) {
    StrategyType.maCross => _maCross(c),
    StrategyType.rsi => _rsi(c),
    StrategyType.maRsi => _maRsi(c),
    StrategyType.enterAtLow => _enterAtLow(done),
    StrategyType.resistanceHigh => _resistanceHigh(done),
  };
}

String _f(double v, [int digits = 2]) => v.isNaN ? '-' : v.toStringAsFixed(digits);

Signal _maCross(List<double> c) {
  final fast = ema(c, 9), slow = ema(c, 21);
  final n = c.length - 1;
  final pf = fast[n - 1], ps = slow[n - 1], f = fast[n], s = slow[n];
  if ([pf, ps, f, s].any((v) => v.isNaN)) return const Signal.none('봉 데이터 부족');
  if (pf <= ps && f > s) return Signal(Side.long, '골든크로스 (MA9 ${_f(f)} > MA21 ${_f(s)})');
  if (pf >= ps && f < s) return Signal(Side.short, '데드크로스 (MA9 ${_f(f)} < MA21 ${_f(s)})');
  final gap = s == 0 ? 0 : (f - s) / s * 100;
  return Signal.none('대기 중 (MA 차이 ${gap.toStringAsFixed(3)}%)');
}

Signal _rsi(List<double> c) {
  final r = rsi(c);
  final n = c.length - 1;
  final prev = r[n - 1], cur = r[n];
  if (prev.isNaN || cur.isNaN) return const Signal.none('봉 데이터 부족');
  // 과매도 구간에서 위로 빠져나올 때 롱, 과매수 구간에서 아래로 빠져나올 때 숏.
  if (prev < 30 && cur >= 30) return Signal(Side.long, 'RSI 과매도 이탈 (${_f(cur, 1)})');
  if (prev > 70 && cur <= 70) return Signal(Side.short, 'RSI 과매수 이탈 (${_f(cur, 1)})');
  return Signal.none('대기 중 (RSI ${_f(cur, 1)})');
}

Signal _maRsi(List<double> c) {
  final ma = _maCross(c);
  if (ma.side == null) return ma;
  final r = lastValid(rsi(c));
  if (ma.side == Side.long && r < 70) return Signal(Side.long, '${ma.reason} + RSI ${_f(r, 1)}');
  if (ma.side == Side.short && r > 30) return Signal(Side.short, '${ma.reason} + RSI ${_f(r, 1)}');
  return Signal.none('크로스 발생했지만 RSI ${_f(r, 1)} 로 보류');
}

/// 최근 20봉 최저가 부근에서 반등(양봉)하면 롱.
Signal _enterAtLow(List<Candle> d) {
  final window = d.sublist(d.length - 21, d.length - 1);
  final low = window.map((e) => e.low).reduce((a, b) => a < b ? a : b);
  final last = d.last;
  final near = (last.low - low) / low * 100;
  if (near <= 0.1 && last.close > last.open) {
    return Signal(Side.long, '20봉 최저가 ${_f(low)} 부근 반등');
  }
  return Signal.none('대기 중 (최저가 대비 ${near.toStringAsFixed(2)}%)');
}

/// 최근 20봉 최고가 저항에서 밀리면(음봉) 숏.
Signal _resistanceHigh(List<Candle> d) {
  final window = d.sublist(d.length - 21, d.length - 1);
  final high = window.map((e) => e.high).reduce((a, b) => a > b ? a : b);
  final last = d.last;
  final near = (high - last.high) / high * 100;
  if (near <= 0.1 && last.close < last.open) {
    return Signal(Side.short, '20봉 최고가 ${_f(high)} 저항 확인');
  }
  return Signal.none('대기 중 (최고가 대비 ${near.toStringAsFixed(2)}%)');
}

/// 상위 타임프레임 추세 필터: 1시간봉 EMA200 위면 롱만, 아래면 숏만 허용.
bool trendAllows(Side side, List<Candle> hourly) {
  final e = lastValid(ema(closes(hourly), 200));
  if (e.isNaN) return true; // 데이터 부족 시 필터 통과
  final last = hourly.last.close;
  return side == Side.long ? last >= e : last <= e;
}
