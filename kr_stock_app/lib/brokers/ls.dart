// LS증권 Open API (국내주식). 실전·모의 같은 주소, 모의투자용 App Key 로 구분.
import 'package:http/http.dart' as http;

import '../core/market.dart';
import 'broker.dart';

bool _okCode(Object? code) {
  final c = '${code ?? ''}'.trim();
  final n = int.tryParse(c);
  return c.isEmpty || (n != null && c.startsWith('0') && n < 1000);
}

class LsBroker implements Broker {
  static const baseUrl = 'https://openapi.ls-sec.co.kr:8080';
  final String appKey, appSecret;
  @override
  final bool live;
  final http.Client client;
  final TokenCache tokens;
  final RateLimiter limiter, chartLimiter;
  String? _token;

  LsBroker(this.appKey, this.appSecret,
      {this.live = false, http.Client? client, KeyValueStore? store, Duration? rateInterval, Duration? chartInterval})
      : client = client ?? http.Client(),
        tokens = TokenCache(store ?? MemoryStore()),
        limiter = RateLimiter(rateInterval ?? const Duration(milliseconds: 350)),
        chartLimiter = RateLimiter(chartInterval ?? const Duration(milliseconds: 1050)) {
    if (appKey.isEmpty || appSecret.isEmpty) throw BrokerException('LS App Key / Secret 을 입력하세요 (모의투자는 모의투자용 키)');
  }

  @override
  String get name => 'ls';
  String get _tokenKey => 'ls_${live}_${appKey.hashCode}';

  Future<String> _accessToken() async {
    if (_token != null) return _token!;
    final cached = await tokens.load(_tokenKey);
    if (cached != null) return _token = cached;
    final r = await sendJson(client, 'POST', Uri.parse('$baseUrl/oauth2/token'),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        form: {'grant_type': 'client_credentials', 'appkey': appKey, 'appsecretkey': appSecret, 'scope': 'oob'});
    final token = r.body['access_token'] as String?;
    if (token == null) throw BrokerException('LS 토큰 발급 실패: ${r.body['error_description'] ?? r.body['rsp_msg'] ?? r.body}');
    await tokens.save(_tokenKey, token, (r.body['expires_in'] as num?)?.toInt() ?? 86400);
    return _token = token;
  }

  Future<JsonResponse> _call(String path, String tr, Map<String, dynamic> inBlock,
      {String? blockName, String trCont = 'N', String trContKey = '', bool retried = false}) async {
    await (tr == 't8410' || tr == 't8412' ? chartLimiter : limiter).wait();
    final r = await sendJson(client, 'POST', Uri.parse('$baseUrl$path'), headers: {
      'content-type': 'application/json; charset=utf-8',
      'authorization': 'Bearer ${await _accessToken()}',
      'tr_cd': tr,
      'tr_cont': trCont,
      'tr_cont_key': trContKey,
    }, body: {blockName ?? '${tr}InBlock': inBlock});
    final code = '${r.body['rsp_cd'] ?? ''}'.trim();
    if (!_okCode(code)) {
      if (code.startsWith('IGW') && '${r.body['rsp_msg']}'.toLowerCase().contains('token') && !retried) {
        _token = null;
        await tokens.clear(_tokenKey);
        return _call(path, tr, inBlock, blockName: blockName, trCont: trCont, trContKey: trContKey, retried: true);
      }
      throw BrokerException('LS $tr 실패 [$code] ${'${r.body['rsp_msg'] ?? ''}'.trim()}');
    }
    return r;
  }

  @override
  Future<Quote> getQuote(String symbol) async {
    final r = await _call('/stock/market-data', 't1101', {'shcode': symbol});
    final o = (r.body['t1101OutBlock'] as Map?) ?? {};
    final bid = parseNum(o['bidho1']), ask = parseNum(o['offerho1']);
    return Quote(symbol, parseNum(o['price']), bid: bid == 0 ? null : bid, ask: ask == 0 ? null : ask);
  }

  @override
  Future<List<Candle>> getCandles(String symbol, String interval, int count) async {
    final minutes = minutesOf(interval);
    final tr = minutes == null ? 't8410' : 't8412';
    final block = <String, dynamic>{
      'shcode': symbol,
      'sdate': '',
      'edate': '99999999',
      'cts_date': '',
      'comp_yn': 'N',
      if (minutes == null) ...{'gubun': '2', 'sujung': 'Y'} else ...{
        'ncnt': minutes,
        'nday': '0',
        'stime': '',
        'etime': '',
        'cts_time': '',
      },
    };
    final m = <DateTime, Candle>{};
    var cont = 'N', key = '';
    for (var i = 0; i < 10; i++) {
      block['qrycnt'] = (count - m.length).clamp(1, 500);
      final r = await _call('/stock/chart', tr, block, trCont: cont, trContKey: key);
      for (final row in ((r.body['${tr}OutBlock1'] as List?) ?? []).cast<Map>()) {
        final date = '${row['date'] ?? ''}';
        if (date.length < 8) continue;
        final t = minutes == null ? parseYmd(date) : parseYmdHms(date, '${row['time'] ?? ''}'.padRight(6, '0').substring(0, 6));
        m[t] = Candle(t, parseNum(row['open']), parseNum(row['high']), parseNum(row['low']), parseNum(row['close']),
            parseNum(row['jdiff_vol']));
      }
      final head = (r.body['${tr}OutBlock'] as Map?) ?? {};
      cont = r.headers['tr_cont'] ?? 'N';
      key = r.headers['tr_cont_key'] ?? '';
      if (m.length >= count || cont != 'Y' || '${head['cts_date'] ?? ''}'.isEmpty) break;
      block['cts_date'] = '${head['cts_date']}';
      if (minutes != null) block['cts_time'] = '${head['cts_time'] ?? ''}';
    }
    return sortedTail(m, count);
  }

  @override
  Future<Balance> getBalance() async {
    final c = await _call('/stock/accno', 'CSPAQ12200', {'BalCreTp': '0'}, blockName: 'CSPAQ12200InBlock1');
    final o2 = (c.body['CSPAQ12200OutBlock2'] as Map?) ?? {};
    final cash = parseNum(o2['MnyOrdAbleAmt'], parseNum(o2['D2Dps']));
    final positions = <Position>[];
    var total = 0.0, cursor = '', cont = 'N', key = '';
    for (var i = 0; i < 10; i++) {
      final r = await _call('/stock/accno', 't0424',
          {'prcgb': '1', 'chegb': '2', 'dangb': '0', 'charge': '1', 'cts_expcode': cursor},
          trCont: cont, trContKey: key);
      final head = (r.body['t0424OutBlock'] as Map?) ?? {};
      total = parseNum(head['sunamt'], total);
      for (final row in ((r.body['t0424OutBlock1'] as List?) ?? []).cast<Map>()) {
        final qty = parseNum(row['janqty']).toInt();
        if (qty > 0) {
          positions.add(Position('${row['expcode']}'.replaceFirst(RegExp('^A'), ''), qty, parseNum(row['pamt']),
              name: '${row['hname'] ?? ''}'.trim(), currentPrice: parseNum(row['price'])));
        }
      }
      cursor = '${head['cts_expcode'] ?? ''}'.trim();
      cont = r.headers['tr_cont'] ?? 'N';
      key = r.headers['tr_cont_key'] ?? '';
      if (cont != 'Y' || cursor.isEmpty) break;
    }
    return Balance(cash, total, positions);
  }

  @override
  Future<OrderResult> placeOrder(String symbol, Side side, int qty, OrderType type, double price) async {
    if (qty <= 0) return const OrderResult(false, message: '수량이 0입니다');
    final market = type == OrderType.market;
    try {
      final r = await _call('/stock/order', 'CSPAT00601', {
        'IsuNo': 'A$symbol',
        'OrdQty': qty,
        'OrdPrc': market ? 0 : price.roundToDouble(),
        'BnsTpCode': side == Side.buy ? '2' : '1',
        'OrdprcPtnCode': market ? '03' : '00',
        'MgntrnCode': '000',
        'LoanDt': '',
        'OrdCndiTpCode': '0',
      }, blockName: 'CSPAT00601InBlock1');
      final no = '${(r.body['CSPAT00601OutBlock2'] as Map?)?['OrdNo'] ?? ''}'.trim();
      if (no.isEmpty || no == '0') return OrderResult(false, message: '${r.body['rsp_msg'] ?? '주문번호 없음'}'.trim());
      return OrderResult(true, orderId: no, message: '${r.body['rsp_msg'] ?? ''}'.trim(), price: price);
    } on BrokerException catch (e) {
      return OrderResult(false, message: e.message);
    }
  }
}
