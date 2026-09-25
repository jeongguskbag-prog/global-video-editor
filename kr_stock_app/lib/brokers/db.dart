// DB증권 Open API (국내주식). 실전·모의 같은 주소, 모의투자용 App Key 로 구분.
import 'package:http/http.dart' as http;

import '../core/market.dart';
import 'broker.dart';

const _tokenErrors = {'IGW00121', 'IGW00122', 'IGW00123'};

class DbBroker implements Broker {
  static const baseUrl = 'https://openapi.dbsec.co.kr:8443';
  final String appKey, appSecret;
  @override
  final bool live;
  final http.Client client;
  final TokenCache tokens;
  final RateLimiter limiter;
  String? _token;

  DbBroker(this.appKey, this.appSecret,
      {this.live = false, http.Client? client, KeyValueStore? store, Duration rateInterval = const Duration(milliseconds: 550)})
      : client = client ?? http.Client(),
        tokens = TokenCache(store ?? MemoryStore()),
        limiter = RateLimiter(rateInterval) {
    if (appKey.isEmpty || appSecret.isEmpty) throw BrokerException('DB App Key / Secret 을 입력하세요 (모의투자는 모의투자용 키)');
  }

  @override
  String get name => 'db';
  String get _tokenKey => 'db_${live}_${appKey.hashCode}';

  Future<String> _accessToken() async {
    if (_token != null) return _token!;
    final cached = await tokens.load(_tokenKey);
    if (cached != null) return _token = cached;
    final r = await sendJson(client, 'POST', Uri.parse('$baseUrl/oauth2/token'),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        form: {'grant_type': 'client_credentials', 'appkey': appKey, 'appsecretkey': appSecret, 'scope': 'oob'});
    final token = r.body['access_token'] as String?;
    if (token == null) throw BrokerException('DB 토큰 발급 실패: ${r.body['rsp_msg'] ?? r.body}');
    final exp = (r.body['expires_in'] as num?)?.toInt() ?? 0;
    await tokens.save(_tokenKey, token, exp > 0 ? exp : 86400);
    return _token = token;
  }

  Future<JsonResponse> _call(String path, Map<String, dynamic> input,
      {String contYn = 'N', String contKey = '', bool retried = false}) async {
    await limiter.wait();
    final r = await sendJson(client, 'POST', Uri.parse('$baseUrl$path'), headers: {
      'content-type': 'application/json; charset=utf-8',
      'authorization': 'Bearer ${await _accessToken()}',
      'cont_yn': contYn,
      'cont_key': contKey,
    }, body: {'In': input});
    final code = '${r.body['rsp_cd'] ?? ''}'.trim();
    if (_tokenErrors.contains(code) && !retried) {
      _token = null;
      await tokens.clear(_tokenKey);
      return _call(path, input, contYn: contYn, contKey: contKey, retried: true);
    }
    final n = int.tryParse(code);
    if (code.isNotEmpty && !(n != null && code.startsWith('0') && n < 1000)) {
      throw BrokerException('DB ${path.split('/').last} 실패 [$code] ${'${r.body['rsp_msg'] ?? ''}'.trim()}');
    }
    return r;
  }

  @override
  Future<Quote> getQuote(String symbol) async {
    final r = await _call('/api/v1/quote/kr-stock/inquiry/price', {'InputIscd1': symbol, 'InputCondMrktDivCode': 'J'});
    final o = (r.body['Out'] as Map?) ?? {};
    final bid = parseNum(o['Bidp1']), ask = parseNum(o['Askp1']);
    return Quote(symbol, parseNum(o['Prpr']), bid: bid == 0 ? null : bid, ask: ask == 0 ? null : ask);
  }

  @override
  Future<List<Candle>> getCandles(String symbol, String interval, int count) async {
    final minutes = minutesOf(interval);
    final today = nowKst();
    final JsonResponse r;
    if (minutes == null) {
      r = await _call('/api/v1/quote/kr-chart/day', {
        'InputOrgAdjPrc': '1',
        'InputCondMrktDivCode': 'J',
        'InputIscd1': symbol,
        'InputDate1': ymd(today.subtract(Duration(days: (count * 1.6).round() + 10))),
        'InputDate2': ymd(today),
      });
    } else {
      r = await _call('/api/v1/quote/kr-chart/min', {
        'dataCnt': '${count.clamp(1, 2000)}',
        'InputCondMrktDivCode': 'J',
        'InputIscd1': symbol,
        'InputDate1': ymd(today),
        'InputDivXtick': '${60 * minutes}',
        'InputOrgAdjPrc': '1',
      });
    }
    final m = <DateTime, Candle>{};
    for (final row in ((r.body['Out'] as List?) ?? []).cast<Map>()) {
      final date = '${row['Date'] ?? ''}'.trim();
      if (date.length < 8) continue;
      final t = minutes == null ? parseYmd(date) : parseYmdHms(date, '${row['Hour'] ?? ''}'.trim().padRight(6, '0').substring(0, 6));
      m[t] = Candle(t, parseNum(row['Oprc']), parseNum(row['Hprc']), parseNum(row['Lprc']), parseNum(row['Prpr']),
          parseNum(row['CntgVol']));
    }
    return sortedTail(m, count);
  }

  @override
  Future<Balance> getBalance() async {
    final dep = await _call('/api/v1/trading/kr-stock/inquiry/acnt-deposit', {});
    final d = (dep.body['Out1'] as Map?) ?? {};
    final cash = parseNum(d['PrsmptDpsD2'], parseNum(d['DpsBalAmt']));
    final positions = <Position>[];
    var total = 0.0, cont = 'N', key = '';
    for (var i = 0; i < 10; i++) {
      final r = await _call('/api/v1/trading/kr-stock/inquiry/balance', {'QryTpCode0': '0'}, contYn: cont, contKey: key);
      total = parseNum((r.body['Out'] as Map?)?['DpsastAmt'], total);
      for (final row in ((r.body['Out1'] as List?) ?? []).cast<Map>()) {
        final qty = parseNum(row['BalQty0'], parseNum(row['BalQty'])).toInt();
        if (qty > 0) {
          final avg = parseNum(row['ExecPrc']) > 0 ? parseNum(row['ExecPrc']) : parseNum(row['PchsAmt']) / qty;
          positions.add(Position('${row['IsuNo']}'.trim().replaceFirst(RegExp('^A'), ''), qty, avg,
              name: '${row['IsuNm'] ?? ''}'.trim(), currentPrice: parseNum(row['NowPrc'])));
        }
      }
      cont = r.headers['cont_yn'] ?? 'N';
      key = r.headers['cont_key'] ?? '';
      if (cont != 'Y' || key.isEmpty) break;
    }
    return Balance(cash, total, positions);
  }

  @override
  Future<OrderResult> placeOrder(String symbol, Side side, int qty, OrderType type, double price) async {
    if (qty <= 0) return const OrderResult(false, message: '수량이 0입니다');
    final market = type == OrderType.market;
    try {
      final r = await _call('/api/v1/trading/kr-stock/order', {
        'IsuNo': 'A$symbol',
        'OrdQty': qty,
        'OrdPrc': market ? 0 : price.round(),
        'BnsTpCode': side == Side.buy ? '2' : '1',
        'OrdprcPtnCode': market ? '03' : '00',
        'MgntrnCode': '000',
        'LoanDt': '00000000',
        'OrdCndiTpCode': '0',
        'TrchNo': 1,
      });
      final no = '${(r.body['Out'] as Map?)?['OrdNo'] ?? ''}'.trim();
      if (no.isEmpty || no == '0') return OrderResult(false, message: '${r.body['rsp_msg'] ?? '주문번호 없음'}'.trim());
      return OrderResult(true, orderId: no, message: '${r.body['rsp_msg'] ?? ''}'.trim(), price: price);
    } on BrokerException catch (e) {
      return OrderResult(false, message: e.message);
    }
  }
}
