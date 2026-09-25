import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/models.dart';

/// 설정은 SharedPreferences, API 키는 보안 저장소(Android Keystore)에 저장한다.
class Storage {
  static const _cfgKey = 'trading_config_v1';
  static const _paperKey = 'paper_balance_v1';
  static const _activeKey = 'auto_trading_active_v1';
  static const _secure = FlutterSecureStorage();

  Future<TradingConfig> loadConfig() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cfgKey);
    if (raw == null) return TradingConfig();
    try {
      return TradingConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return TradingConfig();
    }
  }

  Future<void> saveConfig(TradingConfig c) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_cfgKey, jsonEncode(c.toJson()));
  }

  Future<ApiCredentials> loadCredentials(ExchangeId ex) async {
    final raw = await _secure.read(key: 'creds_${ex.name}');
    if (raw == null) return const ApiCredentials();
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return ApiCredentials(
      apiKey: j['k'] as String? ?? '',
      apiSecret: j['s'] as String? ?? '',
      passphrase: j['p'] as String? ?? '',
    );
  }

  Future<void> saveCredentials(ExchangeId ex, ApiCredentials c) => _secure.write(
      key: 'creds_${ex.name}',
      value: jsonEncode({'k': c.apiKey, 's': c.apiSecret, 'p': c.passphrase}));

  Future<double?> loadPaperBalance() async =>
      (await SharedPreferences.getInstance()).getDouble(_paperKey);

  Future<void> savePaperBalance(double v) async =>
      (await SharedPreferences.getInstance()).setDouble(_paperKey, v);

  /// 자동매매가 켜져 있었는지 기록 — 앱이 강제 종료된 뒤 재시작했을 때 경고하기 위해.
  Future<bool> wasActive() async =>
      (await SharedPreferences.getInstance()).getBool(_activeKey) ?? false;

  Future<void> setActive(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_activeKey, v);
}
