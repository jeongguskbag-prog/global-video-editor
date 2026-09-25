import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/models.dart';
import 'exchange.dart';

/// Binance USDⓈ-M 선물 (단방향 모드 가정).
class BinanceExchange extends SignedExchange {
  static const _base = 'https://fapi.binance.com';
  BinanceExchange(super.creds);

  @override
  ExchangeId get id => ExchangeId.binance;

  String _sym(String coin) => '${coin}USDT';

  Future<dynamic> _signed(String method, String path, [Map<String, String> params = const {}]) async {
    final q = {
      ...params,
      'recvWindow': '5000',
      'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
    };
    final query = Uri(queryParameters: q).query;
    final sig = Hmac(sha256, utf8.encode(creds.apiSecret)).convert(utf8.encode(query)).toString();
    final uri = Uri.parse('$_base$path?$query&signature=$sig');
    final h = {'X-MBX-APIKEY': creds.apiKey};
    final r = switch (method) {
      'POST' => await client.post(uri, headers: h),
      'DELETE' => await client.delete(uri, headers: h),
      _ => await client.get(uri, headers: h),
    };
    return decode(r, 'Binance $path');
  }

  @override
  Future<ContractSpec> fetchSpec(String coin) async {
    final r = await client.get(Uri.parse('$_base/fapi/v1/exchangeInfo'));
    final j = decode(r, 'Binance exchangeInfo');
    final s = (j['symbols'] as List).firstWhere((e) => e['symbol'] == _sym(coin));
    final f = {for (final x in s['filters'] as List) x['filterType']: x};
    return ContractSpec(
      qtyStep: SignedExchange.d(f['MARKET_LOT_SIZE']?['stepSize'] ?? f['LOT_SIZE']['stepSize']),
      minQty: SignedExchange.d(f['LOT_SIZE']['minQty']),
      tickSize: SignedExchange.d(f['PRICE_FILTER']['tickSize']),
    );
  }

  @override
  Future<double> availableBalance() async {
    final j = await _signed('GET', '/fapi/v2/balance') as List;
    final u = j.firstWhere((e) => e['asset'] == 'USDT', orElse: () => null);
    return u == null ? 0 : SignedExchange.d(u['availableBalance']);
  }

  @override
  Future<void> prepare(String coin, int leverage) async {
    try {
      await _signed('POST', '/fapi/v1/marginType', {'symbol': _sym(coin), 'marginType': 'ISOLATED'});
    } on ExchangeException catch (e) {
      if (!e.message.contains('-4046')) rethrow; // 이미 격리 모드
    }
    await _signed('POST', '/fapi/v1/leverage', {'symbol': _sym(coin), 'leverage': '$leverage'});
  }

  @override
  Future<Position?> position(String coin, int leverage) async {
    final j = await _signed('GET', '/fapi/v2/positionRisk', {'symbol': _sym(coin)}) as List;
    for (final p in j) {
      final amt = SignedExchange.d(p['positionAmt']);
      if (amt == 0) continue;
      return Position(
        coin: coin,
        side: amt > 0 ? Side.long : Side.short,
        entryPrice: SignedExchange.d(p['entryPrice']),
        qty: amt.abs(),
        leverage: int.tryParse('${p['leverage']}') ?? leverage,
      );
    }
    return null;
  }

  @override
  Future<double> marketOrder(String coin, Side side, double qty, {bool reduceOnly = false}) async {
    final units = await toUnits(coin, qty);
    await _signed('POST', '/fapi/v1/order', {
      'symbol': _sym(coin),
      'side': side == Side.long ? 'BUY' : 'SELL',
      'type': 'MARKET',
      'quantity': await unitsStr(coin, units),
      if (reduceOnly) 'reduceOnly': 'true',
    });
    return units;
  }

  @override
  Future<void> setProtection(String coin, Position pos, double? stopLoss, double? takeProfit) async {
    await cancelProtection(coin);
    final side = pos.side == Side.long ? 'SELL' : 'BUY';
    Future<void> place(String type, double price) async => _signed('POST', '/fapi/v1/order', {
          'symbol': _sym(coin),
          'side': side,
          'type': type,
          'stopPrice': await priceStr(coin, price),
          'closePosition': 'true',
          'workingType': 'MARK_PRICE',
        });
    if (stopLoss != null) await place('STOP_MARKET', stopLoss);
    if (takeProfit != null) await place('TAKE_PROFIT_MARKET', takeProfit);
  }

  @override
  Future<void> cancelProtection(String coin) async {
    await _signed('DELETE', '/fapi/v1/allOpenOrders', {'symbol': _sym(coin)});
  }
}
