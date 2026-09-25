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
  FlutterForegroundTask.initCommunicationPort();
  ForegroundService.init();
  final controller = AppController();
  runApp(KrStockApp(controller: controller));
  controller.load().then((_) => controller.refreshBalance());
}

class KrStockApp extends StatelessWidget {
  final AppController controller;
  const KrStockApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '국내주식 자동매매',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B82F6), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0E1117),
        cardTheme: const CardThemeData(color: Color(0xFF161B22), margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
        useMaterial3: true,
      ),
      home: WithForegroundTask(child: HomeScreen(controller: controller)),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final AppController controller;
  const HomeScreen({super.key, required this.controller});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final pages = [
          DashboardScreen(controller: c),
          ChartScreen(controller: c),
          HistoryScreen(controller: c),
          SettingsScreen(controller: c),
        ];
        return Scaffold(
          body: SafeArea(child: IndexedStack(index: _tab, children: pages)),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: '대시보드'),
              NavigationDestination(icon: Icon(Icons.candlestick_chart_outlined), label: '차트'),
              NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: '기록'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), label: '설정'),
            ],
          ),
        );
      },
    );
  }
}
