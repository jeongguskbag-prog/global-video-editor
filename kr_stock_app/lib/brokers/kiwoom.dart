// 키움증권 REST API (국내주식).
import 'package:http/http.dart' as http;

import '../core/market.dart';
import 'broker.dart';

const _nativeMinutes = [1, 3, 5, 10, 15, 30, 45, 60];

double _signed(Object? v, [double fallback = 0]) {
  final s = (v ?? '').toString().replaceAll(',', '').trim();
  return s.isEmpty ? fallback : (double.tryParse(s) ?? fallback);
}

class KiwoomBroker implements Broker {
  final String appKey, secretKey;
  @override
  final bool live;
  final http.Client client;
  final TokenCache tokens;
  final RateLimiter limiter;
  String? _token;

  KiwoomBroker(this.appKey, this.secretKey,
      {this.live = false, http.Client? client, KeyValueStore? store, Duration rateInterval = const Duration(milliseconds: 250)})
      : client = client ?? http.Client(),
        tokens = TokenCache(store ?? MemoryStore()),
        limiter = RateLimiter(rateInterval) {
    if (appKey.isEmpty || secretKey.isEmpty) throw BrokerException('키움 App Key / Secret Key 를 입력하세요');
  }

  @override
  String get name => 'kiwoom';
  String get baseUrl => live ? 'https://api.kiwoom.com' : 'https://mockapi.kiwoom.com';
  String get _tokenKey => 'kiwoom_${live}_${appKey.hashCode}';

  Future<String> _accessToken() async {
    if (_token != null) return _token!;
    final cached = await tokens.load(_tokenKey);
    if (cached != null) return _token = cached;
    final r = await sendJson(client, 'POST', Uri.parse('$baseUrl/oauth2/token'),
        headers: {'content-type': 'application/json;charset=UTF-8'},
        body: {'grant_type': 'client_credentials', 'appkey': appKey, 'secretkey': secretKey});
    final token = r.body['token'] as String?;
    if (token == null) throw BrokerException('키움 토큰 발급 실패: ${r.body['return_msg'] ?? r.body}');
    var ttl = 12 * 3600;
    final exp = '${r.body['expires_dt'] ?? ''}';
    if (exp.length == 14) {
      final t = parseYmdHms(exp.substring(0, 8), exp.substring(8));
      ttl = t.difference(nowKst()).inSeconds;
    }
    await tokens.save(_tokenKey, token, ttl);
    return _token = token;
  }

  Future<JsonResponse> _post(String path, String apiId, Map<String, dynamic> body,
      {String contYn = 'N', String nextKey = ''}) async {
    await limiter.wait();
    final r = await sendJson(client, 'POST', Uri.parse('$baseUrl$path'), headers: {
      'content-type': 'application/json;charset=UTF-8',
      'authorization': 'Bearer ${await _accessToken()}',
      'api-id': apiId,
      'cont-yn': contYn,
      'next-key': nextKey,
    }, body: body);
    if ('${r.body['return_code'] ?? 0}' != '0') {
      throw BrokerException('키움 $apiId 실패 [${r.body['return_code']}] ${r.body['return_msg'] ?? ''}');
    }
    return r;
  }

  @override
  Future<Quote> getQuote(String symbol) async {
    final info = await _post('/api/dostk/stkinfo', 'ka10001', {'stk_cd': symbol});
    final price = parseNum(info.body['cur_prc']);
    double? bid, ask;
    try {
      final b = await _post('/api/dostk/mrkcond', 'ka10004', {'stk_cd': symbol});
      ask = parseNum(b.body['sel_fpr_bid']);
      bid = parseNum(b.body['buy_fpr_bid']);
    } on BrokerException {
      // 호가 실패 시 스프레드 필터만 생략
    }
    return Quote(symbol, price, bid: bid == 0 ? null : bid, ask: ask == 0 ? null : ask);
  }

  @override
  Future<List<Candle>> getCandles(String symbol, String interval, int count) async {
    final minutes = minutesOf(interval);
    if (minutes == null) {
      return _chart(symbol, 'ka10081', {'base_dt': ymd(nowKst())}, 'stk_dt_pole_chart_qry', 'dt', count);
    }
    final native = _nativeMinutes.contains(minutes) ? minutes : 1;
    final c = await _chart(symbol, 'ka10080', {'tic_scope': '$native'}, 'stk_min_pole_chart_qry', 'cntr_tm',
        count * minutes ~/ native);
    final res = resampleMinutes(c, native == 1 ? minutes : 1);
    return res.length > count ? res.sublist(res.length - count) : res;
  }

  Future<List<Candle>> _chart(String symbol, String apiId, Map<String, String> extra, String listKey, String timeKey,
      int count) async {
    final m = <DateTime, Candle>{};
    var cont = 'N', key = '';
    for (var i = 0; i < 10; i++) {
      final r = await _post('/api/dostk/chart', apiId, {'stk_cd': symbol, 'upd_stkpc_tp': '1', ...extra},
          contYn: cont, nextKey: key);
      for (final row in ((r.body[listKey] as List?) ?? []).cast<Map>()) {
        final ts = '${row[timeKey] ?? ''}';
        if (ts.length < 8) continue;
        final t = ts.length >= 14 ? parseYmdHms(ts.substring(0, 8), ts.substring(8, 14)) : parseYmd(ts);
        m[t] = Candle(t, parseNum(row['open_pric']), parseNum(row['high_pric']), parseNum(row['low_pric']),
            parseNum(row['cur_prc']), parseNum(row['trde_qty']));
      }
      cont = r.headers['cont-yn'] ?? 'N';
      key = r.headers['next-key'] ?? '';
      if (m.length >= count || cont != 'Y' || key.isEmpty) break;
    }
    return sortedTail(m, count);
  }

  @override
  Future<Balance> getBalance() async {
    final dep = await _post('/api/dostk/acnt', 'kt00001', {'qry_tp': '3'});
    final cash = _signed(dep.body['ord_alow_amt'], _signed(dep.body['entr']));
    final positions = <Position>[];
    var total = 0.0;
    var cont = 'N', key = '';
    for (var i = 0; i < 10; i++) {
      final r = await _post('/api/dostk/acnt', 'kt00018', {'qry_tp': '1', 'dmst_stex_tp': 'KRX'}, contYn: cont, nextKey: key);
      total = _signed(r.body['tot_evlt_amt'], total);
      for (final row in ((r.body['acnt_evlt_remn_indv_tot'] as List?) ?? []).cast<Map>()) {
        final qty = parseNum(row['rmnd_qty']).toInt();
        if (qty > 0) {
          positions.add(Position('${row['stk_cd']}'.replaceFirst(RegExp('^A'), ''), qty, parseNum(row['pur_pric']),
              name: '${row['stk_nm'] ?? ''}'.trim(), currentPrice: parseNum(row['cur_prc'])));
        }
      }
      cont = r.headers['cont-yn'] ?? 'N';
      key = r.headers['next-key'] ?? '';
      if (cont != 'Y' || key.isEmpty) break;
    }
    return Balance(cash, total, positions);
  }

  @override
  Future<OrderResult> placeOrder(String symbol, Side side, int qty, OrderType type, double price) async {
    if (qty <= 0) return const OrderResult(false, message: '수량이 0입니다');
    final market = type == OrderType.market;
    try {
      final r = await _post('/api/dostk/ordr', side == Side.buy ? 'kt10000' : 'kt10001', {
        'dmst_stex_tp': 'KRX',
        'stk_cd': symbol,
        'ord_qty': '$qty',
        'ord_uv': market ? '' : '${price.round()}',
        'trde_tp': market ? '3' : '0',
        'cond_uv': '',
      });
      return OrderResult(true, orderId: '${r.body['ord_no'] ?? ''}', message: '${r.body['return_msg'] ?? ''}', price: price);
    } on BrokerException catch (e) {
      return OrderResult(false, message: e.message);
    }
  }
}
