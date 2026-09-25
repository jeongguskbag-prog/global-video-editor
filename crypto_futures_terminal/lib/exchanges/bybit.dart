import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/models.dart';
import 'exchange.dart';

/// Bybit V5 USDT 무기한 (단방향 모드, 통합계좌).
class BybitExchange extends SignedExchange {
  static const _base = 'https://api.bybit.com';
  BybitExchange(super.creds);

  @override
  ExchangeId get id => ExchangeId.bybit;

  String _sym(String coin) => '${coin}USDT';

  Future<dynamic> _req(String method, String path,
      {Map<String, String> query = const {}, Map<String, dynamic>? body}) async {
    final ts = '${DateTime.now().millisecondsSinceEpoch}';
    const recv = '5000';
    final q = Uri(queryParameters: query.isEmpty ? null : query).query;
    final payload = method == 'GET' ? q : jsonEncode(body ?? {});
    final sign = Hmac(sha256, utf8.encode(creds.apiSecret))
        .convert(utf8.encode('$ts${creds.apiKey}$recv$payload'))
        .toString();
    final h = {
      'X-BAPI-API-KEY': creds.apiKey,
      'X-BAPI-TIMESTAMP': ts,
      'X-BAPI-RECV-WINDOW': recv,
      'X-BAPI-SIGN': sign,
      'Content-Type': 'application/json',
    };
    final uri = Uri.parse('$_base$path${q.isEmpty ? '' : '?$q'}');
    final r = method == 'GET'
        ? await client.get(uri, headers: h)
        : await client.post(uri, headers: h, body: payload);
    final j = decode(r, 'Bybit $path');
    final code = j['retCode'];
    // 110043: 레버리지 변경 없음, 34040: 손절/익절 변경 없음
    if (code != 0 && code != 110043 && code != 34040) {
      throw ExchangeException('Bybit $path: ${j['retMsg']} ($code)');
    }
    return j['result'];
  }

  @override
  Future<ContractSpec> fetchSpec(String coin) async {
    final r = await client.get(Uri.parse(
        '$_base/v5/market/instruments-info?category=linear&symbol=${_sym(coin)}'));
    final s = (decode(r, 'Bybit instruments')['result']['list'] as List).first;
    return ContractSpec(
      qtyStep: SignedExchange.d(s['lotSizeFilter']['qtyStep']),
      minQty: SignedExchange.d(s['lotSizeFilter']['minOrderQty']),
      tickSize: SignedExchange.d(s['priceFilter']['tickSize']),
    );
  }

  @override
  Future<double> availableBalance() async {
    final j = await _req('GET', '/v5/account/wallet-balance', query: {'accountType': 'UNIFIED'});
    final acc = (j['list'] as List).first;
    return SignedExchange.d(acc['totalAvailableBalance']);
  }

  @override
  Future<void> prepare(String coin, int leverage) async {
    await _req('POST', '/v5/position/set-leverage', body: {
      'category': 'linear',
      'symbol': _sym(coin),
      'buyLeverage': '$leverage',
      'sellLeverage': '$leverage',
    });
  }

  @override
  Future<Position?> position(String coin, int leverage) async {
    final j = await _req('GET', '/v5/position/list',
        query: {'category': 'linear', 'symbol': _sym(coin)});
    for (final p in j['list'] as List) {
      final size = SignedExchange.d(p['size']);
      if (size == 0) continue;
      return Position(
        coin: coin,
        side: p['side'] == 'Buy' ? Side.long : Side.short,
        entryPrice: SignedExchange.d(p['avgPrice']),
        qty: size,
        leverage: int.tryParse('${p['leverage']}'.split('.').first) ?? leverage,
      );
    }
    return null;
  }

  @override
  Future<double> marketOrder(String coin, Side side, double qty, {bool reduceOnly = false}) async {
    final units = await toUnits(coin, qty);
    await _req('POST', '/v5/order/create', body: {
      'category': 'linear',
      'symbol': _sym(coin),
      'side': side == Side.long ? 'Buy' : 'Sell',
      'orderType': 'Market',
      'qty': await unitsStr(coin, units),
      'reduceOnly': reduceOnly,
      'positionIdx': 0,
    });
    return units;
  }

  @override
  Future<void> setProtection(String coin, Position pos, double? stopLoss, double? takeProfit) async {
    await _req('POST', '/v5/position/trading-stop', body: {
      'category': 'linear',
      'symbol': _sym(coin),
      'tpslMode': 'Full',
      'positionIdx': 0,
      'stopLoss': stopLoss == null ? '0' : await priceStr(coin, stopLoss),
      'takeProfit': takeProfit == null ? '0' : await priceStr(coin, takeProfit),
      'slTriggerBy': 'MarkPrice',
      'tpTriggerBy': 'MarkPrice',
    });
  }

  @override
  Future<void> cancelProtection(String coin) async {
    // 포지션이 없으면 Bybit 가 오류를 내므로 무시한다.
    try {
      await _req('POST', '/v5/position/trading-stop', body: {
        'category': 'linear',
        'symbol': _sym(coin),
        'tpslMode': 'Full',
        'positionIdx': 0,
        'stopLoss': '0',
        'takeProfit': '0',
      });
    } on ExchangeException catch (_) {}
  }
}
