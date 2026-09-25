import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// 거래소별 공개 시세(캔들/호가) 조회. API 키가 필요 없다.
class MarketData {
  final http.Client _client;
  MarketData([http.Client? client]) : _client = client ?? http.Client();

  static String symbolFor(ExchangeId ex, String coin) => switch (ex) {
        ExchangeId.okx => '$coin-USDT-SWAP',
        ExchangeId.gate => '${coin}_USDT',
        _ => '${coin}USDT',
      };

  Future<dynamic> _get(String url, String label) async {
    final r = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('$label HTTP ${r.statusCode}');
    return jsonDecode(r.body);
  }

  /// 오래된 봉 → 최신 봉 순서로 돌려준다.
  Future<List<Candle>> candles(ExchangeId ex, String coin, String interval,
      {int limit = 200}) async {
    final s = symbolFor(ex, coin);
    List<Candle> out;
    switch (ex) {
      case ExchangeId.binance:
        final j = await _get(
            'https://fapi.binance.com/fapi/v1/klines?symbol=$s&interval=$interval&limit=$limit',
            'Binance klines') as List;
        out = [for (final k in j) _c(k[0], k[1], k[2], k[3], k[4], k[5])];
      case ExchangeId.bybit:
        final iv = {'1m': '1', '5m': '5', '15m': '15', '1h': '60'}[interval] ?? '1';
        final j = await _get(
            'https://api.bybit.com/v5/market/kline?category=linear&symbol=$s&interval=$iv&limit=$limit',
            'Bybit klines');
        final list = j['result']['list'] as List;
        out = [for (final k in list.reversed) _c(k[0], k[1], k[2], k[3], k[4], k[5])];
      case ExchangeId.okx:
        final iv = interval == '1h' ? '1H' : interval;
        final j = await _get(
            'https://www.okx.com/api/v5/market/candles?instId=$s&bar=$iv&limit=${limit > 300 ? 300 : limit}',
            'OKX candles');
        final list = j['data'] as List;
        out = [for (final k in list.reversed) _c(k[0], k[1], k[2], k[3], k[4], k[5])];
      case ExchangeId.bitget:
        final iv = interval == '1h' ? '1H' : interval;
        final j = await _get(
            'https://api.bitget.com/api/v2/mix/market/candles?symbol=$s&productType=USDT-FUTURES&granularity=$iv&limit=$limit',
            'Bitget klines');
        final list = j['data'] as List;
        out = [for (final k in list) _c(k[0], k[1], k[2], k[3], k[4], k[5])];
      case ExchangeId.gate:
        final j = await _get(
            'https://api.gateio.ws/api/v4/futures/usdt/candlesticks?contract=$s&interval=$interval&limit=$limit',
            'Gate candlesticks') as List;
        out = [
          for (final k in j) _c((k['t'] as num) * 1000, k['o'], k['h'], k['l'], k['c'], k['v'])
        ];
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  Future<Ticker> ticker(ExchangeId ex, String coin) async {
    final s = symbolFor(ex, coin);
    switch (ex) {
      case ExchangeId.binance:
        final j = await _get(
            'https://fapi.binance.com/fapi/v1/ticker/bookTicker?symbol=$s', 'Binance bookTicker');
        final bid = _d(j['bidPrice']), ask = _d(j['askPrice']);
        return Ticker(bid: bid, ask: ask, last: (bid + ask) / 2);
      case ExchangeId.bybit:
        final j = await _get(
            'https://api.bybit.com/v5/market/tickers?category=linear&symbol=$s', 'Bybit tickers');
        final t = (j['result']['list'] as List).first;
        return Ticker(bid: _d(t['bid1Price']), ask: _d(t['ask1Price']), last: _d(t['lastPrice']));
      case ExchangeId.okx:
        final j = await _get('https://www.okx.com/api/v5/market/ticker?instId=$s', 'OKX ticker');
        final t = (j['data'] as List).first;
        return Ticker(bid: _d(t['bidPx']), ask: _d(t['askPx']), last: _d(t['last']));
      case ExchangeId.bitget:
        final j = await _get(
            'https://api.bitget.com/api/v2/mix/market/ticker?symbol=$s&productType=USDT-FUTURES',
            'Bitget ticker');
        final t = (j['data'] as List).first;
        return Ticker(bid: _d(t['bidPr']), ask: _d(t['askPr']), last: _d(t['lastPr']));
      case ExchangeId.gate:
        final j = await _get(
            'https://api.gateio.ws/api/v4/futures/usdt/tickers?contract=$s', 'Gate tickers') as List;
        final t = j.first;
        return Ticker(
            bid: _d(t['highest_bid']), ask: _d(t['lowest_ask']), last: _d(t['last']));
    }
  }

  static double _d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  static Candle _c(dynamic t, dynamic o, dynamic h, dynamic l, dynamic c, dynamic v) => Candle(
        time: DateTime.fromMillisecondsSinceEpoch(_d(t).toInt()),
        open: _d(o),
        high: _d(h),
        low: _d(l),
        close: _d(c),
        volume: _d(v),
      );
}
