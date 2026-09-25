import 'package:http/http.dart' as http;

/// 텔레그램 봇 알림 (선택). 토큰/채팅 ID 가 비어 있으면 아무것도 하지 않는다.
class TelegramNotifier {
  String token;
  String chatId;
  TelegramNotifier(this.token, this.chatId);

  bool get enabled => token.isNotEmpty && chatId.isNotEmpty;

  Future<void> send(String text) async {
    if (!enabled) return;
    try {
      await http.post(
        Uri.parse('https://api.telegram.org/bot$token/sendMessage'),
        body: {'chat_id': chatId, 'text': text},
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      // 알림 실패는 매매에 영향을 주지 않는다.
    }
  }
}
