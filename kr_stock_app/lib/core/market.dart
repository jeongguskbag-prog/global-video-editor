// KRX 시장 규칙: 호가단위, 운영시간(KST), 거래비용.
import 'dart:math' as math;

const _tickTable = [
  [2000, 1],
  [5000, 5],
  [20000, 10],
  [50000, 50],
  [200000, 100],
  [500000, 500],
];

int tickSize(double price) {
  for (final row in _tickTable) {
    if (price < row[0]) return row[1];
  }
  return 1000;
}

/// direction: 'down' | 'up' | 'nearest'
int roundToTick(double price, [String direction = 'nearest']) {
  if (price <= 0) return 0;
  final tick = tickSize(price);
  final units = price / tick;
  final n = switch (direction) {
    'down' => (units + 1e-9).floor(),
    'up' => (units - 1e-9).ceil(),
    _ => units.round(),
  };
  final result = n * tick;
  if (tickSize(result.toDouble()) != tick) return roundToTick(result.toDouble(), direction);
  return result;
}

/// 한국 시간(UTC+9). 기기 시간대와 무관하게 계산한다.
DateTime nowKst([DateTime? utcNow]) => (utcNow ?? DateTime.now().toUtc()).toUtc().add(const Duration(hours: 9));

String ymd(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}';

/// 정규장 평일 09:00~15:30. [kst] 는 nowKst() 로 만든 값.
bool isMarketOpen(DateTime kst, [Set<String> holidays = const {}]) {
  if (kst.weekday >= DateTime.saturday || holidays.contains(ymd(kst))) return false;
  final minutes = kst.hour * 60 + kst.minute;
  return minutes >= 9 * 60 && minutes < 15 * 60 + 30;
}

double minutesToClose(DateTime kst) =>
    (15 * 60 + 30) - (kst.hour * 60 + kst.minute + kst.second / 60.0);

double buyCost(double price, int qty, double feeRate) {
  final amount = price * qty;
  return amount + amount * feeRate;
}

double sellProceeds(double price, int qty, double feeRate, double taxRate) {
  final amount = price * qty;
  return amount - amount * feeRate - amount * taxRate;
}

double parseNum(Object? v, [double fallback = 0]) {
  if (v == null) return fallback;
  final s = v.toString().replaceAll(',', '').trim();
  if (s.isEmpty) return fallback;
  final n = double.tryParse(s);
  return n == null ? fallback : n.abs();
}

double clampDouble(double v, double lo, double hi) => math.max(lo, math.min(hi, v));
