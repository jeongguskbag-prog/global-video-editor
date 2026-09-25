import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/config.dart';
import '../core/models.dart';
import '../services/currency.dart';
import 'common.dart';

/// 설정: 거래소·API 키 · 모드 · 코인/전략 · 리스크 관리 · 알림.
class SettingsScreen extends StatefulWidget {
  final AppState app;
  const SettingsScreen({super.key, required this.app});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TradingConfig _c;
  final _key = TextEditingController();
  final _secret = TextEditingController();
  final _pass = TextEditingController();
  bool _keysVisible = false;
  bool _keysDirty = false;
  final Map<String, TextEditingController> _num = {};

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    _c = widget.app.config.copy();
    _fillCreds(widget.app.creds);
    _keysDirty = false;
    String s(num? v) => v == null ? '' : '$v';
    final values = {
      'leverage': s(_c.leverage),
      'margin': s(_c.marginPerTrade),
      'sl': s(_c.stopLossPct),
      'tp': s(_c.takeProfitPct),
      'risk': s(_c.riskPerTradePct),
      'avg': s(_c.averageDownPct),
      'daily': s(_c.dailyLossLimitPct),
      'cdN': s(_c.cooldownLosses),
      'cdH': s(_c.cooldownHours),
      'spread': s(_c.maxSpreadPct),
      'poll': s(_c.pollSeconds),
      'demo': s(_c.demoStartBalance),
      'tgToken': _c.telegramToken,
      'tgChat': _c.telegramChatId,
    };
    values.forEach((k, v) => (_num[k] ??= TextEditingController()).text = v);
  }

  void _fillCreds(ApiCredentials c) {
    _key.text = c.apiKey;
    _secret.text = c.apiSecret;
    _pass.text = c.passphrase;
  }

  @override
  void dispose() {
    for (final c in [_key, _secret, _pass, ..._num.values]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _d(String k) => double.tryParse(_num[k]!.text.trim());

  Future<void> _save() async {
    final app = widget.app;
    if (app.running) {
      toast(context, '자동매매 실행 중에는 설정을 저장할 수 없습니다. 대시보드에서 중지하세요.');
      return;
    }
    final lev = int.tryParse(_num['leverage']!.text.trim());
    final margin = _d('margin');
    if (lev == null || margin == null) {
      toast(context, '올바른 숫자를 입력해 주세요.');
      return;
    }
    _c
      ..leverage = lev
      ..marginPerTrade = margin
      ..stopLossPct = _d('sl')
      ..takeProfitPct = _d('tp')
      ..riskPerTradePct = _d('risk')
      ..averageDownPct = _d('avg') ?? (_c.averageDownEnabled ? _c.defaultAverageDownPct : null)
      ..dailyLossLimitPct = _d('daily')
      ..cooldownLosses = int.tryParse(_num['cdN']!.text.trim()) ?? 0
      ..cooldownHours = _d('cdH') ?? 0
      ..maxSpreadPct = _d('spread')
      ..pollSeconds = int.tryParse(_num['poll']!.text.trim()) ?? 10
      ..demoStartBalance = _d('demo') ?? 1000
      ..telegramToken = _num['tgToken']!.text.trim()
      ..telegramChatId = _num['tgChat']!.text.trim()
      ..live = app.config.live;
    final creds = _keysDirty
        ? ApiCredentials(
            apiKey: _key.text.trim(), apiSecret: _secret.text.trim(), passphrase: _pass.text.trim())
        : null;
    final err = await app.saveConfig(_c.copy()..live = app.config.live, newCreds: creds);
    if (!mounted) return;
    if (err != null) {
      toast(context, err);
    } else {
      setState(_reset);
      toast(context, '저장했습니다');
    }
  }

  Future<void> _changeExchange(ExchangeId ex) async {
    setState(() => _c.exchange = ex);
    _fillCreds(await widget.app.credentialsFor(ex));
    _keysDirty = false;
    setState(() {});
  }

  Future<void> _toggleLive(bool live) async {
    final err = await widget.app.setLive(live);
    if (!mounted) return;
    if (err != null) toast(context, err);
    setState(() {});
  }

  Future<void> _revealKeys() async {
    if (!_keysVisible) {
      final ok = await widget.app.lock.verify('API 키를 보려면 본인 확인이 필요합니다.');
      if (!ok) return;
    }
    setState(() => _keysVisible = !_keysVisible);
  }

  Widget _field(String k, String label, {String? helper, bool number = true}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: TextField(
          controller: _num[k],
          enabled: !widget.app.running,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : null,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 4,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  Widget _secretField(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: TextField(
          controller: c,
          enabled: !widget.app.running,
          obscureText: !_keysVisible,
          onChanged: (_) => _keysDirty = true,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder(), isDense: true),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final locked = app.running;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (locked)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.all(10),
            color: Colors.orange.withValues(alpha: .15),
            child: const Text('수정하려면 자동매매를 먼저 중지하세요.',
                style: TextStyle(color: Colors.orange)),
          ),
        SectionCard(
          title: '모드',
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('데모 (모의투자)')),
              ButtonSegment(value: true, label: Text('실전 (실제 자금)')),
            ],
            selected: {app.config.live},
            onSelectionChanged: locked ? null : (v) => _toggleLive(v.first),
          ),
        ),
        SectionCard(
          title: '선물 거래소 선택 (Top 5)',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<ExchangeId>(
              initialValue: _c.exchange,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              items: [
                for (final e in ExchangeId.values) DropdownMenuItem(value: e, child: Text(e.label)),
              ],
              onChanged: locked ? null : (v) => v == null ? null : _changeExchange(v),
            ),
            const SizedBox(height: 8),
            Row(children: [
              const Expanded(child: Text('API 키', style: TextStyle(fontWeight: FontWeight.bold))),
              TextButton.icon(
                onPressed: _revealKeys,
                icon: Icon(_keysVisible ? Icons.visibility_off : Icons.fingerprint),
                label: Text(_keysVisible ? '숨기기' : '보기'),
              ),
            ]),
            _secretField(_key, 'API Key'),
            _secretField(_secret, 'API Secret'),
            if (_c.exchange.needsPassphrase) _secretField(_pass, 'API Passphrase'),
            const Text(
              'API 키는 기기의 보안 저장소(Android Keystore)에만 저장되고 외부로 전송되지 않습니다. '
              '출금 권한은 절대 켜지 마세요. 선물 계정은 단방향(One-way) 포지션 모드로 설정해 주세요.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ]),
        ),
        SectionCard(
          title: '코인 · 전략',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('코인 선택 (Top 5)'),
            Wrap(spacing: 6, children: [
              for (final k in kCoins)
                ChoiceChip(
                  label: Text(k),
                  selected: _c.coin == k,
                  onSelected: locked ? null : (_) => setState(() => _c.coin = k),
                ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('다중 코인 감시'),
              subtitle: const Text('포지션이 없을 때 5개 코인(BTC/ETH/BNB/SOL/XRP)을 모두 스캔해서 신호가 뜬 코인에 '
                  '진입합니다. 진입 후에는 청산될 때까지 그 코인만 관리합니다.'),
              value: _c.multiCoinScan,
              onChanged: locked ? null : (v) => setState(() => _c.multiCoinScan = v),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<StrategyType>(
              initialValue: _c.strategy,
              decoration: const InputDecoration(
                  labelText: '전략', border: OutlineInputBorder(), isDense: true),
              items: [
                for (final s in StrategyType.values) DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: locked ? null : (v) => setState(() => _c.strategy = v ?? _c.strategy),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _c.interval,
              decoration: const InputDecoration(
                  labelText: '봉 간격', border: OutlineInputBorder(), isDense: true),
              items: [
                for (final i in ['1m', '5m', '15m', '1h']) DropdownMenuItem(value: i, child: Text(i)),
              ],
              onChanged: locked ? null : (v) => setState(() => _c.interval = v ?? _c.interval),
            ),
            _field('poll', '조회 주기 (초)', helper: '5초 이상'),
          ]),
        ),
        SectionCard(
          title: '리스크 관리 설정',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _field('leverage', '레버리지 배율', helper: '1 ~ 125'),
            _field('margin', '거래당 마진 (USDT)'),
            _field('sl', '손절 비율 (%)', helper: '진입가 대비 이 %만큼 불리해지면 거래소가 자동으로 청산합니다.'),
            _field('tp', '익절 비율 (%)'),
            _field('risk', '거래당 리스크 (%)',
                helper: '손실이 계좌의 이 비율을 넘지 않도록 진입 수량을 자동 계산. 손절 비율(%) 입력 필요. '
                    '비워두면 기존 고정 마진 방식 사용'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('물타기 (포지션 추가)'),
              subtitle: const Text('손절가에 도달하기 전, 진입가 대비 아래 %만큼 불리해지면 원래 진입과 같은 수량으로 '
                  '딱 한 번 추가 진입해 평단을 낮춥니다(숏은 높입니다). 레버리지 선물에서는 노출이 커지는 만큼 '
                  '청산 위험도 커지니 신중히 사용하세요.'),
              value: _c.averageDownEnabled,
              onChanged: locked
                  ? null
                  : (v) => setState(() {
                        _c.averageDownEnabled = v;
                        final sl = _d('sl');
                        if (v && _num['avg']!.text.isEmpty && sl != null) {
                          _num['avg']!.text = (sl * 0.9).toStringAsFixed(2);
                        }
                      }),
            ),
            if (_c.averageDownEnabled)
              _field('avg', '물타기 발동 % (손절 %보다 작아야 함)',
                  helper: '손절 직전(손절 %의 90%)으로 자동 계산됩니다. 필요하면 직접 수정하세요.'),
            _field('daily', '일일 손실 한도 (%)',
                helper: '오늘 누적 손실이 계좌의 이 비율에 도달하면 전량 즉시 청산하고 다음 날까지 신규 진입을 막습니다. '
                    '비워두면 비활성'),
            _field('cdN', '연속 손절 쿨다운 기준 (회)', helper: '0 이면 비활성'),
            _field('cdH', '쿨다운 시간 (시간)'),
            _field('spread', '최대 허용 스프레드 (%)', helper: '비워두면 스프레드 필터 비활성'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('상위 타임프레임 추세 필터 (1h EMA200)'),
              subtitle: const Text('1시간봉 EMA200 위에서는 롱만, 아래에서는 숏만 진입합니다.'),
              value: _c.trendFilter,
              onChanged: locked ? null : (v) => setState(() => _c.trendFilter = v),
            ),
          ]),
        ),
        SectionCard(
          title: '데모 계좌',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _field('demo', '데모 시작 잔고 (USDT)'),
            OutlinedButton(
              onPressed: locked
                  ? null
                  : () async {
                      final ok = await confirm(context, '데모 계좌 초기화',
                          '데모 포지션을 지우고 시작 잔고(${app.config.demoStartBalance} USDT)로 되돌립니다.');
                      if (!ok) return;
                      await app.resetDemo();
                      if (context.mounted) toast(context, '데모 계좌를 초기화했습니다');
                    },
              child: const Text('데모 계좌 초기화'),
            ),
          ]),
        ),
        SectionCard(
          title: '텔레그램 알림 (선택)',
          child: Column(children: [
            _field('tgToken', '봇 토큰', number: false),
            _field('tgChat', 'Chat ID', number: false),
          ]),
        ),
        SectionCard(
          title: '표시 통화',
          child: DropdownButtonFormField<String>(
            initialValue: _c.displayCurrency,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            items: [
              for (final c in CurrencyService.supported) DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: locked ? null : (v) => setState(() => _c.displayCurrency = v ?? 'USD'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: locked ? null : () => setState(_reset),
                child: const Text('되돌리기'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: FilledButton(onPressed: locked ? null : _save, child: const Text('저장')),
            ),
          ]),
        ),
      ],
    );
  }
}
