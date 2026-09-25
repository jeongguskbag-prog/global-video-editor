// 앱 설정. 비밀값(API 키)은 여기 없고 SecureStore 에 따로 보관한다.
import 'dart:convert';

class RiskConfig {
  double budgetPerTrade;
  double? riskPerTradePct;
  double? stopLossPct;
  double? takeProfitPct;
  double? trailingStopPct;
  double? averageDownPct;
  double? dailyLossLimitPct;
  int? maxConsecutiveLosses;
  double cooldownHours;
  double? maxSpreadPct;
  int maxPositions;
  double feeRate;
  double taxRate;
  double? exitMinutesBeforeClose;

  RiskConfig({
    this.budgetPerTrade = 1000000,
    this.riskPerTradePct,
    this.stopLossPct = 3,
    this.takeProfitPct = 6,
    this.trailingStopPct,
    this.averageDownPct,
    this.dailyLossLimitPct = 5,
    this.maxConsecutiveLosses = 3,
    this.cooldownHours = 24,
    this.maxSpreadPct = 0.5,
    this.maxPositions = 5,
    this.feeRate = 0.00015,
    this.taxRate = 0.0020,
    this.exitMinutesBeforeClose,
  });

  /// 문제가 있으면 한글 메시지, 없으면 null.
  String? validate() {
    if (averageDownPct != null && (stopLossPct == null || averageDownPct! >= stopLossPct!)) {
      return '물타기 % 는 손절 % 보다 작아야 합니다';
    }
    if (riskPerTradePct != null && (stopLossPct == null || stopLossPct == 0)) {
      return '1회 위험 % 를 쓰려면 손절 % 가 필요합니다';
    }
    if (riskPerTradePct == null && budgetPerTrade <= 0) return '1회 매수 금액은 0보다 커야 합니다';
    if (maxPositions < 1) return '최대 보유 종목 수는 1 이상이어야 합니다';
    return null;
  }

  Map<String, dynamic> toJson() => {
        'budgetPerTrade': budgetPerTrade,
        'riskPerTradePct': riskPerTradePct,
        'stopLossPct': stopLossPct,
        'takeProfitPct': takeProfitPct,
        'trailingStopPct': trailingStopPct,
        'averageDownPct': averageDownPct,
        'dailyLossLimitPct': dailyLossLimitPct,
        'maxConsecutiveLosses': maxConsecutiveLosses,
        'cooldownHours': cooldownHours,
        'maxSpreadPct': maxSpreadPct,
        'maxPositions': maxPositions,
        'feeRate': feeRate,
        'taxRate': taxRate,
        'exitMinutesBeforeClose': exitMinutesBeforeClose,
      };

  factory RiskConfig.fromJson(Map<String, dynamic> j) {
    double? d(String k) => (j[k] as num?)?.toDouble();
    return RiskConfig(
      budgetPerTrade: d('budgetPerTrade') ?? 1000000,
      riskPerTradePct: d('riskPerTradePct'),
      stopLossPct: d('stopLossPct'),
      takeProfitPct: d('takeProfitPct'),
      trailingStopPct: d('trailingStopPct'),
      averageDownPct: d('averageDownPct'),
      dailyLossLimitPct: d('dailyLossLimitPct'),
      maxConsecutiveLosses: (j['maxConsecutiveLosses'] as num?)?.toInt(),
      cooldownHours: d('cooldownHours') ?? 24,
      maxSpreadPct: d('maxSpreadPct'),
      maxPositions: (j['maxPositions'] as num?)?.toInt() ?? 5,
      feeRate: d('feeRate') ?? 0.00015,
      taxRate: d('taxRate') ?? 0.0020,
      exitMinutesBeforeClose: d('exitMinutesBeforeClose'),
    );
  }
}

class AppConfig {
  String broker; // paper | kis | kiwoom | ls | db | nh
  bool live; // false = 모의투자
  List<String> symbols;
  bool marketOrder;
  int pollSeconds;
  int orderCooldownSeconds;
  double paperCash;
  String strategy;
  String interval; // D 또는 1m,3m,5m,10m,15m,30m,60m
  int candles;
  int? trendFilterPeriod;
  List<String> holidays;
  RiskConfig risk;

  AppConfig({
    this.broker = 'paper',
    this.live = false,
    List<String>? symbols,
    this.marketOrder = true,
    this.pollSeconds = 30,
    this.orderCooldownSeconds = 90,
    this.paperCash = 10000000,
    this.strategy = 'ma_rsi',
    this.interval = '5m',
    this.candles = 60,
    this.trendFilterPeriod = 60,
    List<String>? holidays,
    RiskConfig? risk,
  })  : symbols = symbols ?? ['005930', '000660'],
        holidays = holidays ?? [],
        risk = risk ?? RiskConfig();

  String? validate() {
    if (symbols.isEmpty) return '감시 종목을 하나 이상 넣어 주세요';
    for (final s in symbols) {
      if (!RegExp(r'^[0-9A-Z]{6}$').hasMatch(s)) return '종목코드는 6자리여야 합니다: $s';
    }
    if (pollSeconds < 5) return '조회 주기는 5초 이상이어야 합니다';
    if (!RegExp(r'^(D|\d+m)$').hasMatch(interval)) return '봉 간격은 D 또는 5m 같은 형식이어야 합니다';
    return risk.validate();
  }

  Map<String, dynamic> toJson() => {
        'broker': broker,
        'live': live,
        'symbols': symbols,
        'marketOrder': marketOrder,
        'pollSeconds': pollSeconds,
        'orderCooldownSeconds': orderCooldownSeconds,
        'paperCash': paperCash,
        'strategy': strategy,
        'interval': interval,
        'candles': candles,
        'trendFilterPeriod': trendFilterPeriod,
        'holidays': holidays,
        'risk': risk.toJson(),
      };

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        broker: j['broker'] as String? ?? 'paper',
        live: j['live'] as bool? ?? false,
        symbols: (j['symbols'] as List?)?.cast<String>(),
        marketOrder: j['marketOrder'] as bool? ?? true,
        pollSeconds: (j['pollSeconds'] as num?)?.toInt() ?? 30,
        orderCooldownSeconds: (j['orderCooldownSeconds'] as num?)?.toInt() ?? 90,
        paperCash: (j['paperCash'] as num?)?.toDouble() ?? 10000000,
        strategy: j['strategy'] as String? ?? 'ma_rsi',
        interval: j['interval'] as String? ?? '5m',
        candles: (j['candles'] as num?)?.toInt() ?? 60,
        trendFilterPeriod: (j['trendFilterPeriod'] as num?)?.toInt(),
        holidays: (j['holidays'] as List?)?.cast<String>(),
        risk: j['risk'] is Map ? RiskConfig.fromJson((j['risk'] as Map).cast<String, dynamic>()) : null,
      );

  String encode() => jsonEncode(toJson());
  static AppConfig decode(String? s) {
    if (s == null || s.isEmpty) return AppConfig();
    try {
      return AppConfig.fromJson((jsonDecode(s) as Map).cast<String, dynamic>());
    } catch (_) {
      return AppConfig();
    }
  }
}

/// '5m' → 5, 'D' → null
int? parseInterval(String interval) {
  if (interval.toUpperCase() == 'D') return null;
  final m = RegExp(r'^(\d+)m$').firstMatch(interval);
  if (m == null || int.parse(m.group(1)!) <= 0) throw ArgumentError('지원하지 않는 봉 간격: $interval');
  return int.parse(m.group(1)!);
}
