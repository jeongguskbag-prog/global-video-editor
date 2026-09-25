import 'models.dart';

/// 자동매매 설정. 설정 탭에서 편집하고 SharedPreferences 에 JSON 으로 저장한다.
class TradingConfig {
  ExchangeId exchange;
  String coin;
  StrategyType strategy;
  bool live;
  String interval; // 1m, 5m, 15m, 1h
  int pollSeconds;

  int leverage;
  double marginPerTrade; // USDT
  double? stopLossPct;
  double? takeProfitPct;
  double? riskPerTradePct; // 설정 시 손실이 계좌의 이 % 를 넘지 않도록 수량 자동 계산
  bool averageDownEnabled;
  double? averageDownPct; // 손절 % 보다 작아야 함
  double? dailyLossLimitPct;
  int cooldownLosses;
  double cooldownHours;
  double? maxSpreadPct;
  bool trendFilter; // 상위 타임프레임(1h EMA200) 추세 필터
  bool multiCoinScan;

  double demoStartBalance;
  String displayCurrency; // USD, KRW, JPY ...

  String telegramToken;
  String telegramChatId;

  TradingConfig({
    this.exchange = ExchangeId.binance,
    this.coin = 'BTC',
    this.strategy = StrategyType.maCross,
    this.live = false,
    this.interval = '1m',
    this.pollSeconds = 10,
    this.leverage = 5,
    this.marginPerTrade = 20,
    this.stopLossPct = 2,
    this.takeProfitPct = 4,
    this.riskPerTradePct,
    this.averageDownEnabled = false,
    this.averageDownPct,
    this.dailyLossLimitPct,
    this.cooldownLosses = 3,
    this.cooldownHours = 1,
    this.maxSpreadPct = 0.05,
    this.trendFilter = false,
    this.multiCoinScan = false,
    this.demoStartBalance = 1000,
    this.displayCurrency = 'USD',
    this.telegramToken = '',
    this.telegramChatId = '',
  });

  /// 물타기 % 기본값: 손절 직전(손절 % 의 90%).
  double? get defaultAverageDownPct =>
      stopLossPct == null ? null : double.parse((stopLossPct! * 0.9).toStringAsFixed(2));

  /// 잘못된 값이 있으면 사용자에게 보여줄 메시지를, 정상이면 null 을 돌려준다.
  String? validate() {
    if (leverage < 1 || leverage > 125) return '레버리지는 1~125 사이여야 합니다.';
    if (marginPerTrade <= 0) return '거래당 마진(USDT)을 올바르게 입력해 주세요.';
    if (stopLossPct != null && stopLossPct! <= 0) return '손절 %를 올바르게 입력해 주세요.';
    if (takeProfitPct != null && takeProfitPct! <= 0) return '익절 비율(%)을 올바르게 입력해 주세요.';
    if (riskPerTradePct != null) {
      if (riskPerTradePct! <= 0) return '거래당 리스크(%)를 올바르게 입력해 주세요.';
      if (stopLossPct == null) return '거래당 리스크를 쓰려면 손절 %가 필요합니다.';
    }
    if (averageDownEnabled) {
      final a = averageDownPct;
      if (stopLossPct == null || a == null || a <= 0 || a >= stopLossPct!) {
        return '물타기 발동 %를 손절 %보다 작은 값으로 올바르게 입력해 주세요. '
            '손절 %가 비어있으면 먼저 손절 %를 입력해야 합니다.';
      }
    }
    if (pollSeconds < 5) return '조회 주기는 5초 이상이어야 합니다.';
    if (cooldownLosses < 0 || cooldownHours < 0) return '쿨다운 값을 올바르게 입력해 주세요.';
    return null;
  }

  Map<String, dynamic> toJson() => {
        'exchange': exchange.name,
        'coin': coin,
        'strategy': strategy.name,
        'live': live,
        'interval': interval,
        'pollSeconds': pollSeconds,
        'leverage': leverage,
        'marginPerTrade': marginPerTrade,
        'stopLossPct': stopLossPct,
        'takeProfitPct': takeProfitPct,
        'riskPerTradePct': riskPerTradePct,
        'averageDownEnabled': averageDownEnabled,
        'averageDownPct': averageDownPct,
        'dailyLossLimitPct': dailyLossLimitPct,
        'cooldownLosses': cooldownLosses,
        'cooldownHours': cooldownHours,
        'maxSpreadPct': maxSpreadPct,
        'trendFilter': trendFilter,
        'multiCoinScan': multiCoinScan,
        'demoStartBalance': demoStartBalance,
        'displayCurrency': displayCurrency,
        'telegramToken': telegramToken,
        'telegramChatId': telegramChatId,
      };

  factory TradingConfig.fromJson(Map<String, dynamic> j) {
    double? d(String k) => (j[k] as num?)?.toDouble();
    T pick<T extends Enum>(List<T> values, String k, T fallback) {
      final name = j[k] as String?;
      return values.where((v) => v.name == name).firstOrNull ?? fallback;
    }

    final def = TradingConfig();
    return TradingConfig(
      exchange: pick(ExchangeId.values, 'exchange', def.exchange),
      coin: j['coin'] as String? ?? def.coin,
      strategy: pick(StrategyType.values, 'strategy', def.strategy),
      // 실전 모드는 앱 재시작 시 항상 꺼진 상태로 시작한다(생체 인증을 다시 받기 위해).
      live: false,
      interval: j['interval'] as String? ?? def.interval,
      pollSeconds: (j['pollSeconds'] as num?)?.toInt() ?? def.pollSeconds,
      leverage: (j['leverage'] as num?)?.toInt() ?? def.leverage,
      marginPerTrade: d('marginPerTrade') ?? def.marginPerTrade,
      stopLossPct: j.containsKey('stopLossPct') ? d('stopLossPct') : def.stopLossPct,
      takeProfitPct: j.containsKey('takeProfitPct') ? d('takeProfitPct') : def.takeProfitPct,
      riskPerTradePct: d('riskPerTradePct'),
      averageDownEnabled: j['averageDownEnabled'] as bool? ?? false,
      averageDownPct: d('averageDownPct'),
      dailyLossLimitPct: d('dailyLossLimitPct'),
      cooldownLosses: (j['cooldownLosses'] as num?)?.toInt() ?? def.cooldownLosses,
      cooldownHours: d('cooldownHours') ?? def.cooldownHours,
      maxSpreadPct: j.containsKey('maxSpreadPct') ? d('maxSpreadPct') : def.maxSpreadPct,
      trendFilter: j['trendFilter'] as bool? ?? false,
      multiCoinScan: j['multiCoinScan'] as bool? ?? false,
      demoStartBalance: d('demoStartBalance') ?? def.demoStartBalance,
      displayCurrency: j['displayCurrency'] as String? ?? def.displayCurrency,
      telegramToken: j['telegramToken'] as String? ?? '',
      telegramChatId: j['telegramChatId'] as String? ?? '',
    );
  }

  TradingConfig copy() => TradingConfig.fromJson(toJson())..live = live;
}

/// 거래소 API 키. Android Keystore 기반 보안 저장소에만 저장한다.
class ApiCredentials {
  final String apiKey;
  final String apiSecret;
  final String passphrase;

  const ApiCredentials({this.apiKey = '', this.apiSecret = '', this.passphrase = ''});

  bool isCompleteFor(ExchangeId ex) =>
      apiKey.isNotEmpty && apiSecret.isNotEmpty && (!ex.needsPassphrase || passphrase.isNotEmpty);
}
