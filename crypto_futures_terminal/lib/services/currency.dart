import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

/// USDT 금액을 사용자가 고른 통화로 환산해 보여준다 (1 USDT ≈ 1 USD 가정).
class CurrencyService {
  static const supported = ['USD', 'KRW', 'JPY', 'EUR', 'CNY', 'GBP', 'INR', 'VND', 'IDR', 'TRY'];

  Map<String, double> _rates = {'USD': 1};
  DateTime? _fetchedAt;

  Future<void> refresh() async {
    if (_fetchedAt != null && DateTime.now().difference(_fetchedAt!).inHours < 6) return;
    try {
      final r = await http
          .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      _rates = (j['rates'] as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
      _fetchedAt = DateTime.now();
    } catch (_) {}
  }

  /// "12.34 USDT (≈ ₩16,800)" 형태. USD 선택 시 USDT 만 표시.
  String format(double usdt, String currency, {bool signed = false}) {
    final sign = signed && usdt > 0 ? '+' : '';
    final base = '$sign${usdt.toStringAsFixed(2)} USDT';
    final rate = _rates[currency];
    if (currency == 'USD' || rate == null) return base;
    final f = NumberFormat.simpleCurrency(name: currency);
    return '$base (≈ $sign${f.format(usdt * rate)})';
  }
}
