import 'package:local_auth/local_auth.dart';

/// 실전 모드 전환·API 키 열람 시 지문/PIN 본인 확인.
class AppLock {
  final _auth = LocalAuthentication();

  Future<bool> verify(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return true; // 잠금 수단이 없는 기기
      return await _auth.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}
