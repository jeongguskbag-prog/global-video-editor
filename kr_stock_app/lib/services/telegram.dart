import 'package:http/http.dart' as http;

class TelegramNotifier {
  final String token, chatId;
  final http.Client client;
  TelegramNotifier(this.token, this.chatId, {http.Client? client}) : client = client ?? http.Client();

  bool get enabled => token.isNotEmpty && chatId.isNotEmpty;

  Future<void> send(String text) async {
    if (!enabled) return;
    try {
      await client
          .post(Uri.parse('https://api.telegram.org/bot$token/sendMessage'), body: {'chat_id': chatId, 'text': text})
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // 알림 실패는 매매에 영향을 주지 않는다
    }
  }
}
