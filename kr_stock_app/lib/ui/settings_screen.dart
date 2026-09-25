import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/config.dart';
import '../core/strategies.dart';
import '../services/storage.dart';
import 'common.dart';

class SettingsScreen extends StatefulWidget {
  final AppController controller;
  const SettingsScreen({super.key, required this.controller});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppConfig cfg;
  final Map<String, TextEditingController> _secretCtl = {};
  late final TextEditingController _symbols, _poll, _paperCash, _candles, _trend, _holidays;
  final Map<String, TextEditingController> _risk = {};

  AppController get c => widget.controller;

  static const _riskFields = <(String, String, bool)>[
    // (키, 라벨, 비워도 되는지)
    ('budgetPerTrade', '1회 매수 금액 (원)', false),
    ('riskPerTradePct', '1회 위험 % (손절 시 자본 대비 최대 손실, 비우면 금액 기준)', true),
    ('stopLossPct', '손절 %', true),
    ('takeProfitPct', '익절 %', true),
    ('trailingStopPct', '트레일링 스탑 % (고점 대비)', true),
    ('averageDownPct', '물타기 % (손절 % 보다 작게, 1회)', true),
    ('dailyLossLimitPct', '일일 손실 한도 % (도달 시 전량 청산)', true),
    ('maxConsecutiveLosses', '연속 손실 쿨다운 횟수', true),
    ('cooldownHours', '쿨다운 시간', false),
    ('maxSpreadPct', '최대 허용 호가 스프레드 %', true),
    ('maxPositions', '최대 보유 종목 수', false),
    ('exitMinutesBeforeClose', '장 마감 N분 전 전량 청산 (당일 매매)', true),
    ('feeRate', '매매 수수료율 (예: 0.00015)', false),
    ('taxRate', '증권거래세율 (예: 0.002)', false),
  ];

  @override
  void initState() {
    super.initState();
    cfg = AppConfig.fromJson(c.config.toJson());
    for (final k in AppController.secretKeys) {
      _secretCtl[k] = TextEditingController(text: c.secret(k));
    }
    _symbols = TextEditingController(text: cfg.symbols.join(', '));
    _poll = TextEditingController(text: '${cfg.pollSeconds}');
    _paperCash = TextEditingController(text: cfg.paperCash.round().toString());
    _candles = TextEditingController(text: '${cfg.candles}');
    _trend = TextEditingController(text: cfg.trendFilterPeriod?.toString() ?? '');
    _holidays = TextEditingController(text: cfg.holidays.join(', '));
    final r = cfg.risk.toJson();
    for (final (k, _, _) in _riskFields) {
      final v = r[k];
      _risk[k] = TextEditingController(text: v == null ? '' : (v is double && v == v.roundToDouble() && v.abs() >= 1 ? '${v.round()}' : '$v'));
    }
  }

  Future<void> _save() async {
    if (c.running) {
      toast(context, '자동매매를 먼저 중지한 뒤 저장하세요');
      return;
    }
    final risk = <String, dynamic>{};
    for (final (k, label, optional) in _riskFields) {
      final t = _risk[k]!.text.trim();
      if (t.isEmpty) {
        if (!optional) return toast(context, '$label 을(를) 입력하세요');
        risk[k] = null;
        continue;
      }
      final n = num.tryParse(t.replaceAll(',', ''));
      if (n == null) return toast(context, '$label 값이 숫자가 아닙니다');
      risk[k] = n;
    }
    final next = AppConfig.fromJson({
      ...cfg.toJson(),
      'symbols': _symbols.text.split(RegExp(r'[,\s]+')).map((s) => s.trim().toUpperCase()).where((s) => s.isNotEmpty).toList(),
      'pollSeconds': int.tryParse(_poll.text.trim()) ?? 30,
      'paperCash': double.tryParse(_paperCash.text.trim().replaceAll(',', '')) ?? 10000000,
      'candles': int.tryParse(_candles.text.trim()) ?? 60,
      'trendFilterPeriod': int.tryParse(_trend.text.trim()),
      'holidays': _holidays.text.split(RegExp(r'[,\s]+')).where((s) => s.length == 8).toList(),
      'risk': risk,
    });
    final problem = next.validate();
    if (problem != null) return toast(context, problem);
    for (final e in _secretCtl.entries) {
      await c.saveSecret(e.key, e.value.text);
    }
    await c.saveConfig(next);
    setState(() => cfg = AppConfig.fromJson(next.toJson()));
    await c.refreshBalance();
    if (mounted) toast(context, c.lastError == null ? '저장했습니다' : '저장했지만 연결 오류: ${c.lastError}');
  }

  Future<void> _setLive(bool live) async {
    if (live &&
        !await confirm(context, '실전 계좌로 전환',
            '실제 돈으로 주문이 나갑니다. 모의투자에서 충분히 검증했는지 확인하세요.\n\n실전으로 전환할까요?', ok: '실전 전환')) {
      return;
    }
    setState(() => cfg.live = live);
  }

  Widget _field(TextEditingController ctl, String label, {bool secret = false, bool number = false, String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: TextField(
          controller: ctl,
          obscureText: secret,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final fields = brokerFields[cfg.broker] ?? const [];
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      if (c.running)
        const Card(
          color: Color(0xFF3D2F00),
          child: Padding(padding: EdgeInsets.all(12), child: Text('자동매매 실행 중에는 설정을 저장할 수 없습니다. 대시보드에서 중지하세요.')),
        ),
      const SectionTitle('증권사'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: DropdownButtonFormField<String>(
          initialValue: cfg.broker,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: brokerNames.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (v) => setState(() => cfg.broker = v!),
        ),
      ),
      if (cfg.broker != 'paper')
        SwitchListTile(
          title: Text(cfg.live ? '실전 계좌' : '모의투자'),
          subtitle: Text(brokerDemoNotes[cfg.broker] ?? ''),
          value: cfg.live,
          activeThumbColor: upColor,
          onChanged: _setLive,
        ),
      ...fields.map((f) => _field(_secretCtl[f.$1]!, f.$2, secret: f.$3)),
      if (cfg.broker == 'paper') ...[
        _field(_paperCash, '모의 시작 현금 (원)', number: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: DropdownButtonFormField<String>(
            initialValue: _secretCtl['paper_source']!.text.isEmpty ? 'paper' : _secretCtl['paper_source']!.text,
            decoration: const InputDecoration(labelText: '시세 출처', border: OutlineInputBorder(), isDense: true),
            items: [
              const DropdownMenuItem(value: 'paper', child: Text('가상 시세 (장 시간 무관)')),
              ...brokerFields.keys.map((k) => DropdownMenuItem(value: k, child: Text('${brokerNames[k]} 실제 시세'))),
            ],
            onChanged: (v) => setState(() => _secretCtl['paper_source']!.text = v == 'paper' ? '' : v!),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('실제 시세를 쓰려면 해당 증권사 키도 입력해야 합니다. 주문은 앱 안에서만 체결됩니다.',
              style: TextStyle(fontSize: 12, color: mutedColor)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton(
              onPressed: () async {
                if (await confirm(context, '모의 계좌 초기화', '보유 종목을 지우고 시작 현금으로 되돌립니다.', ok: '초기화')) await c.resetPaper();
              },
              child: const Text('모의 계좌 초기화'),
            ),
          ),
        ),
      ],
      const SectionTitle('종목 · 전략'),
      _field(_symbols, '감시 종목코드 (쉼표로 구분)', hint: '005930, 000660'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: DropdownButtonFormField<String>(
          initialValue: cfg.strategy,
          decoration: const InputDecoration(labelText: '전략', border: OutlineInputBorder(), isDense: true),
          items: strategyNames.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (v) => setState(() => cfg.strategy = v!),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: DropdownButtonFormField<String>(
          initialValue: cfg.interval,
          decoration: const InputDecoration(labelText: '봉 간격', border: OutlineInputBorder(), isDense: true),
          items: const ['D', '60m', '30m', '15m', '10m', '5m', '3m', '1m']
              .map((s) => DropdownMenuItem(value: s, child: Text(s == 'D' ? '일봉' : '${s.replaceAll('m', '')}분봉')))
              .toList(),
          onChanged: (v) => setState(() => cfg.interval = v!),
        ),
      ),
      _field(_candles, '전략 계산에 쓸 캔들 수', number: true),
      _field(_poll, '조회 주기 (초)', number: true),
      _field(_trend, '상위 추세 필터: 일봉 N일 이동평균 위에서만 매수 (비우면 끔)', number: true),
      SwitchListTile(
        title: Text(cfg.marketOrder ? '시장가 주문' : '지정가 주문 (1호가)'),
        subtitle: const Text('지정가는 매수 시 매도1호가, 매도 시 매수1호가로 냅니다'),
        value: cfg.marketOrder,
        onChanged: (v) => setState(() => cfg.marketOrder = v),
      ),
      _field(_holidays, '휴장일 (YYYYMMDD, 쉼표 구분)', hint: '20261009, 20261225'),
      const SectionTitle('리스크 관리'),
      ..._riskFields.map((f) => _field(_risk[f.$1]!, f.$2, number: true)),
      const SectionTitle('텔레그램 알림 (선택)'),
      _field(_secretCtl['telegram_token']!, '봇 토큰', secret: true),
      _field(_secretCtl['telegram_chat_id']!, '채팅 ID'),
      Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(onPressed: c.running ? null : _save, icon: const Icon(Icons.save), label: const Text('저장')),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'API 키는 기기의 보안 저장소(Android Keystore)에만 저장되고 외부로 전송되지 않습니다. '
          '투자 손실에 대한 책임은 사용자에게 있으며, 이 앱은 수익을 보장하지 않습니다.',
          style: TextStyle(fontSize: 12, color: mutedColor),
        ),
      ),
    ]);
  }
}
