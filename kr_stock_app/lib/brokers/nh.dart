// NH투자증권 NHPLUG Open API (나무·QV 공용 REST).
// NH 규약상 rsp_cd 로 성공을 판정하지 않고, 기대한 출력 블록이 왔는지로 판단한다.
import 'package:http/http.dart' as http;

import '../core/market.dart';
import 'broker.dart';

class NhBroker implements Broker {
  static const liveUrl = 'https://api.nhplug.com:8443';
  static const mockUrl = 'https://moapi.nhplug.com:8443';
  final String appKey, appSecret;
  @override
  final bool live;
  final http.Client client;
  final TokenCache tokens;
  final RateLimiter limiter;
  String _account;
  String? _token;

  NhBroker(this.appKey, this.appSecret,
      {String account = '', this.live = false, http.Client? client, KeyValueStore? store,
      Duration rateInterval = const Duration(milliseconds: 220)})
      : _account = account.replaceAll('-', '').trim(),
        client = client ?? http.Client(),
        tokens = TokenCache(store ?? MemoryStore()),
        limiter = RateLimiter(rateInterval) {
    if (appKey.isEmpty || appSecret.isEmpty) throw BrokerException('NH App Key / Secret 을 입력하세요 (NHPLUG 포털)');
  }

  @override
  String get name => 'nh';
  String get baseUrl => live ? liveUrl : mockUrl;
  String get _tokenKey => 'nh_${appKey.hashCode}'; // 토큰은 운영에서만 발급 → 환경 공용

  Future<String> _accessToken({bool force = false}) async {
    if (_token != null && !force) return _token!;
    final cached = force ? null : await tokens.load(_tokenKey);
    if (cached != null) return _token = cached;
    final uri = Uri.parse('$liveUrl/oauth2/token').replace(queryParameters: {
      'appkey': appKey,
      'appsecretkey': appSecret,
      'grant_type': 'client_credentials',
      'scope': 'oob',
    });
    final r = await sendJson(client, 'POST', uri, headers: {'content-type': 'application/x-www-form-urlencoded'});
    final token = r.body['access_token'] as String?;
    if (token == null) throw BrokerException('NH 토큰 발급 실패: ${r.body['rsp_msg'] ?? r.body}');
    await tokens.save(_tokenKey, token, (r.body['expires_in'] as num?)?.toInt() ?? 86400);
    return _token = token;
  }

  Future<JsonResponse> _call(String path, Map<String, dynamic> input, {String? cts, String? ctsFlag}) async {
    late JsonResponse r;
    for (var attempt = 0; attempt < 2; attempt++) {
      await limiter.wait();
      r = await sendJson(client, 'POST', Uri.parse('$baseUrl$path'), headers: {
        'authorization': 'Bearer ${await _accessToken(force: attempt == 1)}',
        'x-client-id': appKey,
        'x-client-secret': appSecret,
        'content-type': 'application/json; charset=UTF-8',
        'cts': ?cts,
        'cts_flag': ?ctsFlag,
      }, body: {'Input_0': input});
      if (r.status != 401) break;
    }
    if (r.status == 429) throw BrokerException('NH 호출 한도 초과(초당 약 5회): ${r.body['rsp_msg'] ?? ''}');
    if (r.status != 200) throw BrokerException('NH $path HTTP ${r.status} [${r.body['rsp_cd']}] ${r.body['rsp_msg'] ?? ''}');
    return r;
  }

  Future<String> _accountNo() async {
    if (_account.isNotEmpty) return _account;
    final r = await _call('/n2/acctinfo', {});
    final wanted = live ? {'01', '02'} : {'03'};
    final rows = ((r.body['Output_0'] as List?) ?? []).cast<Map>().where((a) => wanted.contains('${a['acct_type']}'.trim()));
    if (rows.isEmpty) {
      throw BrokerException('NH ${live ? '실전' : '모의투자'} 계좌를 찾지 못했습니다 (계좌구분 ${wanted.join(', ')}). 설정에서 계좌번호를 직접 넣을 수 있습니다');
    }
    return _account = '${rows.first['acct_no']}'.trim();
  }

  @override
  Future<Quote> getQuote(String symbol) async {
    final r = await _call('/krstock/quote/v1/currentPrice', {'iem_cd': symbol, 'market_cd': 'KRX'});
    final o = r.body['Output_0'] as Map?;
    if (o == null || o.isEmpty) throw BrokerException('NH 현재가 결과 없음: ${'${r.body['rsp_msg'] ?? ''}'.trim()}');
    final ask = parseNum(o['askp1']) > 0 ? parseNum(o['askp1']) : parseNum(o['askp']);
    final bid = parseNum(o['bidp1']) > 0 ? parseNum(o['bidp1']) : parseNum(o['bidp']);
    return Quote(symbol, parseNum(o['stck_prpr']), bid: bid == 0 ? null : bid, ask: ask == 0 ? null : ask);
  }

  @override
  Future<List<Candle>> getCandles(String symbol, String interval, int count) async {
    final minutes = minutesOf(interval);
    final r = await _call('/krstock/quote/v1/period', {
      'market_cd': 'KRX',
      'iem_cd': symbol,
      'view_main_yn': 'Y',
      'edate': ymd(nowKst()),
      'array_cnt': '${count.clamp(1, 9999)}',
      'gubun': minutes == null ? '1' : '5',
      'today_cls_code': '0',
      'fake_tick': '1',
      if (minutes != null) 'xtick': '$minutes',
    });
    final m = <DateTime, Candle>{};
    for (final row in ((r.body['Output_1'] as List?) ?? []).cast<Map>()) {
      final date = '${row['bsop_date'] ?? ''}'.trim();
      if (date.length < 8) continue;
      final t = minutes == null ? parseYmd(date) : parseYmdHms(date, '${row['bsop_time'] ?? ''}'.trim().padLeft(6, '0').substring(0, 6));
      m[t] = Candle(t, parseNum(row['stck_oprc']), parseNum(row['stck_hgpr']), parseNum(row['stck_lwpr']),
          parseNum(row['stck_prpr']), parseNum(row['vol']));
    }
    if (m.isEmpty && r.body['Output_0'] == null) {
      throw BrokerException('NH 차트 결과 없음: ${'${r.body['rsp_msg'] ?? ''}'.trim()}');
    }
    return sortedTail(m, count);
  }

  @override
  Future<Balance> getBalance() async {
    final input = {
      'act_no': await _accountNo(),
      'bnc_bse_cd': '5',
      'ltg_aot_dit_cd': '9',
      'aet_bse': '2',
      'qut_dit_cd': 'KRX',
      'aly_qut_cd': '1',
    };
    final positions = <Position>[];
    Map summary = {};
    String? cts, flag;
    JsonResponse? last;
    for (var i = 0; i < 20; i++) {
      final r = last = await _call('/krstock/inquiry/v1/balance', input, cts: cts, ctsFlag: flag);
      if (r.body['Output_0'] is Map) summary = r.body['Output_0'] as Map;
      for (final row in ((r.body['Output_1'] as List?) ?? []).cast<Map>()) {
        final qty = parseNum(row['itg_bnc_qty']).toInt();
        if (qty > 0) {
          positions.add(Position('${row['iem_cd']}'.trim().replaceFirst(RegExp('^A'), ''), qty, parseNum(row['phs_pr']),
              name: '${row['iem_nm'] ?? ''}'.trim(), currentPrice: parseNum(row['now_pr'])));
        }
      }
      final next = (r.headers['cts'] ?? '').trim();
      flag = (r.headers['cts_flag'] ?? '').trim().toUpperCase();
      if (flag.isEmpty) flag = null;
      if (next.isEmpty || next == cts || flag == 'N') break;
      cts = next;
    }
    if (summary.isEmpty) throw BrokerException('NH 잔고 결과 없음: ${'${last?.body['rsp_msg'] ?? ''}'.trim()}');
    final cash = parseNum(summary['orr_pbl_amt4'], parseNum(summary['orr_pbl_amt']));
    return Balance(cash, parseNum(summary['tot_aet_amt']), positions);
  }

  @override
  Future<OrderResult> placeOrder(String symbol, Side side, int qty, OrderType type, double price) async {
    if (qty <= 0) return const OrderResult(false, message: '수량이 0입니다');
    final market = type == OrderType.market;
    try {
      final r = await _call(side == Side.buy ? '/krstock/order/v1/cashBuy' : '/krstock/order/v1/cashSell', {
        'act_no': await _accountNo(),
        'iem_cd': symbol,
        'orr_qty': qty,
        'nmn_pr_tp_cd': market ? '05' : '01',
        'orr_cnd_dit_cd': '00',
        'ssl_nmn_pr_dit_cd': '00',
        'rmt_mkt_cd': 'KRX',
        'sor_mkt_sli_yn': 'N',
        if (!market) 'orr_pr': price.round(),
      });
      final no = '${(r.body['Output_0'] as Map?)?['mkt_orr_no'] ?? ''}'.trim();
      final msg = '${r.body['rsp_msg'] ?? ''}'.trim();
      if (no.replaceAll('0', '').isEmpty) return OrderResult(false, message: msg.isEmpty ? '주문번호가 오지 않았습니다' : msg);
      return OrderResult(true, orderId: no, message: msg, price: price);
    } on BrokerException catch (e) {
      return OrderResult(false, message: e.message);
    }
  }
}
