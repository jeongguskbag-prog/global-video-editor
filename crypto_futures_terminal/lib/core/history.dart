import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 기기에 저장되는 거래 내역. 실제 거래소 기록에는 영향이 없다.
class TradeHistoryStore {
  static const _key = 'trade_history_v1';
  static const _max = 1000;

  final List<TradeRecord> _items = [];
  List<TradeRecord> get items => List.unmodifiable(_items);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    _items.clear();
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _items.addAll(list.map((e) => TradeRecord.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      // 손상된 데이터는 무시
    }
  }

  Future<void> add(TradeRecord r) async {
    _items.insert(0, r);
    if (_items.length > _max) _items.removeRange(_max, _items.length);
    await _save();
  }

  Future<void> clear() async {
    _items.clear();
    await _save();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(_items.map((e) => e.toJson()).toList()));
  }

  HistoryStats stats({bool? live}) =>
      HistoryStats.of(live == null ? _items : _items.where((e) => e.live == live));
}

class HistoryStats {
  final int count, wins;
  final double totalPnl, grossProfit, grossLoss;

  const HistoryStats(this.count, this.wins, this.totalPnl, this.grossProfit, this.grossLoss);

  factory HistoryStats.of(Iterable<TradeRecord> it) {
    int n = 0, w = 0;
    double total = 0, gp = 0, gl = 0;
    for (final t in it) {
      n++;
      total += t.pnl;
      if (t.pnl > 0) {
        w++;
        gp += t.pnl;
      } else {
        gl -= t.pnl;
      }
    }
    return HistoryStats(n, w, total, gp, gl);
  }

  double get winRate => count == 0 ? 0 : wins / count * 100;
  double get avgPnl => count == 0 ? 0 : totalPnl / count;
  double? get profitFactor => grossLoss == 0 ? null : grossProfit / grossLoss;
}
