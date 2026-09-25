import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/models.dart';

/// 주문 수량/가격 규격. qtyStep 은 거래소 주문 단위(OKX/Gate 는 계약 수) 기준.
class ContractSpec {
  final double contractSize; // 1 계약 = 몇 코인 (Binance/Bybit/Bitget 은 1)
  final double qtyStep;
  final double minQty;
  final double tickSize;
  const ContractSpec({
    this.contractSize = 1,
    required this.qtyStep,
    this.minQty = 0,
    required this.tickSize,
  });
}

class ExchangeException implements Exception {
  final String message;
  ExchangeException(this.message);
  @override
  String toString() => message;
}

/// 실전/모의 공통 거래소 인터페이스. 엔진은 이 인터페이스만 사용한다.
abstract class ExchangeClient {
  ExchangeId get id;
  bool get isPaper => false;

  /// 주문 가능 USDT 잔고.
  Future<double> availableBalance();

  /// 레버리지·격리 마진 설정.
  Future<void> prepare(String coin, int leverage);

  /// 현재 열린 포지션 (없으면 null). 수량은 코인 단위.
  Future<Position?> position(String coin, int leverage);

  /// 시장가 주문. [qty] 는 코인 단위, 내부에서 거래소 단위로 내림 처리.
  /// 실제로 주문된 코인 수량을 돌려준다.
  Future<double> marketOrder(String coin, Side side, double qty, {bool reduceOnly = false});

  /// 거래소에 손절/익절(조건부) 주문을 건다. 기존 것은 먼저 취소한다.
  Future<void> setProtection(String coin, Position pos, double? stopLoss, double? takeProfit);

  Future<void> cancelProtection(String coin);

  Future<void> closePosition(String coin, Position pos) async {
    await cancelProtection(coin);
    await marketOrder(coin, pos.side.opposite, pos.qty, reduceOnly: true);
  }

  void dispose() {}
}

/// HTTP·서명·수량 반올림 공통 처리.
abstract class SignedExchange extends ExchangeClient {
  final ApiCredentials creds;
  final http.Client client = http.Client();
  final Map<String, ContractSpec> _specs = {};

  SignedExchange(this.creds);

  Future<ContractSpec> fetchSpec(String coin);

  Future<ContractSpec> spec(String coin) async =>
      _specs[coin] ??= await fetchSpec(coin);

  static int decimalsOf(double step) {
    if (step <= 0) return 8;
    final d = -math.log(step) / math.ln10;
    return math.max(0, d.ceil()).clamp(0, 12);
  }

  static String fmt(double v, double step) => v.toStringAsFixed(decimalsOf(step));

  /// 코인 수량 → 거래소 주문 단위(내림).
  Future<double> toUnits(String coin, double coinQty) async {
    final s = await spec(coin);
    final units = coinQty / s.contractSize;
    final r = (units / s.qtyStep + 1e-9).floor() * s.qtyStep;
    if (r <= 0 || r < s.minQty) {
      throw ExchangeException('주문 수량이 최소 단위보다 작습니다 (${fmt(units, s.qtyStep)})');
    }
    return r;
  }

  Future<String> unitsStr(String coin, double units) async => fmt(units, (await spec(coin)).qtyStep);

  Future<String> priceStr(String coin, double price) async {
    final t = (await spec(coin)).tickSize;
    return fmt((price / t).round() * t, t);
  }

  static double d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  dynamic decode(http.Response r, String label) {
    dynamic body;
    try {
      body = jsonDecode(r.body);
    } catch (_) {
      throw ExchangeException('$label HTTP ${r.statusCode}: ${r.body}');
    }
    if (r.statusCode >= 400) throw ExchangeException('$label HTTP ${r.statusCode}: ${r.body}');
    return body;
  }

  @override
  void dispose() => client.close();
}
