import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'services/foreground.dart';
import 'ui/chart_screen.dart';
import 'ui/dashboard_screen.dart';
import 'ui/history_screen.dart';
import 'ui/settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ForegroundService.init();
  runApp(const GlobalFuturesTerminal());
}

class GlobalFuturesTerminal extends StatefulWidget {
  const GlobalFuturesTerminal({super.key});

  @override
  State<GlobalFuturesTerminal> createState() => _GlobalFuturesTerminalState();
}

class _GlobalFuturesTerminalState extends State<GlobalFuturesTerminal> {
  final app = AppState();

  @override
  void initState() {
    super.initState();
    app.init();
  }

  @override
  void dispose() {
    app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '글로벌 선물 터미널',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFF0B90B),
        useMaterial3: true,
      ),
      theme: ThemeData(colorSchemeSeed: const Color(0xFFF0B90B), useMaterial3: true),
      home: WithForegroundTask(
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) => app.loaded
              ? HomeShell(app: app)
              : const Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
      ),
    );
  }
}

/// 하단 4개 메뉴: 대시보드 / 차트 / 거래 내역 / 설정.
class HomeShell extends StatefulWidget {
  final AppState app;
  const HomeShell({super.key, required this.app});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    if (widget.app.resumedAfterKill) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _warnResumed());
    }
  }

  Future<void> _warnResumed() async {
    widget.app.resumedAfterKill = false;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('자동매매가 중단되었습니다'),
        content: const Text('앱이나 폰이 재시작되기 전에 켜져 있던 자동매매가 중간에 꺼진 것으로 보입니다. '
            '거래소 앱에서 직접 확인하시거나, 자동매매를 다시 시작해 이어서 관리하세요.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('확인'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pages = [
      DashboardScreen(app: app),
      ChartScreen(app: app),
      HistoryScreen(app: app),
      SettingsScreen(app: app),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: app.running,
              backgroundColor: Colors.green,
              smallSize: 8,
              child: const Icon(Icons.dashboard_outlined),
            ),
            selectedIcon: const Icon(Icons.dashboard),
            label: '대시보드',
          ),
          const NavigationDestination(
              icon: Icon(Icons.candlestick_chart_outlined),
              selectedIcon: Icon(Icons.candlestick_chart),
              label: '차트'),
          const NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: '거래 내역'),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '설정'),
        ],
      ),
    );
  }
}
