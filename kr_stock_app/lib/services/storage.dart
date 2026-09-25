// 저장소: API 키·토큰은 보안 저장소(Android Keystore), 설정·기록은 SharedPreferences.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../brokers/broker.dart';

class SecureStore implements KeyValueStore {
  final FlutterSecureStorage _s = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
}

class PrefsStore implements KeyValueStore {
  final SharedPreferences prefs;
  PrefsStore(this.prefs);
  @override
  Future<String?> read(String key) async => prefs.getString(key);
  @override
  Future<void> write(String key, String value) => prefs.setString(key, value);
}

/// 증권사별 입력 항목 (키 이름, 화면 표시 이름, 비밀 여부)
const brokerFields = <String, List<(String, String, bool)>>{
  'kis': [('kis_app_key', 'App Key', true), ('kis_app_secret', 'App Secret', true), ('kis_account', '계좌번호 (12345678-01)', false)],
  'kiwoom': [('kiwoom_app_key', 'App Key', true), ('kiwoom_secret_key', 'Secret Key', true)],
  'ls': [('ls_app_key', 'App Key', true), ('ls_app_secret', 'App Secret', true)],
  'db': [('db_app_key', 'App Key', true), ('db_app_secret', 'App Secret', true)],
  'nh': [('nh_app_key', 'App Key', true), ('nh_app_secret', 'App Secret', true), ('nh_account', '계좌번호 (비우면 자동)', false)],
};

const brokerNames = {
  'paper': '모의매매 (가상 시세)',
  'kis': '한국투자증권',
  'kiwoom': '키움증권',
  'ls': 'LS증권',
  'db': 'DB증권',
  'nh': 'NH투자증권',
};

const brokerDemoNotes = {
  'kis': '모의투자는 별도 서버로 자동 연결됩니다 (모의투자 신청 필요).',
  'kiwoom': '모의투자는 별도 서버로 자동 연결됩니다.',
  'ls': '실전·모의 주소가 같습니다. 모의투자는 모의투자용 App Key 를 넣으세요.',
  'db': '실전·모의 주소가 같습니다. 모의투자는 모의투자용 App Key 를 넣으세요.',
  'nh': '모의투자는 moapi 서버와 계좌구분 03 계좌를 자동으로 사용합니다.',
};
