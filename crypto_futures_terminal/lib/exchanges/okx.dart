import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../core/models.dart';
import 'exchange.dart';

/// OKX USDT 무기한 스왑 (단방향 net 모드, 격리 마진).
class OkxExchange extends SignedExchange {
  static const _base = 'https://www.okx.com';
  OkxExchange(super.creds);

  @override
  ExchangeId get id => ExchangeId.okx;

  String _inst(String coin) => '$coin-USDT-SWAP';

  Future<dynamic> _req(String method, String path, {Object? body}) async {
    final ts = DateTime.now().toUtc().toIso8601String().replaceFirst(RegExp(r'\d{3}Z$'), 'Z');
    final b = body == null ? '' : jsonEncode(body);
    final sign = base64.encode(
        Hmac(sha256, utf8.encode(creds.apiSecret)).convert(utf8.encode('$ts$method$path$b')).bytes);
    final h = {
      'OK-ACCESS-KEY': creds.apiKey,
      'OK-ACCESS-SIGN': sign,
      'OK-ACCESS-TIMESTAMP': ts,
      'OK-ACCESS-PASSPHRASE': creds.passphrase,
      'Content-Type': 'application/json',
    };
    final uri = Uri.parse('$_base$path');
    final r = method == 'GET'
        ? await client.get(uri, headers: h)
        : await client.post(uri, headers: h, body: b);
    final j = decode(r, 'OKX $path');
    if ('${j['code']}' != '0') {
      final detail = (j['data'] is List && (j['data'] as List).isNotEmpty)
          ? (j['data'] as List).first['sMsg']
          : '';
      throw ExchangeException('OKX $path: ${j['msg']} $detail (${j['code']})');
    }
    return j['data'];
  }

  @override
  Future<ContractSpec> fetchSpec(String coin) async {
    final r = await client.get(
        Uri.parse('$_base/api/v5/public/instruments?instType=SWAP&instId=${_inst(coin)}'));
    final s = (decode(r, 'OKX instruments')['data'] as List).first;
    return ContractSpec(
      contractSize: SignedExchange.d(s['ctVal']),
      qtyStep: SignedExchange.d(s['lotSz']),
      minQty: SignedExchange.d(s['minSz']),
      tickSize: SignedExchange.d(s['tickSz']),
    );
  }

  @override
  Future<double> availableBalance() async {
    final d = await _req('GET', '/api/v5/account/balance?ccy=USDT') as List;
    final details = d.first['details'] as List;
    if (details.isEmpty) return 0;
    final u = details.first;
    return SignedExchange.d(u['availEq'] == '' ? u['availBal'] : u['availEq']);
  }

  @override
  Future<void> prepare(String coin, int leverage) async {
    await _req('POST', '/api/v5/account/set-leverage',
        body: {'instId': _inst(coin), 'lever': '$leverage', 'mgnMode': 'isolated'});
  }

  @override
  Future<Position?> position(String coin, int leverage) async {
    final d = await _req('GET', '/api/v5/account/positions?instId=${_inst(coin)}') as List;
    final s = await spec(coin);
    for (final p in d) {
      final pos = SignedExchange.d(p['pos']);
      if (pos == 0) continue;
      return Position(
        coin: coin,
        side: pos > 0 ? Side.long : Side.short,
        entryPrice: SignedExchange.d(p['avgPx']),
        qty: pos.abs() * s.contractSize,
        leverage: int.tryParse('${p['lever']}') ?? leverage,
      );
    }
    return null;
  }

  @override
  Future<double> marketOrder(String coin, Side side, double qty, {bool reduceOnly = false}) async {
    final units = await toUnits(coin, qty);
    await _req('POST', '/api/v5/trade/order', body: {
      'instId': _inst(coin),
      'tdMode': 'isolated',
      'side': side == Side.long ? 'buy' : 'sell',
      'ordType': 'market',
      'sz': await unitsStr(coin, units),
      if (reduceOnly) 'reduceOnly': true,
    });
    return units * (await spec(coin)).contractSize;
  }

  @override
  Future<void> setProtection(String coin, Position pos, double? stopLoss, double? takeProfit) async {
    await cancelProtection(coin);
    if (stopLoss == null && takeProfit == null) return;
    final units = await toUnits(coin, pos.qty);
    await _req('POST', '/api/v5/trade/order-algo', body: {
      'instId': _inst(coin),
      'tdMode': 'isolated',
      'side': pos.side == Side.long ? 'sell' : 'buy',
      'ordType': (stopLoss != null && takeProfit != null) ? 'oco' : 'conditional',
      'sz': await unitsStr(coin, units),
      'reduceOnly': true,
      if (stopLoss != null) ...{
        'slTriggerPx': await priceStr(coin, stopLoss),
        'slOrdPx': '-1',
        'slTriggerPxType': 'mark',
      },
      if (takeProfit != null) ...{
        'tpTriggerPx': await priceStr(coin, takeProfit),
        'tpOrdPx': '-1',
        'tpTriggerPxType': 'mark',
      },
    });
  }

  @override
  Future<void> cancelProtection(String coin) async {
    final pending = <Map<String, String>>[];
    for (final t in ['oco', 'conditional']) {
      final d = await _req('GET',
          '/api/v5/trade/orders-algo-pending?ordType=$t&instId=${_inst(coin)}') as List;
      pending.addAll(d.map((e) => {'algoId': '${e['algoId']}', 'instId': _inst(coin)}));
    }
    // cancel-algos 는 한 번에 최대 10건
    for (var i = 0; i < pending.length; i += 10) {
      await _req('POST', '/api/v5/trade/cancel-algos',
          body: pending.sublist(i, math.min(i + 10, pending.length)));
    }
  }
}
