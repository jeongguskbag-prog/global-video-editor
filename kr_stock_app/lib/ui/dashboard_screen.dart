import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../services/storage.dart';
import 'common.dart';

class DashboardScreen extends StatelessWidget {
  final AppController controller;
  const DashboardScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final b = c.balance;
    final cfg = c.config;
    final unrealized = b?.positions.fold(0.0, (a, p) => a + p.unrealizedPnl) ?? 0;
    final today = c.history.realizedOn(DateTime.now().toUtc().add(const Duration(hours: 9)));
    return RefreshIndicator(
      onRefresh: c.refreshBalance,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              const Text('국내주식 자동매매', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const Spacer(),
              _Badge(text: brokerNames[cfg.broker] ?? cfg.broker, color: const Color(0xFF30363D)),
              const SizedBox(width: 6),
              _Badge(text: cfg.live ? '실전' : '모의', color: cfg.live ? upColor : const Color(0xFF238636)),
            ]),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('총 평가자산', style: TextStyle(color: mutedColor)),
                const SizedBox(height: 4),
                Text(b == null ? '-' : '${won(b.totalEval)}원',
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Row(children: [
                  _Stat('주문가능', b == null ? '-' : won(b.cash)),
                  _Stat('평가손익', won(unrealized, sign: true), color: pnlColor(unrealized)),
                  _Stat('오늘 실현', won(today, sign: true), color: pnlColor(today)),
                ]),
              ]),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Row(children: [
                  Icon(Icons.circle, size: 12, color: c.running ? const Color(0xFF3FB950) : mutedColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.running
                          ? '자동매매 실행 중 · ${cfg.pollSeconds}초마다${c.lastTick != null ? ' · 최근 ${hms(c.lastTick!)}' : ''}'
                          : '자동매매 꺼짐',
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: c.running ? const Color(0xFF6E7681) : const Color(0xFF238636)),
                      onPressed: () => _toggle(context),
                      icon: Icon(c.running ? Icons.stop : Icons.play_arrow),
                      label: Text(c.running ? '자동매매 중지' : '자동매매 시작'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => _manualOrder(context), child: const Text('수동 주문')),
                ]),
                if (c.lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(c.lastError!, style: const TextStyle(color: Color(0xFFF85149))),
                  ),
              ]),
            ),
          ),
          SectionTitle('감시 종목 (${cfg.symbols.length})'),
          ...cfg.symbols.map((s) {
            final status = c.engine?.status[s];
            Position? pos;
            for (final p in b?.positions ?? const <Position>[]) {
              if (p.symbol == s) pos = p;
            }
            return Card(
              child: ListTile(
                dense: true,
                title: Text(pos?.name.isNotEmpty == true ? '${pos!.name} ($s)' : s),
                subtitle: Text(status ?? (c.running ? '대기 중' : '-'), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: pos == null
                    ? null
                    : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${pos.qty}주 · ${won(pos.currentPrice)}'),
                        Text(pct(pos.pnlPct), style: TextStyle(color: pnlColor(pos.pnlPct))),
                      ]),
              ),
            );
          }),
          if ((b?.positions ?? []).any((p) => !cfg.symbols.contains(p.symbol))) ...[
            const SectionTitle('기타 보유 종목 (자동매매 대상 아님)'),
            ...b!.positions.where((p) => !cfg.symbols.contains(p.symbol)).map((p) => Card(
                  child: ListTile(
                    dense: true,
                    title: Text(p.name.isNotEmpty ? '${p.name} (${p.symbol})' : p.symbol),
                    subtitle: Text('${p.qty}주 · 평단 ${won(p.avgPrice)}'),
                    trailing: Text(pct(p.pnlPct), style: TextStyle(color: pnlColor(p.pnlPct))),
                  ),
                )),
          ],
          SectionTitle('실행 로그', trailing: c.engine?.status['*'] == null ? null : Text(c.engine!.status['*']!, style: const TextStyle(color: mutedColor, fontSize: 12))),
          if (c.logs.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('아직 기록이 없습니다', style: TextStyle(color: mutedColor))),
          ...c.logs.take(50).map((l) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                child: Text('${hms(l.time)}  ${l.text}', style: const TextStyle(fontSize: 13)),
              )),
        ],
      ),
    );
  }

  Future<void> _toggle(BuildContext context) async {
    final c = controller;
    if (c.running) {
      await c.stop();
      return;
    }
    if (c.config.live &&
        !await confirm(context, '실전 자동매매', '실제 계좌로 주문이 나갑니다. 손실에 대한 책임은 본인에게 있습니다.\n\n계속할까요?', ok: '실전 시작')) {
      return;
    }
    await c.start();
    if (context.mounted && c.lastError != null && !c.running) toast(context, c.lastError!);
  }

  Future<void> _manualOrder(BuildContext context) async {
    final result = await showDialog<(String, Side, int, double?)>(context: context, builder: (_) => const _OrderDialog());
    if (result == null || !context.mounted) return;
    final (symbol, side, qty, price) = result;
    final label = side == Side.buy ? '매수' : '매도';
    final desc = '$symbol $label $qty주 ${price == null ? '시장가' : '지정가 ${won(price)}원'}';
    if (!await confirm(context, '${controller.config.live ? '[실전] ' : ''}주문 확인', desc, ok: label)) return;
    final r = await controller.manualOrder(symbol, side, qty, price);
    if (context.mounted) toast(context, r.ok ? '주문 완료 #${r.orderId}' : '주문 실패: ${r.message}');
  }
}

class _OrderDialog extends StatefulWidget {
  const _OrderDialog();
  @override
  State<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<_OrderDialog> {
  final _symbol = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _price = TextEditingController();
  Side _side = Side.buy;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('수동 주문'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<Side>(
            segments: const [
              ButtonSegment(value: Side.buy, label: Text('매수')),
              ButtonSegment(value: Side.sell, label: Text('매도')),
            ],
            selected: {_side},
            onSelectionChanged: (s) => setState(() => _side = s.first),
          ),
          TextField(controller: _symbol, decoration: const InputDecoration(labelText: '종목코드 (6자리)'), maxLength: 6),
          TextField(controller: _qty, decoration: const InputDecoration(labelText: '수량'), keyboardType: TextInputType.number),
          TextField(
              controller: _price,
              decoration: const InputDecoration(labelText: '가격 (비우면 시장가)'),
              keyboardType: TextInputType.number),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
            onPressed: () {
              final s = _symbol.text.trim().toUpperCase();
              final q = int.tryParse(_qty.text.trim()) ?? 0;
              final p = double.tryParse(_price.text.trim().replaceAll(',', ''));
              if (s.length != 6 || q <= 0) {
                toast(context, '종목코드 6자리와 수량을 확인하세요');
                return;
              }
              Navigator.pop(context, (s, _side, q, p));
            },
            child: const Text('다음'),
          ),
        ],
      );
}

class _Stat extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _Stat(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: mutedColor, fontSize: 12)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ]),
      );
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      );
}
