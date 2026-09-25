/// 앱 전체에서 쓰는 기본 데이터 모델.
library;

enum ExchangeId { binance, bybit, okx, bitget, gate }

extension ExchangeIdX on ExchangeId {
  String get label => switch (this) {
        ExchangeId.binance => '바이낸스 (Binance)',
        ExchangeId.bybit => '바이비트 (Bybit)',
        ExchangeId.okx => 'OKX',
        ExchangeId.bitget => '비트겟 (Bitget)',
        ExchangeId.gate => '게이트아이오 (Gate.io)',
      };

  /// OKX / Bitget 은 API Passphrase 가 추가로 필요하다.
  bool get needsPassphrase =>
      this == ExchangeId.okx || this == ExchangeId.bitget;
}

/// 감시 대상 코인 (Top 5).
const List<String> kCoins = ['BTC', 'ETH', 'BNB', 'SOL', 'XRP'];

enum Side { long, short }

extension SideX on Side {
  String get label => this == Side.long ? '롱' : '숏';
  Side get opposite => this == Side.long ? Side.short : Side.long;

  /// 롱이면 +1, 숏이면 -1. 손익 계산에 사용.
  double get sign => this == Side.long ? 1 : -1;
}

enum StrategyType { maCross, rsi, maRsi, enterAtLow, resistanceHigh }

extension StrategyTypeX on StrategyType {
  String get label => switch (this) {
        StrategyType.maCross => 'MA 크로스 (9/21)',
        StrategyType.rsi => 'RSI 과매수/과매도',
        StrategyType.maRsi => '이평+RSI 결합',
        StrategyType.enterAtLow => '최저가 진입',
        StrategyType.resistanceHigh => '최고가 저항',
      };
}

class Candle {
  final DateTime time;
  final double open, high, low, close, volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });
}

class Ticker {
  final double bid, ask, last;
  const Ticker({required this.bid, required this.ask, required this.last});

  double get mid => (bid > 0 && ask > 0) ? (bid + ask) / 2 : last;

  /// 매수/매도 호가 스프레드 (%).
  double get spreadPct => (bid > 0 && ask > 0) ? (ask - bid) / mid * 100 : 0;
}

/// 거래소(또는 모의 계좌)에 열려 있는 포지션.
class Position {
  final String coin;
  final Side side;
  final double entryPrice;
  final double qty; // 코인 수량
  final int leverage;

  const Position({
    required this.coin,
    required this.side,
    required this.entryPrice,
    required this.qty,
    required this.leverage,
  });

  double get notional => entryPrice * qty;
  double get margin => leverage > 0 ? notional / leverage : notional;

  double unrealizedPnl(double price) => (price - entryPrice) * qty * side.sign;

  double unrealizedPct(double price) =>
      margin > 0 ? unrealizedPnl(price) / margin * 100 : 0;

  Position copyWith({double? entryPrice, double? qty}) => Position(
        coin: coin,
        side: side,
        entryPrice: entryPrice ?? this.entryPrice,
        qty: qty ?? this.qty,
        leverage: leverage,
      );
}

class Signal {
  final Side? side;
  final String reason;
  const Signal(this.side, this.reason);
  const Signal.none(this.reason) : side = null;
}

/// 청산 완료된 거래 1건.
class TradeRecord {
  final String coin;
  final Side side;
  final double entryPrice;
  final double exitPrice;
  final double qty;
  final int leverage;
  final double pnl;
  final String reason;
  final bool live;
  final ExchangeId exchange;
  final DateTime openedAt;
  final DateTime closedAt;

  const TradeRecord({
    required this.coin,
    required this.side,
    required this.entryPrice,
    required this.exitPrice,
    required this.qty,
    required this.leverage,
    required this.pnl,
    required this.reason,
    required this.live,
    required this.exchange,
    required this.openedAt,
    required this.closedAt,
  });

  double get pnlPct {
    final margin = entryPrice * qty / (leverage == 0 ? 1 : leverage);
    return margin > 0 ? pnl / margin * 100 : 0;
  }

  Map<String, dynamic> toJson() => {
        'coin': coin,
        'side': side.name,
        'entry': entryPrice,
        'exit': exitPrice,
        'qty': qty,
        'lev': leverage,
        'pnl': pnl,
        'reason': reason,
        'live': live,
        'ex': exchange.name,
        'open': openedAt.millisecondsSinceEpoch,
        'close': closedAt.millisecondsSinceEpoch,
      };

  factory TradeRecord.fromJson(Map<String, dynamic> j) => TradeRecord(
        coin: j['coin'] as String,
        side: Side.values.byName(j['side'] as String),
        entryPrice: (j['entry'] as num).toDouble(),
        exitPrice: (j['exit'] as num).toDouble(),
        qty: (j['qty'] as num).toDouble(),
        leverage: (j['lev'] as num).toInt(),
        pnl: (j['pnl'] as num).toDouble(),
        reason: j['reason'] as String? ?? '',
        live: j['live'] as bool? ?? false,
        exchange: ExchangeId.values.byName(j['ex'] as String? ?? 'binance'),
        openedAt: DateTime.fromMillisecondsSinceEpoch(j['open'] as int),
        closedAt: DateTime.fromMillisecondsSinceEpoch(j['close'] as int),
      );
}

class LogEntry {
  final DateTime time;
  final String message;
  LogEntry(this.message) : time = DateTime.now();
}
