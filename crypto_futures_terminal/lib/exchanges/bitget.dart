import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../core/models.dart';
import 'exchange.dart';

/// Bitget V2 USDT-M 선물 (단방향 모드, 격리 마진).
class BitgetExchange extends SignedExchange {
  static const _base = 'https://api.bitget.com';
  static const _pt = 'USDT-FUTURES';
  BitgetExchange(super.creds);

  @override
  ExchangeId get id => ExchangeId.bitget;

  String _sym(String coin) => '${coin}USDT';

  Future<dynamic> _req(String method, String path,
      {Map<String, String> query = const {}, Map<String, dynamic>? body}) async {
    final ts = '${DateTime.now().millisecondsSinceEpoch}';
    final q = Uri(queryParameters: query.isEmpty ? null : query).query;
    final pathQ = q.isEmpty ? path : '$path?$q';
    final b = body == null ? '' : jsonEncode(body);
    final sign = base64.encode(Hmac(sha256, utf8.encode(creds.apiSecret))
        .convert(utf8.encode('$ts$method$pathQ$b'))
        .bytes);
    final h = {
      'ACCESS-KEY': creds.apiKey,
      'ACCESS-SIGN': sign,
      'ACCESS-TIMESTAMP': ts,
      'ACCESS-PASSPHRASE': creds.passphrase,
      'Content-Type': 'application/json',
      'locale': 'en-US',
    };
    final uri = Uri.parse('$_base$pathQ');
    final r = method == 'GET'
        ? await client.get(uri, headers: h)
        : await client.post(uri, headers: h, body: b);
    final j = decode(r, 'Bitget $path');
    if ('${j['code']}' != '00000') throw ExchangeException('Bitget $path: ${j['msg']} (${j['code']})');
    return j['data'];
  }

  @override
  Future<ContractSpec> fetchSpec(String coin) async {
    final r = await client.get(
        Uri.parse('$_base/api/v2/mix/market/contracts?productType=$_pt&symbol=${_sym(coin)}'));
    final s = (decode(r, 'Bitget contracts')['data'] as List).first;
    final place = int.tryParse('${s['pricePlace']}') ?? 2;
    final endStep = SignedExchange.d(s['priceEndStep']);
    return ContractSpec(
      qtyStep: SignedExchange.d(s['sizeMultiplier']),
      minQty: SignedExchange.d(s['minTradeNum']),
      tickSize: (endStep == 0 ? 1 : endStep) * math.pow(10, -place).toDouble(),
    );
  }

  @override
  Future<double> availableBalance() async {
    final d = await _req('GET', '/api/v2/mix/account/accounts', query: {'productType': _pt}) as List;
    final u = d.firstWhere((e) => e['marginCoin'] == 'USDT', orElse: () => null);
    return u == null ? 0 : SignedExchange.d(u['available']);
  }

  @override
  Future<void> prepare(String coin, int leverage) async {
    final base = {'symbol': _sym(coin), 'productType': _pt, 'marginCoin': 'USDT'};
    try {
      await _req('POST', '/api/v2/mix/account/set-margin-mode',
          body: {...base, 'marginMode': 'isolated'});
    } on ExchangeException catch (_) {
      // 포지션/주문이 있으면 모드 변경이 거부된다. 이미 격리일 가능성이 높으므로 무시.
    }
    await _req('POST', '/api/v2/mix/account/set-leverage', body: {...base, 'leverage': '$leverage'});
  }

  @override
  Future<Position?> position(String coin, int leverage) async {
    final d = await _req('GET', '/api/v2/mix/position/single-position',
        query: {'symbol': _sym(coin), 'productType': _pt, 'marginCoin': 'USDT'}) as List;
    for (final p in d) {
      final total = SignedExchange.d(p['total']);
      if (total == 0) continue;
      final hs = '${p['holdSide']}';
      return Position(
        coin: coin,
        side: (hs == 'long' || hs == 'buy') ? Side.long : Side.short,
        entryPrice: SignedExchange.d(p['openPriceAvg']),
        qty: total,
        leverage: int.tryParse('${p['leverage']}') ?? leverage,
      );
    }
    return null;
  }

  @override
  Future<double> marketOrder(String coin, Side side, double qty, {bool reduceOnly = false}) async {
    final units = await toUnits(coin, qty);
    await _req('POST', '/api/v2/mix/order/place-order', body: {
      'symbol': _sym(coin),
      'productType': _pt,
      'marginMode': 'isolated',
      'marginCoin': 'USDT',
      'size': await unitsStr(coin, units),
      'side': side == Side.long ? 'buy' : 'sell',
      'orderType': 'market',
      'reduceOnly': reduceOnly ? 'YES' : 'NO',
    });
    return units;
  }

  @override
  Future<void> setProtection(String coin, Position pos, double? stopLoss, double? takeProfit) async {
    await cancelProtection(coin);
    Future<void> place(String planType, double price) async =>
        _req('POST', '/api/v2/mix/order/place-tpsl-order', body: {
          'marginCoin': 'USDT',
          'productType': _pt,
          'symbol': _sym(coin),
          'planType': planType,
          'triggerPrice': await priceStr(coin, price),
          'triggerType': 'mark_price',
          // 단방향 모드에서는 buy = 롱 포지션, sell = 숏 포지션
          'holdSide': pos.side == Side.long ? 'buy' : 'sell',
        });
    if (stopLoss != null) await place('pos_loss', stopLoss);
    if (takeProfit != null) await place('pos_profit', takeProfit);
  }

  @override
  Future<void> cancelProtection(String coin) async {
    try {
      await _req('POST', '/api/v2/mix/order/cancel-plan-order', body: {
        'symbol': _sym(coin),
        'productType': _pt,
        'marginCoin': 'USDT',
        'planType': 'profit_loss',
      });
    } on ExchangeException catch (_) {
      // 취소할 주문이 없으면 오류가 난다.
    }
  }
}
