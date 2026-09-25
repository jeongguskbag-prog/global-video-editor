// 한국투자증권 KIS Developers Open API (국내주식).
import 'package:http/http.dart' as http;

import '../core/market.dart';
import 'broker.dart';

class KisBroker implements Broker {
  static const baseUrls = {true: 'https://openapi.koreainvestment.com:9443', false: 'https://openapivts.koreainvestment.com:29443'};
  final String appKey, appSecret, cano, prdt;
  @override
  final bool live;
  final http.Client client;
  final TokenCache tokens;
  final RateLimiter limiter;
  String? _token;
  final Map<String, (String, Map<DateTime, Candle>)> _minuteCache = {};

  KisBroker._(this.appKey, this.appSecret, this.cano, this.prdt, this.live, this.client, this.tokens, this.limiter);

  factory KisBroker(String appKey, String appSecret, String account,
      {bool live = false, http.Client? client, KeyValueStore? store, Duration? rateInterval}) {
    if (appKey.isEmpty || appSecret.isEmpty) throw BrokerException('한국투자증권 App Key / App Secret 을 입력하세요');
    var digits = account.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length != 10) throw BrokerException('계좌번호는 12345678-01 형식(10자리)이어야 합니다');
    return KisBroker._(appKey, appSecret, digits.substring(0, 8), digits.substring(8), live, client ?? http.Client(),
        TokenCache(store ?? MemoryStore()), RateLimiter(rateInterval ?? Duration(milliseconds: live ? 60 : 550)));
  }

  @override
  String get name => 'kis';
  String get baseUrl => baseUrls[live]!;
  String get _tokenKey => 'kis_${live}_${appKey.hashCode}';

  Future<String> _accessToken() async {
    if (_token != null) return _token!;
    final cached = await tokens.load(_tokenKey);
    if (cached != null) return _token = cached;
    final r = await sendJson(client, 'POST', Uri.parse('$baseUrl/oauth2/tokenP'),
        headers: {'content-type': 'application/json'},
        body: {'grant_type': 'client_credentials', 'appkey': appKey, 'appsecret': appSecret});
    final token = r.body['access_token'] as String?;
    if (token == null) throw BrokerException('KIS 토큰 발급 실패: ${r.body['error_description'] ?? r.body}');
    await tokens.save(_tokenKey, token, (r.body['expires_in'] as num?)?.toInt() ?? 86400);
    return _token = token;
  }

  Future<JsonResponse> _request(String method, String path, String trId,
      {Map<String, String>? params, Map<String, dynamic>? body, String trCont = '', bool retried = false}) async {
    await limiter.wait();
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: params);
    final r = await sendJson(client, method, uri, headers: {
      'content-type': 'application/json; charset=utf-8',
      'authorization': 'Bearer ${await _accessToken()}',
      'appkey': appKey,
      'appsecret': appSecret,
      'tr_id': trId,
      'tr_cont': trCont,
      'custtype': 'P',
    }, body: body);
    if ('${r.body['rt_cd']}' != '0') {
      if (r.body['msg_cd'] == 'EGW00123' && !retried) {
        _token = null;
        await tokens.clear(_tokenKey);
        return _request(method, path, trId, params: params, body: body, trCont: trCont, retried: true);
      }
      throw BrokerException('KIS $trId 실패 [${r.body['msg_cd']}] ${(r.body['msg1'] ?? '').toString().trim()}');
    }
    return r;
  }

  @override
  Future<Quote> getQuote(String symbol) async {
    final p = {'FID_COND_MRKT_DIV_CODE': 'J', 'FID_INPUT_ISCD': symbol};
    final r = await _request('GET', '/uapi/domestic-stock/v1/quotations/inquire-price', 'FHKST01010100', params: p);
    final price = parseNum((r.body['output'] as Map?)?['stck_prpr']);
    double? bid, ask;
    try {
      final b = await _request('GET', '/uapi/domestic-stock/v1/quotations/inquire-asking-price-exp-ccn', 'FHKST01010200',
          params: p);
      final o = (b.body['output1'] as Map?) ?? {};
      bid = parseNum(o['bidp1']);
      ask = parseNum(o['askp1']);
    } on BrokerException {
      // 호가 실패 시 스프레드 필터만 생략
    }
    return Quote(symbol, price, bid: bid == 0 ? null : bid, ask: ask == 0 ? null : ask);
  }

  @override
  Future<List<Candle>> getCandles(String symbol, String interval, int count) async {
    final minutes = minutesOf(interval);
    if (minutes == null) return _daily(symbol, count);
    final ones = await _minutes(symbol, count * minutes);
    final res = resampleMinutes(ones, minutes);
    return res.length > count ? res.sublist(res.length - count) : res;
  }

  Future<List<Candle>> _daily(String symbol, int count) async {
    final m = <DateTime, Candle>{};
    var end = nowKst();
    for (var i = 0; i < 20 && m.length < count; i++) {
      final start = end.subtract(const Duration(days: 150));
      final r = await _request('GET', '/uapi/domestic-stock/v1/quotations/inquire-daily-itemchartprice', 'FHKST03010100',
          params: {
            'FID_COND_MRKT_DIV_CODE': 'J',
            'FID_INPUT_ISCD': symbol,
            'FID_INPUT_DATE_1': ymd(start),
            'FID_INPUT_DATE_2': ymd(end),
            'FID_PERIOD_DIV_CODE': 'D',
            'FID_ORG_ADJ_PRC': '0',
          });
      final rows = ((r.body['output2'] as List?) ?? []).cast<Map>().where((e) => '${e['stck_bsop_date'] ?? ''}'.isNotEmpty).toList();
      if (rows.isEmpty) break;
      DateTime? oldest;
      for (final row in rows) {
        final t = parseYmd('${row['stck_bsop_date']}');
        m[t] = Candle(t, parseNum(row['stck_oprc']), parseNum(row['stck_hgpr']), parseNum(row['stck_lwpr']),
            parseNum(row['stck_clpr']), parseNum(row['acml_vol']));
        if (oldest == null || t.isBefore(oldest)) oldest = t;
      }
      end = oldest!.subtract(const Duration(days: 1));
    }
    return sortedTail(m, count);
  }

  Future<Map<DateTime, Candle>> _minutePage(String symbol, DateTime cursor) async {
    final r = await _request('GET', '/uapi/domestic-stock/v1/quotations/inquire-time-itemchartprice', 'FHKST03010200',
        params: {
          'FID_ETC_CLS_CODE': '',
          'FID_COND_MRKT_DIV_CODE': 'J',
          'FID_INPUT_ISCD': symbol,
          'FID_INPUT_HOUR_1': '${cursor.hour.toString().padLeft(2, '0')}${cursor.minute.toString().padLeft(2, '0')}00',
          'FID_PW_DATA_INCU_YN': 'N',
        });
    final page = <DateTime, Candle>{};
    for (final row in ((r.body['output2'] as List?) ?? []).cast<Map>()) {
      final hour = '${row['stck_cntg_hour'] ?? ''}';
      if (hour.isEmpty) continue;
      final t = parseYmdHms('${row['stck_bsop_date']}', hour);
      page[t] = Candle(t, parseNum(row['stck_oprc']), parseNum(row['stck_hgpr']), parseNum(row['stck_lwpr']),
          parseNum(row['stck_prpr']), parseNum(row['cntg_vol']));
    }
    return page;
  }

  /// 당일 1분봉: 처음엔 30개씩 과거로, 이후엔 최신 페이지만 받아 캐시에 합친다.
  Future<List<Candle>> _minutes(String symbol, int count) async {
    final now = nowKst();
    final close = DateTime(now.year, now.month, now.day, 15, 30);
    final open = DateTime(now.year, now.month, now.day, 9);
    var cursor = now.isAfter(close) ? close : now;
    final cached = _minuteCache[symbol];
    var candles = (cached != null && cached.$1 == ymd(now)) ? cached.$2 : <DateTime, Candle>{};
    final latest = await _minutePage(symbol, cursor);
    final keys = candles.keys.toList()..sort();
    final latestKeys = latest.keys.toList()..sort();
    if (candles.isNotEmpty && latest.isNotEmpty && !latestKeys.first.isAfter(keys.last.add(const Duration(minutes: 1)))) {
      candles.addAll(latest);
    } else {
      candles = Map.of(latest);
      for (var i = 0; i < 14 && candles.isNotEmpty && candles.length < count; i++) {
        final first = (candles.keys.toList()..sort()).first;
        cursor = first.subtract(const Duration(minutes: 1));
        if (cursor.isBefore(open)) break;
        final page = await _minutePage(symbol, cursor);
        if (page.isEmpty) break;
        candles.addAll(page);
      }
    }
    _minuteCache[symbol] = (ymd(now), candles);
    return sortedTail(candles, count);
  }

  @override
  Future<Balance> getBalance() async {
    final positions = <Position>[];
    Map summary = {};
    var fk = '', nk = '', trCont = '';
    for (var i = 0; i < 10; i++) {
      final r = await _request('GET', '/uapi/domestic-stock/v1/trading/inquire-balance', live ? 'TTTC8434R' : 'VTTC8434R',
          trCont: trCont,
          params: {
            'CANO': cano,
            'ACNT_PRDT_CD': prdt,
            'AFHR_FLPR_YN': 'N',
            'OFL_YN': '',
            'INQR_DVSN': '02',
            'UNPR_DVSN': '01',
            'FUND_STTL_ICLD_YN': 'N',
            'FNCG_AMT_AUTO_RDPT_YN': 'N',
            'PRCS_DVSN': '00',
            'CTX_AREA_FK100': fk,
            'CTX_AREA_NK100': nk,
          });
      for (final row in ((r.body['output1'] as List?) ?? []).cast<Map>()) {
        final qty = parseNum(row['hldg_qty']).toInt();
        if (qty > 0) {
          positions.add(Position('${row['pdno']}', qty, parseNum(row['pchs_avg_pric']),
              name: '${row['prdt_name'] ?? ''}', currentPrice: parseNum(row['prpr'])));
        }
      }
      final o2 = r.body['output2'];
      if (o2 is List && o2.isNotEmpty) summary = o2.first as Map;
      if (o2 is Map) summary = o2;
      final next = r.headers['tr_cont'] ?? '';
      if (next != 'F' && next != 'M') break;
      fk = '${r.body['ctx_area_fk100'] ?? ''}';
      nk = '${r.body['ctx_area_nk100'] ?? ''}';
      trCont = 'N';
    }
    final cash = parseNum(summary['prvs_rcdl_excc_amt'], parseNum(summary['dnca_tot_amt']));
    return Balance(cash, parseNum(summary['tot_evlu_amt']), positions);
  }

  @override
  Future<OrderResult> placeOrder(String symbol, Side side, int qty, OrderType type, double price) async {
    if (qty <= 0) return const OrderResult(false, message: '수량이 0입니다');
    final market = type == OrderType.market;
    final trId = '${live ? 'T' : 'V'}TTC001${side == Side.buy ? '2' : '1'}U';
    try {
      final r = await _request('POST', '/uapi/domestic-stock/v1/trading/order-cash', trId, body: {
        'CANO': cano,
        'ACNT_PRDT_CD': prdt,
        'PDNO': symbol,
        'ORD_DVSN': market ? '01' : '00',
        'ORD_QTY': '$qty',
        'ORD_UNPR': market ? '0' : '${price.round()}',
        'EXCG_ID_DVSN_CD': 'KRX',
        'SLL_TYPE': side == Side.sell ? '01' : '',
        'CNDT_PRIC': '',
      });
      return OrderResult(true,
          orderId: '${(r.body['output'] as Map?)?['ODNO'] ?? ''}', message: '${r.body['msg1'] ?? ''}'.trim(), price: price);
    } on BrokerException catch (e) {
      return OrderResult(false, message: e.message);
    }
  }
}
