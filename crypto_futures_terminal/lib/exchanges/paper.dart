import '../core/market.dart';
import '../core/models.dart';
import 'exchange.dart';

/// 데모(모의투자) 거래소. 실제 시세로 가상 체결하며, 실제 주문은 나가지 않는다.
class PaperExchange extends ExchangeClient {
  static const takerFee = 0.0005;

  @override
  final ExchangeId id;
  final MarketData market;
  double balance; // 가용 잔고 (증거금 제외)
  final Map<String, Position> _positions = {};
  final Map<String, (double?, double?)> _protection = {};
  final void Function(double balance)? onBalanceChanged;

  int _pendingLeverage = 1;

  PaperExchange(this.id, this.market, this.balance, {this.onBalanceChanged});

  @override
  bool get isPaper => true;

  @override
  Future<double> availableBalance() async => balance;

  /// 가용 잔고 + 포지션 증거금 (미실현 손익 제외).
  double get equity => balance + _positions.values.fold(0.0, (s, p) => s + p.margin);

  @override
  Future<void> prepare(String coin, int leverage) async => _pendingLeverage = leverage;

  Future<double> _price(String coin) async => (await market.ticker(id, coin)).mid;

  /// 조건부 주문(손절/익절) 체결을 흉내낸다.
  @override
  Future<Position?> position(String coin, int leverage) async {
    final p = _positions[coin];
    if (p == null) return null;
    final (sl, tp) = _protection[coin] ?? (null, null);
    if (sl != null || tp != null) {
      final price = await _price(coin);
      final long = p.side == Side.long;
      final hitSl = sl != null && (long ? price <= sl : price >= sl);
      final hitTp = tp != null && (long ? price >= tp : price <= tp);
      if (hitSl || hitTp) {
        _settle(coin, p, hitSl ? sl : tp!);
        return null;
      }
    }
    return p;
  }

  void _settle(String coin, Position p, double exit) {
    final pnl = p.unrealizedPnl(exit) - exit * p.qty * takerFee;
    balance += p.margin + pnl;
    _positions.remove(coin);
    _protection.remove(coin);
    onBalanceChanged?.call(balance);
  }

  @override
  Future<double> marketOrder(String coin, Side side, double qty, {bool reduceOnly = false}) async {
    if (qty <= 0) throw ExchangeException('수량이 0입니다');
    final t = await market.ticker(id, coin);
    // 매수는 매도1호가, 매도는 매수1호가로 체결
    final fill = side == Side.long ? (t.ask > 0 ? t.ask : t.last) : (t.bid > 0 ? t.bid : t.last);
    final cur = _positions[coin];
    if (reduceOnly) {
      if (cur == null || cur.side == side) return 0;
      _settle(coin, cur, fill);
      return cur.qty;
    }
    final lev = cur?.leverage ?? _pendingLeverage;
    final margin = fill * qty / lev;
    final fee = fill * qty * takerFee;
    if (margin + fee > balance) {
      throw ExchangeException('데모 잔고 부족 (필요 ${(margin + fee).toStringAsFixed(2)} USDT)');
    }
    balance -= margin + fee;
    if (cur == null) {
      _positions[coin] = Position(coin: coin, side: side, entryPrice: fill, qty: qty, leverage: lev);
    } else {
      final total = cur.qty + qty;
      _positions[coin] =
          cur.copyWith(qty: total, entryPrice: (cur.entryPrice * cur.qty + fill * qty) / total);
    }
    onBalanceChanged?.call(balance);
    return qty;
  }

  @override
  Future<void> setProtection(String coin, Position pos, double? stopLoss, double? takeProfit) async {
    _protection[coin] = (stopLoss, takeProfit);
  }

  @override
  Future<void> cancelProtection(String coin) async => _protection.remove(coin);

  void reset(double startBalance) {
    _positions.clear();
    _protection.clear();
    balance = startBalance;
    onBalanceChanged?.call(balance);
  }
}
