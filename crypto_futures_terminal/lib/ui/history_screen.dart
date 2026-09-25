import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import 'common.dart';

/// 거래 내역: 통계 요약 + 청산된 거래 목록.
class HistoryScreen extends StatefulWidget {
  final AppState app;
  const HistoryScreen({super.key, required this.app});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool? _live; // null = 전체

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final items = app.history.items.where((t) => _live == null || t.live == _live).toList();
    final s = app.history.stats(live: _live);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<bool?>(
            segments: const [
              ButtonSegment(value: null, label: Text('전체')),
              ButtonSegment(value: false, label: Text('데모')),
              ButtonSegment(value: true, label: Text('실전')),
            ],
            selected: {_live},
            onSelectionChanged: (v) => setState(() => _live = v.first),
          ),
        ),
        SectionCard(
          title: '통계',
          trailing: IconButton(
            tooltip: '기록 삭제',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await confirm(context, '거래 내역을 전부 지울까요?',
                  '이 기기에 저장된 거래 내역이 모두 삭제됩니다. 실제 거래소 기록에는 영향이 없습니다.',
                  ok: '전체 삭제', danger: true);
              if (ok) await app.clearHistory();
            },
          ),
          child: Column(children: [
            KV('거래 수', '${s.count}회 (승 ${s.wins} / 패 ${s.count - s.wins})'),
            KV('승률', '${s.winRate.toStringAsFixed(1)}%'),
            KV('총 손익', app.money(s.totalPnl, signed: true), color: pnlColor(s.totalPnl)),
            KV('평균 손익', app.money(s.avgPnl, signed: true), color: pnlColor(s.avgPnl)),
            KV('손익비(PF)', s.profitFactor?.toStringAsFixed(2) ?? '-'),
          ]),
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text('아직 청산된 거래 내역이 없습니다.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          ),
        for (final t in items) _TradeTile(t: t, app: app),
      ],
    );
  }
}

class _TradeTile extends StatelessWidget {
  final TradeRecord t;
  final AppState app;
  const _TradeTile({required this.t, required this.app});

  @override
  Widget build(BuildContext context) {
    final sideColor = t.side == Side.long ? kUp : kDown;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: sideColor.withValues(alpha: .2),
          child: Text(t.side.label, style: TextStyle(color: sideColor, fontSize: 13)),
        ),
        title: Text('${t.coin} · ${t.leverage}x · ${t.reason}${t.live ? '' : ' (데모)'}'),
        subtitle: Text('${fmtPrice(t.entryPrice)} → ${fmtPrice(t.exitPrice)}\n'
            '${fmtTime(t.openedAt)} ~ ${fmtTime(t.closedAt)}'),
        isThreeLine: true,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${t.pnl >= 0 ? '+' : ''}${t.pnl.toStringAsFixed(2)}',
                style: TextStyle(color: pnlColor(t.pnl), fontWeight: FontWeight.bold)),
            Text('${t.pnlPct.toStringAsFixed(1)}%',
                style: TextStyle(color: pnlColor(t.pnl), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
