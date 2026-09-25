// 공통 데이터 모델.
enum Side { buy, sell }

enum OrderType { market, limit }

class Candle {
  final DateTime time;
  final double open, high, low, close, volume;
  const Candle(this.time, this.open, this.high, this.low, this.close, [this.volume = 0]);
}

class Quote {
  final String symbol;
  final double price;
  final double? bid, ask;
  const Quote(this.symbol, this.price, {this.bid, this.ask});

  double? get spreadPct {
    final b = bid, a = ask;
    if (b == null || a == null || b <= 0) return null;
    return (a - b) / b * 100;
  }
}

class Position {
  final String symbol;
  final int qty;
  final double avgPrice;
  final String name;
  final double currentPrice;
  const Position(this.symbol, this.qty, this.avgPrice, {this.name = '', this.currentPrice = 0});

  double get unrealizedPnl => (currentPrice - avgPrice) * qty;
  double get pnlPct => avgPrice > 0 ? (currentPrice / avgPrice - 1) * 100 : 0;
}

class Balance {
  final double cash;
  final double totalEval;
  final List<Position> positions;
  const Balance(this.cash, this.totalEval, this.positions);
}

class OrderResult {
  final bool ok;
  final String orderId;
  final String message;
  final double price;
  const OrderResult(this.ok, {this.orderId = '', this.message = '', this.price = 0});
}

class BrokerException implements Exception {
  final String message;
  BrokerException(this.message);
  @override
  String toString() => message;
}
