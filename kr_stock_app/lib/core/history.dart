// 체결 기록과 통계.
import 'dart:convert';

class TradeRecord {
  final DateTime time; // KST
  final String symbol, side, reason, orderId, broker;
  final int qty;
  final double price;
  final double? pnl;
  const TradeRecord({
    required this.time,
    required this.symbol,
    required this.side,
    required this.qty,
    required this.price,
    this.reason = '',
    this.pnl,
    this.orderId = '',
    this.broker = '',
  });

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        's': symbol,
        'd': side,
        'q': qty,
        'p': price,
        'r': reason,
        'l': pnl,
        'o': orderId,
        'b': broker,
      };

  factory TradeRecord.fromJson(Map<String, dynamic> j) => TradeRecord(
        time: DateTime.parse(j['t'] as String),
        symbol: j['s'] as String,
        side: j['d'] as String,
        qty: (j['q'] as num).toInt(),
        price: (j['p'] as num).toDouble(),
        reason: j['r'] as String? ?? '',
        pnl: (j['l'] as num?)?.toDouble(),
        orderId: j['o'] as String? ?? '',
        broker: j['b'] as String? ?? '',
      );
}

class TradeStats {
  final int trades, wins, losses;
  final double winRate, totalPnl;
  final double? profitFactor;
  const TradeStats(this.trades, this.wins, this.losses, this.winRate, this.totalPnl, this.profitFactor);
}

class TradeHistory {
  final List<TradeRecord> records;
  final void Function(List<TradeRecord>)? onChanged;
  TradeHistory([List<TradeRecord>? initial, this.onChanged]) : records = initial ?? [];

  void add(TradeRecord r) {
    records.add(r);
    if (records.length > 2000) records.removeRange(0, records.length - 2000);
    onChanged?.call(records);
  }

  void clear() {
    records.clear();
    onChanged?.call(records);
  }

  Iterable<TradeRecord> get closed => records.where((r) => r.pnl != null);

  double realizedOn(DateTime kst) =>
      closed.where((r) => _sameDay(r.time, kst)).fold(0.0, (a, r) => a + r.pnl!);

  /// (연속 손실 횟수, 마지막 손실 시각)
  (int, DateTime?) consecutiveLosses() {
    var count = 0;
    DateTime? last;
    for (final r in closed.toList().reversed) {
      if (r.pnl! < 0) {
        count++;
        last ??= r.time;
      } else {
        break;
      }
    }
    return (count, last);
  }

  TradeStats stats() {
    final c = closed.toList();
    final wins = c.where((r) => r.pnl! > 0).toList();
    final losses = c.where((r) => r.pnl! <= 0).toList();
    final gw = wins.fold(0.0, (a, r) => a + r.pnl!);
    final gl = -losses.fold(0.0, (a, r) => a + r.pnl!);
    return TradeStats(c.length, wins.length, losses.length, c.isEmpty ? 0 : wins.length / c.length * 100, gw - gl,
        gl > 0 ? gw / gl : null);
  }

  String encode() => jsonEncode(records.map((e) => e.toJson()).toList());
  static List<TradeRecord> decode(String? s) {
    if (s == null || s.isEmpty) return [];
    try {
      return (jsonDecode(s) as List).map((e) => TradeRecord.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
