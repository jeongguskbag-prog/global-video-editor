import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/models.dart';
import 'exchange.dart';

/// Gate.io USDT 무기한 선물 (단일 포지션 모드, 격리 마진).
class GateExchange extends SignedExchange {
  static const _host = 'https://api.gateio.ws';
  static const _prefix = '/api/v4';
  GateExchange(super.creds);

  @override
  ExchangeId get id => ExchangeId.gate;

  String _c(String coin) => '${coin}_USDT';

  Future<dynamic> _req(String method, String path,
      {Map<String, String> query = const {}, Object? body}) async {
    final ts = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final q = Uri(queryParameters: query.isEmpty ? null : query).query;
    final b = body == null ? '' : jsonEncode(body);
    final bodyHash = sha512.convert(utf8.encode(b)).toString();
    final sign = Hmac(sha512, utf8.encode(creds.apiSecret))
        .convert(utf8.encode('$method\n$_prefix$path\n$q\n$bodyHash\n$ts'))
        .toString();
    final h = {
      'KEY': creds.apiKey,
      'Timestamp': ts,
      'SIGN': sign,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final uri = Uri.parse('$_host$_prefix$path${q.isEmpty ? '' : '?$q'}');
    final r = switch (method) {
      'POST' => await client.post(uri, headers: h, body: b),
      'DELETE' => await client.delete(uri, headers: h),
      _ => await client.get(uri, headers: h),
    };
    return decode(r, 'Gate $path');
  }

  @override
  Future<ContractSpec> fetchSpec(String coin) async {
    final r = await client.get(Uri.parse('$_host$_prefix/futures/usdt/contracts/${_c(coin)}'));
    final s = decode(r, 'Gate contract');
    return ContractSpec(
      contractSize: SignedExchange.d(s['quanto_multiplier']),
      qtyStep: 1,
      minQty: SignedExchange.d(s['order_size_min']),
      tickSize: SignedExchange.d(s['order_price_round']),
    );
  }

  @override
  Future<double> availableBalance() async {
    final j = await _req('GET', '/futures/usdt/accounts');
    return SignedExchange.d(j['available']);
  }

  @override
  Future<void> prepare(String coin, int leverage) async {
    // leverage 가 0 이 아니면 격리 마진으로 설정된다.
    await _req('POST', '/futures/usdt/positions/${_c(coin)}/leverage',
        query: {'leverage': '$leverage'});
  }

  @override
  Future<Position?> position(String coin, int leverage) async {
    final p = await _req('GET', '/futures/usdt/positions/${_c(coin)}');
    final size = SignedExchange.d(p['size']);
    if (size == 0) return null;
    final s = await spec(coin);
    return Position(
      coin: coin,
      side: size > 0 ? Side.long : Side.short,
      entryPrice: SignedExchange.d(p['entry_price']),
      qty: size.abs() * s.contractSize,
      leverage: int.tryParse('${p['leverage']}') ?? leverage,
    );
  }

  @override
  Future<double> marketOrder(String coin, Side side, double qty, {bool reduceOnly = false}) async {
    final units = await toUnits(coin, qty);
    await _req('POST', '/futures/usdt/orders', body: {
      'contract': _c(coin),
      'size': side == Side.long ? units.round() : -units.round(),
      'price': '0',
      'tif': 'ioc',
      'reduce_only': reduceOnly,
    });
    return units * (await spec(coin)).contractSize;
  }

  @override
  Future<void> setProtection(String coin, Position pos, double? stopLoss, double? takeProfit) async {
    await cancelProtection(coin);
    // rule 1: 가격 >= 트리거, rule 2: 가격 <= 트리거
    Future<void> place(double price, int rule) async =>
        _req('POST', '/futures/usdt/price_orders', body: {
          'initial': {
            'contract': _c(coin),
            'size': 0,
            'price': '0',
            'tif': 'ioc',
            'close': true,
            'reduce_only': true,
          },
          'trigger': {
            'strategy_type': 0,
            'price_type': 1, // 마크 가격
            'price': await priceStr(coin, price),
            'rule': rule,
            'expiration': 0,
          },
        });
    final long = pos.side == Side.long;
    if (stopLoss != null) await place(stopLoss, long ? 2 : 1);
    if (takeProfit != null) await place(takeProfit, long ? 1 : 2);
  }

  @override
  Future<void> cancelProtection(String coin) async {
    await _req('DELETE', '/futures/usdt/price_orders', query: {'contract': _c(coin)});
  }
}
