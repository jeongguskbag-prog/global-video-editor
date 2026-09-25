// 앱 전체 상태: 설정·증권사 연결·자동매매 루프·기록.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'brokers/broker.dart';
import 'brokers/db.dart';
import 'brokers/kis.dart';
import 'brokers/kiwoom.dart';
import 'brokers/ls.dart';
import 'brokers/nh.dart';
import 'brokers/paper.dart';
import 'core/config.dart';
import 'core/engine.dart';
import 'core/history.dart';
import 'core/market.dart';
import 'core/strategies.dart';
import 'services/foreground.dart';
import 'services/storage.dart';
import 'services/telegram.dart';

class LogEntry {
  final DateTime time;
  final String text;
  LogEntry(this.time, this.text);
}

class AppController extends ChangeNotifier {
  late SharedPreferences _prefs;
  final SecureStore secure = SecureStore();
  AppConfig config = AppConfig();
  late TradeHistory history;
  final Map<String, String> secrets = {};
  Broker? _broker;
  AutoTradeEngine? engine;
  Timer? _timer;
  bool running = false;
  bool busy = false;
  bool ready = false;
  Balance? balance;
  String? lastError;
  DateTime? lastTick;
  final List<LogEntry> logs = [];

  static const secretKeys = [
    'kis_app_key', 'kis_app_secret', 'kis_account', 'kiwoom_app_key', 'kiwoom_secret_key', 'ls_app_key',
    'ls_app_secret', 'db_app_key', 'db_app_secret', 'nh_app_key', 'nh_app_secret', 'nh_account',
    'telegram_token', 'telegram_chat_id', 'paper_source',
  ];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    config = AppConfig.decode(_prefs.getString('config'));
    history = TradeHistory(TradeHistory.decode(_prefs.getString('history')), (r) {
      _prefs.setString('history', TradeHistory(r).encode());
    });
    for (final k in secretKeys) {
      secrets[k] = await secure.read(k) ?? '';
    }
    ready = true;
    notifyListeners();
  }

  void log(String text) {
    logs.insert(0, LogEntry(nowKst(), text));
    if (logs.length > 300) logs.removeLast();
    notifyListeners();
  }

  Future<void> saveConfig(AppConfig c) async {
    config = c;
    await _prefs.setString('config', c.encode());
    _broker = null;
    notifyListeners();
  }

  Future<void> saveSecret(String key, String value) async {
    secrets[key] = value.trim();
    await secure.write(key, value.trim());
    _broker = null;
  }

  String secret(String k) => secrets[k] ?? '';

  /// 설정에 맞는 증권사 클라이언트 (설정이 바뀌면 새로 만든다)
  Future<Broker> broker() async {
    if (_broker != null) return _broker!;
    _broker = await _build(config.broker);
    return _broker!;
  }

  Future<Broker> _build(String name) async {
    final live = config.live;
    switch (name) {
      case 'kis':
        return KisBroker(secret('kis_app_key'), secret('kis_app_secret'), secret('kis_account'), live: live, store: secure);
      case 'kiwoom':
        return KiwoomBroker(secret('kiwoom_app_key'), secret('kiwoom_secret_key'), live: live, store: secure);
      case 'ls':
        return LsBroker(secret('ls_app_key'), secret('ls_app_secret'), live: live, store: secure);
      case 'db':
        return DbBroker(secret('db_app_key'), secret('db_app_secret'), live: live, store: secure);
      case 'nh':
        return NhBroker(secret('nh_app_key'), secret('nh_app_secret'), account: secret('nh_account'), live: live, store: secure);
      default:
        final source = secret('paper_source');
        final paper = PaperBroker(
          cash: config.paperCash,
          feeRate: config.risk.feeRate,
          taxRate: config.risk.taxRate,
          dataSource: source.isNotEmpty && source != 'paper' ? await _build(source) : null,
          quoteInterval: config.interval,
          store: PrefsStore(_prefs),
        );
        await paper.load();
        return paper;
    }
  }

  bool get synthetic => config.broker == 'paper' && (secret('paper_source').isEmpty || secret('paper_source') == 'paper');

  Future<void> refreshBalance() async {
    try {
      final b = await broker();
      balance = await b.getBalance();
      lastError = null;
    } catch (e) {
      lastError = '$e';
    }
    notifyListeners();
  }

  Future<void> start() async {
    final problem = config.validate();
    if (problem != null) {
      lastError = problem;
      notifyListeners();
      return;
    }
    try {
      final b = await broker();
      final telegram = TelegramNotifier(secret('telegram_token'), secret('telegram_chat_id'));
      engine = AutoTradeEngine(
        cfg: config,
        broker: b,
        strategy: buildStrategy(config.strategy),
        history: history,
        respectMarketHours: !synthetic,
        notify: (m) {
          log(m);
          telegram.send(m);
        },
      );
      running = true;
      lastError = null;
      final label = '${brokerNames[config.broker]} · ${config.live ? '실전' : '모의'} · ${config.symbols.join(', ')}';
      log('자동매매 시작: $label (${strategyNames[config.strategy]}, ${config.interval})');
      telegram.send('자동매매 시작: $label');
      await ForegroundService.start(label);
      await _tick();
      _timer = Timer.periodic(Duration(seconds: config.pollSeconds), (_) => _tick());
    } catch (e) {
      running = false;
      lastError = '$e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    running = false;
    log('자동매매 중지');
    await ForegroundService.stop();
    notifyListeners();
  }

  Future<void> _tick() async {
    final e = engine;
    if (e == null || busy) return;
    busy = true;
    try {
      final b = await broker();
      if (synthetic && b is PaperBroker) {
        for (final s in config.symbols) {
          b.market.advance(s, config.interval);
        }
      }
      await e.tick();
      balance = await b.getBalance();
      lastTick = nowKst();
      lastError = null;
      final pnl = balance!.positions.fold(0.0, (a, p) => a + p.unrealizedPnl);
      await ForegroundService.update('보유 ${balance!.positions.length}종목 · 평가손익 ${formatWon(pnl)}');
    } catch (err) {
      lastError = '$err';
      log('오류: $err');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<OrderResult> manualOrder(String symbol, Side side, int qty, double? price) async {
    final b = await broker();
    final r = await b.placeOrder(symbol, side, qty, price == null ? OrderType.market : OrderType.limit, price ?? 0);
    final label = side == Side.buy ? '매수' : '매도';
    if (r.ok) {
      history.add(TradeRecord(
        time: nowKst(),
        symbol: symbol,
        side: side.name,
        qty: qty,
        price: r.price > 0 ? r.price : (price ?? 0),
        reason: '수동 주문',
        orderId: r.orderId,
        broker: '${b.name}/${b.live ? '실전' : '모의'}',
      ));
    }
    log(r.ok ? '✅ 수동 $label $symbol $qty주 (#${r.orderId})' : '❌ 수동 $label 실패: ${r.message}');
    await refreshBalance();
    return r;
  }

  Future<void> resetPaper() async {
    final b = await broker();
    if (b is PaperBroker) {
      await b.reset(config.paperCash);
      log('모의 계좌 초기화: ${formatWon(config.paperCash)}');
      await refreshBalance();
    }
  }

  void clearHistory() {
    history.clear();
    notifyListeners();
  }
}
