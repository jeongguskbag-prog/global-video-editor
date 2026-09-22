import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'trading_engine.dart';

const String kSupportEmail = "pjk6322@gmail.com";

// 다중 코인 감시(자동매매)에서 스캔할 후보 Top 5. 수동 매매(상단 코인 표시)는
// BTCUSDT 고정이며 이 목록의 영향을 받지 않는다.
const List<String> kAvailableSymbols = [
  'BTCUSDT',
  'ETHUSDT',
  'BNBUSDT',
  'SOLUSDT',
  'XRPUSDT',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProductionEnterpriseApp());
}

// ==========================================
// 1. API 원가 방어 & 크레딧 차감 엔진 (마진 50% 고정)
// ==========================================
class CreditCostEngine {
  // 1 크레딧 = 0.01 USDT
  // 고화질 AI 분석/초고속 렌더링 원가: 5 크레딧 (0.05 USDT)
  static const int kApiCostCredits = 5;
  static const double kCostFloorMarginRatio = 0.50;

  // 원가 / (1 - 마진율) 로 계산 -> 마진율 50% 유지 (5 / 0.5 = 10 크레딧)
  static final int kProActionCreditCost =
      (kApiCostCredits / (1 - kCostFloorMarginRatio)).round();

  static bool deductCredit({
    required int currentCredits,
    required Function(int newCredits) onSuccess,
    required Function(String error) onFailure,
  }) {
    if (currentCredits < kProActionCreditCost) {
      onFailure("크레딧이 부족합니다. (필요: $kProActionCreditCost 크레딧)");
      return false;
    }
    onSuccess(currentCredits - kProActionCreditCost);
    return true;
  }
}

// ==========================================
// 2. 라이선스 무결성 & 안티 탬퍼링(변조 방지) 모듈
//
// 주의: 이 클래스는 로컬 기기에만 저장된 서명을 자기 자신과 비교하는
// "trust-on-first-use" 방식이라, 실제 서버 발급/검증 없이는 크랙 방어
// 효과가 없다. 프로덕션 배포 전 아래 항목을 반드시 백엔드로 옮길 것:
//   - 유효 라이선스 키 목록 및 발급/해지
//   - salt 값 (현재 클라이언트 바이너리에 그대로 노출됨)
//   - 서명 검증 로직 자체
// ==========================================
class AntiTamperLicenseVault {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    wOptions: WindowsOptions(),
  );

  static String generateDeviceFingerprint(String licenseKey, String deviceId) {
    const salt = "SECURE_TOP5_ENTERPRISE_KEY_SALT_2026";
    final payload = "$licenseKey:$deviceId:$salt";
    return sha256.convert(utf8.encode(payload)).toString();
  }

  static Future<bool> verifyLicenseIntegrity({
    required String licenseKey,
    required String deviceId,
  }) async {
    if (licenseKey.isEmpty || licenseKey.length < 16) return false;
    final expectedSignature = generateDeviceFingerprint(licenseKey, deviceId);

    final storedSig = await _storage.read(key: "hw_license_signature");
    if (storedSig == null) {
      await _storage.write(key: "hw_license_signature", value: expectedSignature);
      return true;
    }
    return storedSig == expectedSignature;
  }

  static Future<void> saveLicense(String licenseKey, String deviceId) async {
    final sig = generateDeviceFingerprint(licenseKey, deviceId);
    await _storage.write(key: "license_key", value: licenseKey);
    await _storage.write(key: "hw_license_signature", value: sig);
  }
}

// ==========================================
// 3. 글로벌 선물 거래소 규격 + 거래소별 실시간 시세 연동
// ==========================================
enum Exchange { binance, bybit, bitget, okx, gateio }

extension ExchangeExt on Exchange {
  String get displayName {
    switch (this) {
      case Exchange.binance: return '바이낸스 (Binance)';
      case Exchange.bybit:   return '바이비트 (Bybit)';
      case Exchange.bitget:  return '비트겟 (Bitget)';
      case Exchange.okx:     return 'OKX';
      case Exchange.gateio:  return '게이트아이오 (Gate.io)';
    }
  }
}

/// 거래소별 웹소켓 접속 정보(엔드포인트, 구독 메시지, 파서)를 한 곳에 모아
/// _connectWebSocket()이 어느 거래소를 고르든 실제로 그 거래소의 실시간
/// 데이터를 받도록 한다. (기존 코드는 거래소를 바꿔도 항상 바이낸스에만
/// 연결되는 버그가 있었음)
class _ExchangeWsConfig {
  final Uri uri;
  final String? subscribeMessage;
  // 메시지를 받아 {'last','high','low','changePercent'} 중 갱신된 값만 반환.
  // 파싱 실패/무관한 메시지는 null 반환.
  final Map<String, double>? Function(dynamic rawMessage) parser;

  _ExchangeWsConfig({required this.uri, this.subscribeMessage, required this.parser});
}

double? _num(dynamic v) => v == null ? null : double.tryParse(v.toString());

_ExchangeWsConfig _wsConfigFor(Exchange ex, String symbol) {
  final base = symbol.substring(0, symbol.length - 4); // "BTCUSDT" -> "BTC"
  switch (ex) {
    case Exchange.binance:
      return _ExchangeWsConfig(
        uri: Uri.parse('wss://fstream.binance.com/ws/${symbol.toLowerCase()}@ticker'),
        parser: (raw) {
          try {
            final data = jsonDecode(raw);
            final updates = <String, double>{};
            final c = _num(data['c']);
            final h = _num(data['h']);
            final l = _num(data['l']);
            final p = _num(data['P']);
            if (c != null) updates['last'] = c;
            if (h != null) updates['high'] = h;
            if (l != null) updates['low'] = l;
            if (p != null) updates['changePercent'] = p;
            return updates.isEmpty ? null : updates;
          } catch (_) {
            return null;
          }
        },
      );

    case Exchange.bybit:
      return _ExchangeWsConfig(
        uri: Uri.parse('wss://stream.bybit.com/v5/public/linear'),
        subscribeMessage: jsonEncode({
          "op": "subscribe",
          "args": ["tickers.$symbol"],
        }),
        parser: (raw) {
          try {
            final msg = jsonDecode(raw);
            final data = msg['data'];
            if (data == null) return null;
            final updates = <String, double>{};
            final last = _num(data['lastPrice']);
            final high = _num(data['highPrice24h']);
            final low = _num(data['lowPrice24h']);
            final pct = _num(data['price24hPcnt']); // fraction, e.g. 0.0245
            if (last != null) updates['last'] = last;
            if (high != null) updates['high'] = high;
            if (low != null) updates['low'] = low;
            if (pct != null) updates['changePercent'] = pct * 100;
            return updates.isEmpty ? null : updates;
          } catch (_) {
            return null;
          }
        },
      );

    case Exchange.bitget:
      return _ExchangeWsConfig(
        uri: Uri.parse('wss://ws.bitget.com/v2/ws/public'),
        subscribeMessage: jsonEncode({
          "op": "subscribe",
          "args": [
            {"instType": "USDT-FUTURES", "channel": "ticker", "instId": symbol}
          ],
        }),
        parser: (raw) {
          try {
            final msg = jsonDecode(raw);
            final list = msg['data'];
            if (list == null || list is! List || list.isEmpty) return null;
            final d = list[0];
            final updates = <String, double>{};
            final last = _num(d['lastPr']);
            final high = _num(d['high24h']);
            final low = _num(d['low24h']);
            final chg = _num(d['change24h']); // fraction
            if (last != null) updates['last'] = last;
            if (high != null) updates['high'] = high;
            if (low != null) updates['low'] = low;
            if (chg != null) updates['changePercent'] = chg * 100;
            return updates.isEmpty ? null : updates;
          } catch (_) {
            return null;
          }
        },
      );

    case Exchange.okx:
      final instId = '$base-USDT-SWAP';
      return _ExchangeWsConfig(
        uri: Uri.parse('wss://ws.okx.com:8443/ws/v5/public'),
        subscribeMessage: jsonEncode({
          "op": "subscribe",
          "args": [
            {"channel": "tickers", "instId": instId}
          ],
        }),
        parser: (raw) {
          try {
            final msg = jsonDecode(raw);
            final list = msg['data'];
            if (list == null || list is! List || list.isEmpty) return null;
            final d = list[0];
            final updates = <String, double>{};
            final last = _num(d['last']);
            final high = _num(d['high24h']);
            final low = _num(d['low24h']);
            final open = _num(d['open24h']);
            if (last != null) updates['last'] = last;
            if (high != null) updates['high'] = high;
            if (low != null) updates['low'] = low;
            if (last != null && open != null && open != 0) {
              updates['changePercent'] = (last - open) / open * 100;
            }
            return updates.isEmpty ? null : updates;
          } catch (_) {
            return null;
          }
        },
      );

    case Exchange.gateio:
      final contract = '${base}_USDT';
      return _ExchangeWsConfig(
        uri: Uri.parse('wss://fx-ws.gateio.ws/v4/ws/usdt'),
        subscribeMessage: jsonEncode({
          "time": DateTime.now().millisecondsSinceEpoch ~/ 1000,
          "channel": "futures.tickers",
          "event": "subscribe",
          "payload": [contract],
        }),
        parser: (raw) {
          try {
            final msg = jsonDecode(raw);
            final result = msg['result'];
            if (result == null || result is! List || result.isEmpty) return null;
            final d = result[0];
            final updates = <String, double>{};
            final last = _num(d['last']);
            final high = _num(d['high_24h']);
            final low = _num(d['low_24h']);
            final pct = _num(d['change_percentage']); // already in percent
            if (last != null) updates['last'] = last;
            if (high != null) updates['high'] = high;
            if (low != null) updates['low'] = low;
            if (pct != null) updates['changePercent'] = pct;
            return updates.isEmpty ? null : updates;
          } catch (_) {
            return null;
          }
        },
      );
  }
}

// ==========================================
// 4. 앱 루트 & 35개국 로케일 등록
// ==========================================
class ProductionEnterpriseApp extends StatelessWidget {
  const ProductionEnterpriseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Global High-Speed Futures Terminal',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121418),
        cardColor: const Color(0xFF1E222D),
      ),
      supportedLocales: const [
        Locale('ko'), Locale('en'), Locale('ja'), Locale('zh'),
        Locale('es'), Locale('fr'), Locale('de'), Locale('ru'),
        Locale('vi'), Locale('th'), Locale('id'), Locale('hi'),
        Locale('pt'), Locale('it'), Locale('tr'), Locale('pl'),
        Locale('uk'), Locale('ar'), Locale('fa'), Locale('nl'),
        Locale('sv'), Locale('el'), Locale('cs'), Locale('ro'),
        Locale('hu'), Locale('ms'), Locale('fil'), Locale('bn'),
        Locale('pa'), Locale('ur'), Locale('kk'), Locale('he'),
        Locale('da'), Locale('fi'), Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const MainEnterpriseScreen(),
    );
  }
}

// ==========================================
// 5. 메인 엔터프라이즈 트레이딩 화면
// ==========================================
class MainEnterpriseScreen extends StatefulWidget {
  const MainEnterpriseScreen({super.key});

  @override
  State<MainEnterpriseScreen> createState() => _MainEnterpriseScreenState();
}

class _MainEnterpriseScreenState extends State<MainEnterpriseScreen> {
  Exchange _selectedExchange = Exchange.binance;
  final String _symbol = "BTCUSDT";

  // 보안 & 크레딧 & 프로모션 상태
  final String _deviceId = "SYS-NODE-HW8821"; // 실제 환경에선 device_info_plus 등으로 추출
  int _userCredits = 100; // 초기 론칭 기념 무료 크레딧 100 지급 (CAC 0원 마케팅)
  bool _isLicenseVerified = false;
  Duration _promoTimeLeft = const Duration(hours: 47, minutes: 59, seconds: 50);
  Timer? _promoTimer;

  // 시세 및 매매 파라미터
  double _lastPrice = 64250.0;
  double _high24h = 65120.0;
  double _low24h = 63800.0;
  double _changePercent = 2.45;
  double _leverage = 20.0;
  int _selectedPercent = 25;
  bool _isLong = true;

  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _qtyController = TextEditingController();

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;

  // 자동매매(데모/페이퍼트레이딩) 상태. 실제 거래소 주문은 보내지 않고
  // 가상 잔고로 시뮬레이션만 한다 — _executeSecureOrder()와 마찬가지로
  // 이 프로토타입에는 인증된 거래소 주문 API 연동이 없기 때문.
  bool _autoTradeRunning = false;
  // 켜면 코인 하나(_symbol) 대신 kAvailableSymbols(5개) 전부를 매 틱마다
  // 스캔해서, 포지션이 없을 때 신호가 뜬 코인에 진입한다. 포지션이 열리면
  // 청산될 때까지 그 코인만 관리한다(한 번에 포지션 하나). 수동 매매
  // (상단 코인 표시, 주문 폼)에는 영향 없음.
  bool _multiSymbolScan = false;
  AutoTradeEngine? _autoEngine;
  AutoTradeStatus? _autoStatus;

  @override
  void initState() {
    super.initState();
    _priceController.text = _lastPrice.toStringAsFixed(1);
    _recalculateQty();
    _connectWebSocket();
    _startPromoCountdown();
    _verifyInitialLicense();
  }

  void _startPromoCountdown() {
    _promoTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_promoTimeLeft.inSeconds > 0) {
        setState(() => _promoTimeLeft -= const Duration(seconds: 1));
      } else {
        _promoTimer?.cancel();
      }
    });
  }

  Future<void> _verifyInitialLicense() async {
    final ok = await AntiTamperLicenseVault.verifyLicenseIntegrity(
      licenseKey: "VALID_PRO_KEY_882910394857",
      deviceId: _deviceId,
    );
    if (!mounted) return; // 위젯이 dispose된 뒤 setState 호출되는 것을 방지
    setState(() => _isLicenseVerified = ok);
  }

  void _connectWebSocket() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();

    final config = _wsConfigFor(_selectedExchange, _symbol);
    try {
      _channel = WebSocketChannel.connect(config.uri);
      if (config.subscribeMessage != null) {
        _channel!.sink.add(config.subscribeMessage);
      }
      _channel!.stream.listen(
        (message) {
          if (!mounted) return;
          final updates = config.parser(message);
          if (updates == null || updates.isEmpty) return;
          setState(() {
            if (updates.containsKey('last')) _lastPrice = updates['last']!;
            if (updates.containsKey('high')) _high24h = updates['high']!;
            if (updates.containsKey('low')) _low24h = updates['low']!;
            if (updates.containsKey('changePercent')) {
              _changePercent = updates['changePercent']!;
            }
          });
        },
        onError: (_) => _scheduleReconnect(),
        onDone: () => _scheduleReconnect(),
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _connectWebSocket();
    });
  }

  void _recalculateQty() {
    final price = double.tryParse(_priceController.text) ?? _lastPrice;
    if (price <= 0) return;
    const baseCapital = 5000.0;
    final margin = baseCapital * (_selectedPercent / 100);
    final notional = margin * _leverage;
    _qtyController.text = (notional / price).toStringAsFixed(3);
  }

  double _getLiquidationPrice() {
    final p = double.tryParse(_priceController.text) ?? _lastPrice;
    if (p <= 0 || _leverage <= 0) return 0.0;
    return _isLong
        ? p * (1 - (1 / _leverage) + 0.005)
        : p * (1 + (1 / _leverage) - 0.005);
  }

  // 주문 전송 시: 크레딧 마진 방어 + 라이선스 무결성 동시 검증
  void _executeSecureOrder() {
    if (!_isLicenseVerified) {
      _showSecurityAlert("소프트웨어 무결성 검증에 실패했습니다. 변조된 실행 파일에서는 주문이 차단됩니다.");
      return;
    }

    CreditCostEngine.deductCredit(
      currentCredits: _userCredits,
      onSuccess: (updated) {
        setState(() => _userCredits = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '⚡ [${_selectedExchange.name.toUpperCase()}] 주문 체결 완료 '
              '(${CreditCostEngine.kProActionCreditCost} 크레딧 차감, 잔여: $_userCredits)',
            ),
            backgroundColor: const Color(0xFF00C087),
          ),
        );
      },
      onFailure: (err) {
        _showCreditPaywall(err);
      },
    );
  }

  void _showCreditPaywall(String message) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.bolt, color: Colors.amber, size: 24),
                SizedBox(width: 8),
                Text('API 연산 크레딧 충전 (마진 50% 보호)', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            Text(message, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFF262932), borderRadius: BorderRadius.circular(8)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('500 크레딧 패키지: 5 USDT', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C087)),
                    onPressed: () => _startCreditPurchase(ctx, credits: 500, priceUsdt: 5),
                    child: const Text('충전하기'),
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 실제 결제 게이트웨이(IAP 등) 연동 전까지는 크레딧을 임의로 지급하지 않는다.
  // TODO: 인앱결제/USDT 결제 콜백에서 서버가 결제를 검증한 뒤에만 크레딧을 지급하도록 교체.
  void _startCreditPurchase(BuildContext sheetCtx, {required int credits, required num priceUsdt}) {
    Navigator.pop(sheetCtx);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('결제 연동 준비 중입니다. 문의: $kSupportEmail')),
    );
  }

  void _toggleAutoTrade() {
    if (_autoTradeRunning) {
      _autoEngine?.stop();
      _autoEngine = null;
      setState(() => _autoTradeRunning = false);
      return;
    }

    final symbols = _multiSymbolScan ? kAvailableSymbols : [_symbol];
    const capitalUsdt = 5000.0;
    final marginPerTrade = capitalUsdt * (_selectedPercent / 100);

    final engine = AutoTradeEngine(
      symbols: symbols,
      leverage: _leverage,
      marginPerTradeUsdt: marginPerTrade,
      stopLossPercent: 3,
      takeProfitPercent: 6,
      demoBalance: capitalUsdt,
      onUpdate: (status) {
        if (!mounted) return;
        setState(() => _autoStatus = status);
      },
    );
    _autoEngine = engine;
    engine.start();
    setState(() {
      _autoTradeRunning = true;
      _autoStatus = null;
    });
  }

  void _showSecurityAlert(String msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222D),
        title: const Text('보안 위반 경고', style: TextStyle(color: Color(0xFFF84960))),
        content: Text(msg, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인', style: TextStyle(color: Colors.amber))),
        ],
      ),
    );
  }

  void _showExchangeListSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('선물 거래소 선택 (Top 5)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  IconButton(icon: const Icon(Icons.close, color: Colors.white54), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
            ),
            ...Exchange.values.map((ex) {
              final isSel = ex == _selectedExchange;
              return ListTile(
                leading: Icon(
                  isSel ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: isSel ? const Color(0xFF00C087) : Colors.white30,
                ),
                title: Text(ex.displayName, style: TextStyle(color: isSel ? Colors.white : Colors.white70, fontWeight: isSel ? FontWeight.bold : FontWeight.normal)),
                onTap: () {
                  setState(() => _selectedExchange = ex);
                  Navigator.pop(ctx);
                  _connectWebSocket();
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _promoTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _autoEngine?.stop();
    _priceController.dispose();
    _qtyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const buyColor = Color(0xFF00C087);
    const sellColor = Color(0xFFF84960);
    final isUp = _changePercent >= 0;

    final hours = _promoTimeLeft.inHours.toString().padLeft(2, '0');
    final minutes = (_promoTimeLeft.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (_promoTimeLeft.inSeconds % 60).toString().padLeft(2, '0');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF181A20),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.currency_bitcoin, color: Colors.amber, size: 20),
            const SizedBox(width: 8),
            Text('$_symbol [엔터프라이즈]', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
              child: Text('${_leverage.toInt()}X', style: const TextStyle(color: Colors.amber, fontSize: 11)),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: InkWell(
              onTap: _showExchangeListSheet,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: const Color(0xFF262932), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
                child: Row(
                  children: [
                    const Icon(Icons.account_balance, size: 14, color: Colors.amber),
                    const SizedBox(width: 6),
                    Text(_selectedExchange.displayName.split(' ')[0], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(width: 4),
                    const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.white70),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          children: [
            // 론칭 프로모션 선점 배너 (초기 마케팅 CAC 0원 달성용)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF8A2387), Color(0xFFE94057)]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Text("론칭 기념 무료 트래픽 선점: $hours:$minutes:$seconds", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(4)),
                    child: Text("잔여: $_userCredits 크레딧", style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // 실시간 시세 카드
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFF1E222D), borderRadius: BorderRadius.circular(10)),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_lastPrice.toStringAsFixed(1), style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: isUp ? buyColor : sellColor)),
                          Text('${isUp ? "+" : ""}${_changePercent.toStringAsFixed(2)}% (실시간 초고속)', style: TextStyle(color: isUp ? buyColor : sellColor, fontSize: 12)),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('24h 고가: ${_high24h.toStringAsFixed(1)}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                          Text('24h 저가: ${_low24h.toStringAsFixed(1)}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildChip('최저가 진입', _low24h.toStringAsFixed(1), () {
                        _priceController.text = _low24h.toStringAsFixed(1);
                        _recalculateQty();
                      }),
                      _buildChip('현재가 채우기', _lastPrice.toStringAsFixed(1), () {
                        _priceController.text = _lastPrice.toStringAsFixed(1);
                        _recalculateQty();
                      }),
                      _buildChip('최고가 저항', _high24h.toStringAsFixed(1), () {
                        _priceController.text = _high24h.toStringAsFixed(1);
                        _recalculateQty();
                      }),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 포지션 선택 버튼
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: _isLong ? buyColor : const Color(0xFF262932)),
                    onPressed: () => setState(() => _isLong = true),
                    child: const Text('LONG (매수)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: !_isLong ? sellColor : const Color(0xFF262932)),
                    onPressed: () => setState(() => _isLong = false),
                    child: const Text('SHORT (매도)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 레버리지 슬라이더
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('레버리지 배율', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Text('${_leverage.toInt()}X', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
              ],
            ),
            Slider(
              value: _leverage,
              min: 1,
              max: 100,
              divisions: 99,
              activeColor: Colors.amber,
              onChanged: (v) {
                setState(() {
                  _leverage = v;
                  _recalculateQty();
                });
              },
            ),

            TextField(
              controller: _priceController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: '주문 가격 (USDT)', filled: true, fillColor: Color(0xFF1E222D)),
              onChanged: (_) => _recalculateQty(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _qtyController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: '주문 수량 (BTC)', filled: true, fillColor: Color(0xFF1E222D)),
            ),
            const SizedBox(height: 8),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [25, 50, 75, 100].map((p) {
                final isSel = _selectedPercent == p;
                return OutlinedButton(
                  style: OutlinedButton.styleFrom(side: BorderSide(color: isSel ? Colors.amber : Colors.white24)),
                  onPressed: () {
                    setState(() {
                      _selectedPercent = p;
                      _recalculateQty();
                    });
                  },
                  child: Text('$p%', style: TextStyle(color: isSel ? Colors.amber : Colors.white60)),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFF262932), borderRadius: BorderRadius.circular(6)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('예상 강제청산가', style: TextStyle(color: Colors.white60, fontSize: 12)),
                  Text('${_getLiquidationPrice().toStringAsFixed(1)} USDT', style: TextStyle(color: sellColor, fontWeight: FontWeight.bold, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 주문 전송 버튼 (API 비용 방어 + 라이선스 무결성 검증 체인 작동)
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _isLong ? buyColor : sellColor),
                onPressed: _executeSecureOrder,
                child: Text(
                  '[${_selectedExchange.name.toUpperCase()}] ${_isLong ? "롱 오픈" : "숏 오픈"} (${CreditCostEngine.kProActionCreditCost} 크레딧)',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 14),

            _buildAutoTradeCard(buyColor, sellColor),
            const SizedBox(height: 14),

            // 프로그램 문의 및 고객센터 배너
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: const Color(0xFF1E222D), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.mail_outline, color: Colors.amber, size: 16),
                      SizedBox(width: 8),
                      Text('프로그램 문의: $kSupportEmail', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, color: Colors.white38, size: 16),
                    onPressed: () {
                      Clipboard.setData(const ClipboardData(text: kSupportEmail));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('문의 메일($kSupportEmail)이 복사되었습니다.')));
                    },
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _positionLabel(StrategyPosition p) {
    switch (p) {
      case StrategyPosition.long:
        return '롱';
      case StrategyPosition.short:
        return '숏';
      case StrategyPosition.none:
        return '없음';
    }
  }

  Widget _buildAutoTradeCard(Color buyColor, Color sellColor) {
    final status = _autoStatus;
    final watching = _multiSymbolScan
        ? kAvailableSymbols.map((s) => s.replaceAll('USDT', '')).join(' / ')
        : _symbol.replaceAll('USDT', '');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.smart_toy_outlined, color: Colors.amber, size: 18),
              SizedBox(width: 8),
              Text('자동매매 (데모/페이퍼트레이딩)',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '실제 거래소에 주문을 보내지 않고 실시간 시세로 가상 잔고를 시뮬레이션합니다. '
            '전략: 5/20 이동평균 크로스, 손절 -3% / 익절 +6%.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text('다중 코인 감시', style: TextStyle(color: Colors.white70, fontSize: 13)),
              ),
              Switch(
                value: _multiSymbolScan,
                activeThumbColor: Colors.amber,
                onChanged: _autoTradeRunning
                    ? null
                    : (v) => setState(() => _multiSymbolScan = v),
              ),
            ],
          ),
          Text(
            _multiSymbolScan
                ? '포지션이 없을 때 5개 코인(BTC/ETH/BNB/SOL/XRP)을 모두 스캔해서 신호가 뜬 코인에 진입합니다. 진입 후에는 청산될 때까지 그 코인만 관리합니다.'
                : '$_symbol 한 코인만 감시합니다.',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _autoTradeRunning ? sellColor : buyColor,
              ),
              onPressed: _toggleAutoTrade,
              child: Text(
                _autoTradeRunning ? '자동매매 중지' : '자동매매 시작 (데모)',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ),
          if (_autoTradeRunning) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFF262932), borderRadius: BorderRadius.circular(6)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('감시 중: $watching', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 6),
                  if (status == null)
                    const Text('첫 신호 확인 중...', style: TextStyle(color: Colors.white38, fontSize: 12))
                  else if (status.event == AutoTradeEvent.error)
                    Text('오류: ${status.message}', style: TextStyle(color: sellColor, fontSize: 12))
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('${status.symbol} · 포지션: ${_positionLabel(status.position)}',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                            Text('현재가: ${status.price.toStringAsFixed(2)}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                        if (status.entryPrice != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('진입가: ${status.entryPrice!.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
                              if (status.unrealizedPnl != null)
                                Text(
                                  '평가손익: ${status.unrealizedPnl! >= 0 ? "+" : ""}${status.unrealizedPnl!.toStringAsFixed(2)} USDT',
                                  style: TextStyle(
                                      color: status.unrealizedPnl! >= 0 ? buyColor : sellColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold),
                                ),
                            ],
                          ),
                        ],
                        if (status.message != null) ...[
                          const SizedBox(height: 4),
                          Text(status.message!, style: const TextStyle(color: Colors.amber, fontSize: 11)),
                        ],
                        const SizedBox(height: 4),
                        Text('데모 잔고: ${status.demoBalance.toStringAsFixed(2)} USDT',
                            style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChip(String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFF262932), borderRadius: BorderRadius.circular(6)),
        child: Column(
          children: [
            Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
