import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

class HistoryScreen extends StatelessWidget {
  final AppController controller;
  const HistoryScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final h = controller.history;
    final s = h.stats();
    final records = h.records.reversed.toList();
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('누적 성과 (청산 기준)', style: TextStyle(color: mutedColor)),
            const SizedBox(height: 6),
            Text('${won(s.totalPnl, sign: true)}원',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: pnlColor(s.totalPnl))),
            const SizedBox(height: 10),
            Wrap(spacing: 20, runSpacing: 6, children: [
              Text('청산 ${s.trades}회'),
              Text('승 ${s.wins} / 패 ${s.losses}'),
              Text('승률 ${s.winRate.toStringAsFixed(1)}%'),
              Text('손익비(PF) ${s.profitFactor == null ? '-' : s.profitFactor!.toStringAsFixed(2)}'),
            ]),
            const SizedBox(height: 6),
            const Text('매도 손익은 주문 시점 호가 기준 추정치이며, 수수료·거래세를 뺀 금액입니다.',
                style: TextStyle(fontSize: 12, color: mutedColor)),
          ]),
        ),
      ),
      SectionTitle('체결 기록 (${records.length})',
          trailing: records.isEmpty
              ? null
              : TextButton(
                  onPressed: () async {
                    if (await confirm(context, '기록 삭제', '모든 체결 기록과 통계를 지웁니다.', ok: '삭제')) controller.clearHistory();
                  },
                  child: const Text('전체 삭제'))),
      if (records.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('아직 체결 기록이 없습니다', style: TextStyle(color: mutedColor))),
      ...records.take(300).map((r) => Card(
            child: ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: r.side == 'buy' ? upColor.withValues(alpha: 0.2) : downColor.withValues(alpha: 0.2),
                child: Text(r.side == 'buy' ? '매수' : '매도',
                    style: TextStyle(fontSize: 10, color: r.side == 'buy' ? upColor : downColor)),
              ),
              title: Text('${r.symbol} ${r.qty}주 @ ${won(r.price)}'),
              subtitle: Text('${mdhm(r.time)} · ${r.reason}${r.broker.isEmpty ? '' : ' · ${r.broker}'}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: r.pnl == null
                  ? null
                  : Text(won(r.pnl!, sign: true), style: TextStyle(color: pnlColor(r.pnl!), fontWeight: FontWeight.w600)),
            ),
          )),
    ]);
  }
}
