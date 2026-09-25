// 화면이 꺼져도 자동매매가 멈추지 않도록 포그라운드 서비스(상단 알림)를 유지한다.
// 매매 로직은 앱 메인 isolate 의 타이머에서 돌고, 서비스는 프로세스를 살려 두는 역할만 한다.
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void keepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class ForegroundService {
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'auto_trading',
        channelName: '자동매매 실행 중',
        channelDescription: '자동매매가 켜져 있는 동안 표시됩니다',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start(String text) async {
    try {
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationTitle: '자동매매 실행 중', notificationText: text);
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 300,
          serviceTypes: [ForegroundServiceTypes.specialUse],
          notificationTitle: '자동매매 실행 중',
          notificationText: text,
          callback: keepAliveCallback,
        );
      }
    } catch (_) {
      // 서비스 시작 실패해도 앱이 켜져 있는 동안은 매매가 계속된다
    }
  }

  static Future<void> update(String text) async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationText: text);
      }
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
