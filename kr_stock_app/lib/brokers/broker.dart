// 증권사 공통 인터페이스와 HTTP 도우미.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/models.dart';

export '../core/models.dart';

abstract class Broker {
  String get name;
  bool get live;
  Future<Quote> getQuote(String symbol);

  /// 오래된 → 최신 순서
  Future<List<Candle>> getCandles(String symbol, String interval, int count);
  Future<Balance> getBalance();
  Future<OrderResult> placeOrder(String symbol, Side side, int qty, OrderType type, double price);
}

/// 토큰 등 작은 값을 보관하는 저장소 (앱에서는 보안 저장소, 테스트에서는 메모리).
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

/// 발급 토큰을 만료 5분 전까지 재사용한다 (KIS 는 1분 1회 발급 제한).
class TokenCache {
  final KeyValueStore store;
  TokenCache(this.store);

  Future<String?> load(String key) async {
    final raw = await store.read('token_$key');
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map;
      final exp = (j['exp'] as num).toInt();
      if (exp - 300 > DateTime.now().millisecondsSinceEpoch ~/ 1000) return j['token'] as String?;
    } catch (_) {}
    return null;
  }

  Future<void> save(String key, String token, int expiresInSeconds) => store.write(
      'token_$key', jsonEncode({'token': token, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresInSeconds}));

  Future<void> clear(String key) => store.write('token_$key', '');
}

/// 호출 간 최소 간격을 지킨다.
class RateLimiter {
  final Duration minInterval;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  RateLimiter(this.minInterval);

  Future<void> wait() async {
    final delta = DateTime.now().difference(_last);
    if (delta < minInterval) await Future<void>.delayed(minInterval - delta);
    _last = DateTime.now();
  }
}

class JsonResponse {
  final int status;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
  JsonResponse(this.status, this.body, this.headers);
}

Future<JsonResponse> sendJson(http.Client client, String method, Uri uri,
    {Map<String, String>? headers, Object? body, Map<String, String>? form}) async {
  final req = http.Request(method, uri);
  if (headers != null) req.headers.addAll(headers);
  if (form != null) {
    req.bodyFields = form;
  } else if (body != null) {
    req.body = jsonEncode(body);
  }
  late http.Response res;
  try {
    res = await http.Response.fromStream(await client.send(req).timeout(const Duration(seconds: 15)));
  } catch (e) {
    throw BrokerException('네트워크 오류: $e');
  }
  Map<String, dynamic> data;
  try {
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    data = decoded is Map ? decoded.cast<String, dynamic>() : {'_list': decoded};
  } catch (_) {
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    throw BrokerException('응답 오류 HTTP ${res.statusCode}: ${text.length > 200 ? text.substring(0, 200) : text}');
  }
  return JsonResponse(res.statusCode, data, res.headers);
}

/// 1분봉을 N분봉으로 묶는다 (09:00 기준).
List<Candle> resampleMinutes(List<Candle> candles, int minutes) {
  if (minutes <= 1) return candles;
  final out = <Candle>[];
  String? key;
  for (final c in candles) {
    final since = c.time.hour * 60 + c.time.minute - 9 * 60;
    final k = '${c.time.year}${c.time.month}${c.time.day}:${since ~/ minutes}';
    if (k != key) {
      key = k;
      out.add(c);
    } else {
      final b = out.removeLast();
      out.add(Candle(b.time, b.open, c.high > b.high ? c.high : b.high, c.low < b.low ? c.low : b.low, c.close,
          b.volume + c.volume));
    }
  }
  return out;
}

List<Candle> sortedTail(Map<DateTime, Candle> m, int count) {
  final keys = m.keys.toList()..sort();
  final list = keys.map((k) => m[k]!).toList();
  return list.length > count ? list.sublist(list.length - count) : list;
}

DateTime parseYmd(String s) => DateTime(int.parse(s.substring(0, 4)), int.parse(s.substring(4, 6)), int.parse(s.substring(6, 8)));

DateTime parseYmdHms(String date, String hms) {
  final t = hms.padLeft(6, '0');
  return DateTime(int.parse(date.substring(0, 4)), int.parse(date.substring(4, 6)), int.parse(date.substring(6, 8)),
      int.parse(t.substring(0, 2)), int.parse(t.substring(2, 4)), int.parse(t.substring(4, 6)));
}

int? minutesOf(String interval) => parseInterval(interval);
