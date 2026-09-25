import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kr_stock_app/brokers/broker.dart';
import 'package:kr_stock_app/brokers/db.dart';
import 'package:kr_stock_app/brokers/kis.dart';
import 'package:kr_stock_app/brokers/kiwoom.dart';
import 'package:kr_stock_app/brokers/ls.dart';
import 'package:kr_stock_app/brokers/nh.dart';

/// 경로 끝부분 → 응답 목록. 요청은 calls 에 기록된다.
class Fake {
  final Map<String, List<http.Response>> routes;
  final List<http.Request> calls = [];
  Fake(this.routes);

  MockClient get client => MockClient((req) async {
        calls.add(req);
        for (final e in routes.entries) {
          if (req.url.path.endsWith(e.key)) {
            return e.value.length > 1 ? e.value.removeAt(0) : e.value.first;
          }
        }
        return http.Response('{"error":"unexpected ${req.url}"}', 404);
      });

  Map<String, dynamic> body(int i) => jsonDecode(calls[i].body) as Map<String, dynamic>;
}

http.Response j(Object body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json', ...headers});

void main() {
  test('KIS demo order uses VTTC0012U and body fields', () async {
    final f = Fake({
      '/oauth2/tokenP': [j({'access_token': 'T', 'expires_in': 86400})],
      '/order-cash': [j({'rt_cd': '0', 'msg1': '주문 전송 완료', 'output': {'ODNO': '0000117057'}})],
    });
    final b = KisBroker('k', 's', '12345678-01', client: f.client, rateInterval: Duration.zero);
    final r = await b.placeOrder('005930', Side.buy, 3, OrderType.limit, 70100);
    expect(r.ok, isTrue);
    expect(r.orderId, '0000117057');
    final req = f.calls.last;
    expect(req.url.host, 'openapivts.koreainvestment.com');
    expect(req.headers['tr_id'], 'VTTC0012U');
    expect(req.headers['authorization'], 'Bearer T');
    final body = f.body(f.calls.length - 1);
    expect(body['CANO'], '12345678');
    expect(body['ORD_DVSN'], '00');
    expect(body['ORD_UNPR'], '70100');
  });

  test('KIS real sell market + error message', () async {
    final f = Fake({
      '/oauth2/tokenP': [j({'access_token': 'T'})],
      '/order-cash': [
        j({'rt_cd': '1', 'msg_cd': 'APBK0986', 'msg1': '주문가능금액을 초과 했습니다'}),
        j({'rt_cd': '0', 'output': {'ODNO': '1'}}),
      ],
    });
    final b = KisBroker('k', 's', '1234567801', live: true, client: f.client, rateInterval: Duration.zero);
    final bad = await b.placeOrder('005930', Side.buy, 1000, OrderType.market, 0);
    expect(bad.ok, isFalse);
    expect(bad.message, contains('주문가능금액'));
    await b.placeOrder('005930', Side.sell, 1, OrderType.market, 0);
    expect(f.calls.last.headers['tr_id'], 'TTTC0011U');
    expect(f.body(f.calls.length - 1)['ORD_UNPR'], '0');
  });

  test('KIS balance paging', () async {
    final f = Fake({
      '/oauth2/tokenP': [j({'access_token': 'T'})],
      '/inquire-balance': [
        j({
          'rt_cd': '0',
          'ctx_area_fk100': 'a',
          'ctx_area_nk100': 'b',
          'output1': [{'pdno': '005930', 'prdt_name': '삼성전자', 'hldg_qty': '10', 'pchs_avg_pric': '68000', 'prpr': '70100'}],
          'output2': [{'prvs_rcdl_excc_amt': '900000', 'tot_evlu_amt': '1601000'}],
        }, headers: {'tr_cont': 'M'}),
        j({
          'rt_cd': '0',
          'output1': [{'pdno': '035420', 'hldg_qty': '2', 'pchs_avg_pric': '200000', 'prpr': '210000'}],
          'output2': [{'prvs_rcdl_excc_amt': '900000', 'tot_evlu_amt': '1601000'}],
        }, headers: {'tr_cont': 'D'}),
      ],
    });
    final b = KisBroker('k', 's', '12345678-01', client: f.client, rateInterval: Duration.zero);
    final bal = await b.getBalance();
    expect(bal.cash, 900000);
    expect(bal.positions.map((p) => p.symbol), ['005930', '035420']);
    expect(f.calls.last.headers['tr_cont'], 'N');
  });

  test('Kiwoom market buy body and signed prices', () async {
    final f = Fake({
      '/oauth2/token': [j({'token': 'W', 'expires_dt': '20991231235959', 'return_code': 0})],
      '/api/dostk/ordr': [j({'ord_no': '00024', 'return_code': 0})],
      '/api/dostk/stkinfo': [j({'cur_prc': '-70100', 'return_code': 0})],
      '/api/dostk/mrkcond': [j({'sel_fpr_bid': '+70200', 'buy_fpr_bid': '-70100', 'return_code': 0})],
    });
    final b = KiwoomBroker('k', 's', client: f.client, rateInterval: Duration.zero);
    final r = await b.placeOrder('005930', Side.buy, 2, OrderType.market, 0);
    expect(r.ok, isTrue);
    expect(f.calls.last.headers['api-id'], 'kt10000');
    expect(f.body(f.calls.length - 1)['trde_tp'], '3');
    final q = await b.getQuote('005930');
    expect([q.price, q.bid, q.ask], [70100, 70100, 70200]);
  });

  test('LS form token + CSPAT00601 body + non-zero success code', () async {
    final f = Fake({
      '/oauth2/token': [j({'access_token': 'L', 'expires_in': 86400})],
      '/stock/order': [j({'rsp_cd': '00040', 'rsp_msg': '매수주문 완료', 'CSPAT00601OutBlock2': {'OrdNo': 12345}})],
    });
    final b = LsBroker('k', 's', client: f.client, rateInterval: Duration.zero, chartInterval: Duration.zero);
    final r = await b.placeOrder('005930', Side.buy, 3, OrderType.limit, 70100);
    expect(r.ok, isTrue);
    expect(r.orderId, '12345');
    expect(f.calls.first.bodyFields['appsecretkey'], 's');
    final block = f.body(1)['CSPAT00601InBlock1'] as Map;
    expect(block['IsuNo'], 'A005930');
    expect(block['BnsTpCode'], '2');
    expect(block['OrdprcPtnCode'], '00');
    expect(f.calls.last.headers['tr_cd'], 'CSPAT00601');
  });

  test('DB order body and token retry', () async {
    final f = Fake({
      '/oauth2/token': [j({'access_token': 'D', 'expires_in': 86400})],
      '/inquiry/price': [
        j({'rsp_cd': 'IGW00123', 'rsp_msg': '기간이 만료된 token 입니다.'}),
        j({'rsp_cd': '00000', 'Out': {'Prpr': '70100', 'Bidp1': '70100', 'Askp1': '70200'}}),
      ],
      '/kr-stock/order': [j({'rsp_cd': '00000', 'Out': {'OrdNo': 3021}})],
    });
    final b = DbBroker('k', 's', client: f.client, rateInterval: Duration.zero);
    expect((await b.getQuote('005930')).ask, 70200);
    expect(f.calls.where((c) => c.url.path.endsWith('/oauth2/token')).length, 2);
    final r = await b.placeOrder('005930', Side.sell, 2, OrderType.market, 0);
    expect(r.orderId, '3021');
    final input = f.body(f.calls.length - 1)['In'] as Map;
    expect(input['BnsTpCode'], '1');
    expect(input['OrdprcPtnCode'], '03');
    expect(input['TrchNo'], 1);
  });

  test('NH token from live host, mock account auto-select, order', () async {
    final f = Fake({
      '/oauth2/token': [j({'access_token': 'N', 'expires_in': 86400})],
      '/n2/acctinfo': [
        j({'Output_0': [
          {'acct_no': '20100000001', 'acct_type': '01'},
          {'acct_no': '20100000003', 'acct_type': '03'},
        ]})
      ],
      '/cashBuy': [j({'rsp_cd': '00166', 'rsp_msg': '매수주문이 접수되었습니다', 'Output_0': {'mkt_orr_no': '0000012345'}})],
    });
    final b = NhBroker('k', 's', client: f.client, rateInterval: Duration.zero);
    final r = await b.placeOrder('005930', Side.buy, 2, OrderType.limit, 70100);
    expect(r.ok, isTrue);
    expect(f.calls.first.url.host, 'api.nhplug.com');
    expect(f.calls.first.url.queryParameters['scope'], 'oob');
    expect(f.calls.last.url.host, 'moapi.nhplug.com');
    final input = f.body(f.calls.length - 1)['Input_0'] as Map;
    expect(input['act_no'], '20100000003');
    expect(input['nmn_pr_tp_cd'], '01');
    expect(input['orr_pr'], 70100);
  });

  test('NH failure uses rsp_msg when no order number', () async {
    final f = Fake({
      '/oauth2/token': [j({'access_token': 'N'})],
      '/cashSell': [j({'rsp_cd': '10006', 'rsp_msg': '매도가능수량이 부족합니다'})],
    });
    final b = NhBroker('k', 's', account: '20100000001', live: true, client: f.client, rateInterval: Duration.zero);
    final r = await b.placeOrder('005930', Side.sell, 5, OrderType.market, 0);
    expect(r.ok, isFalse);
    expect(r.message, contains('부족'));
  });

  test('resample minutes', () {
    final c = [
      for (var m = 0; m < 10; m++) Candle(DateTime(2026, 9, 25, 9, m), 100.0 + m, 101.0 + m, 99.0 + m, 100.5 + m, 1)
    ];
    final r = resampleMinutes(c, 5);
    expect(r.length, 2);
    expect(r.first.close, 104.5);
    expect(r.first.volume, 5);
  });
}
