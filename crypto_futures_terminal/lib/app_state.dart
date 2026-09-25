import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/config.dart';
import 'core/engine.dart';
import 'core/history.dart';
import 'core/market.dart';
import 'core/models.dart';
import 'core/risk.dart';
import 'exchanges/binance.dart';
import 'exchanges/bitget.dart';
import 'exchanges/bybit.dart';
import 'exchanges/exchange.dart';
import 'exchanges/gate.dart';
import 'exchanges/okx.dart';
import 'exchanges/paper.dart';
import 'services/app_lock.dart';
import 'services/currency.dart';
import 'services/foreground.dart';
import 'services/storage.dart';
import 'services/telegram.dart';

/// 4개 탭이 공유하는 앱 상태.
class AppState extends ChangeNotifier {
  final storage = Storage();
  final market = MarketData();
  final history = TradeHistoryStore();
  final currency = CurrencyService();
  final lock = AppLock();
  final riskState = RiskState();

  TradingConfig config = TradingConfig();
  ApiCredentials creds = const ApiCredentials();
  late TradingEngine engine;
  PaperExchange? _paper;

  bool loaded = false;

  /// 이전 실행에서 자동매매가 켜진 채로 앱이 종료됐는지.
  bool resumedAfterKill = false;
  Timer? _refreshTimer;

  bool get running => engine.running;

  Future<void> init() async {
    config = await storage.loadConfig();
    creds = await storage.loadCredentials(config.exchange);
    await history.load();
    resumedAfterKill = await storage.wasActive();
    await storage.setActive(false);
    unawaited(currency.refresh());
    await _rebuildEngine();
    loaded = true;
    _startRefresh();
    notifyListeners();
  }

  Future<ExchangeClient> _client() async {
    if (!config.live) {
      // 설정 저장으로 엔진을 다시 만들어도 열린 데모 포지션은 유지한다.
      final prev = _paper;
      if (prev != null && prev.id == config.exchange) return prev;
      final bal = await storage.loadPaperBalance() ?? config.demoStartBalance;
      return _paper = PaperExchange(config.exchange, market, bal,
          onBalanceChanged: (b) => storage.savePaperBalance(b));
    }
    _paper = null;
    return switch (config.exchange) {
      ExchangeId.binance => BinanceExchange(creds),
      ExchangeId.bybit => BybitExchange(creds),
      ExchangeId.okx => OkxExchange(creds),
      ExchangeId.bitget => BitgetExchange(creds),
      ExchangeId.gate => GateExchange(creds),
    };
  }

  Future<void> _rebuildEngine() async {
    if (loaded) {
      engine.stop();
      if (!engine.ex.isPaper) engine.dispose();
    }
    engine = TradingEngine(
      cfg: config,
      ex: await _client(),
      market: market,
      history: history,
      telegram: TelegramNotifier(config.telegramToken, config.telegramChatId),
      state: riskState,
      onChanged: notifyListeners,
    );
    unawaited(engine.refresh());
  }

  /// 자동매매가 꺼져 있을 때도 대시보드 시세/잔고를 갱신.
  void _startRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!engine.running) engine.refresh();
    });
  }

  // ------------------------------------------------------------------ 자동매매

  Future<String?> startTrading() async {
    if (config.live && !creds.isCompleteFor(config.exchange)) {
      return '실전 모드는 ${config.exchange.label} API Key/Secret 입력이 필요합니다.';
    }
    try {
      await engine.start();
      await storage.setActive(true);
      await ForegroundService.start(
          '${config.live ? '실전' : '데모'} · ${config.exchange.label} · ${config.strategy.label}');
      return null;
    } catch (e) {
      await engine.stop(reason: '자동매매 시작 실패: $e');
      return '자동매매 시작 실패: $e';
    }
  }

  Future<void> stopTrading() async {
    await engine.stop();
    await storage.setActive(false);
    await ForegroundService.stop();
    notifyListeners();
  }

  Future<String?> testEntry(Side side) async {
    if (config.live) return '테스트 진입은 데모 모드에서만 사용할 수 있습니다.';
    try {
      await engine.openPosition(config.coin, side, reason: '테스트 ${side.label} 진입');
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> closePosition() async {
    try {
      await engine.closePosition();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  // ------------------------------------------------------------------ 설정

  /// 설정 저장. 자동매매 중에는 거부한다.
  Future<String?> saveConfig(TradingConfig next, {ApiCredentials? newCreds}) async {
    if (running) return '자동매매를 먼저 중지한 뒤 저장하세요.';
    final err = next.validate();
    if (err != null) return err;
    final exchangeChanged = next.exchange != config.exchange;
    config = next;
    await storage.saveConfig(config);
    if (newCreds != null) {
      creds = newCreds;
      await storage.saveCredentials(config.exchange, creds);
    } else if (exchangeChanged) {
      creds = await storage.loadCredentials(config.exchange);
    }
    await _rebuildEngine();
    notifyListeners();
    return null;
  }

  Future<ApiCredentials> credentialsFor(ExchangeId ex) => storage.loadCredentials(ex);

  /// 실전 모드 전환은 지문/PIN 확인 후에만 허용.
  Future<String?> setLive(bool live) async {
    if (running) return '자동매매를 먼저 중지하세요.';
    if (live) {
      final ok = await lock.verify('실전 모드로 전환하려면 본인 확인이 필요합니다.');
      if (!ok) return '인증에 실패해 실전 모드로 전환하지 못했습니다.';
    }
    config.live = live;
    await _rebuildEngine();
    notifyListeners();
    return null;
  }

  Future<void> resetDemo() async {
    _paper?.reset(config.demoStartBalance);
    await storage.savePaperBalance(config.demoStartBalance);
    engine.position = null;
    await engine.refresh();
  }

  Future<void> clearHistory() async {
    await history.clear();
    notifyListeners();
  }

  /// 대시보드용 총 평가금 (데모: 증거금 포함 잔고 + 미실현 손익).
  double get equity {
    final p = engine.position;
    final price = engine.ticker?.mid;
    final unreal = (p != null && price != null) ? p.unrealizedPnl(price) : 0.0;
    final base = _paper != null && !config.live ? _paper!.equity : engine.balance + (p?.margin ?? 0);
    return base + unreal;
  }

  String money(double usdt, {bool signed = false}) =>
      currency.format(usdt, config.displayCurrency, signed: signed);

  @override
  void dispose() {
    _refreshTimer?.cancel();
    engine.dispose();
    super.dispose();
  }
}
