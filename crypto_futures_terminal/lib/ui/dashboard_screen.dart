import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/indicators.dart';
import '../core/models.dart';
import 'common.dart';

/// 대시보드: 계좌 요약 · 자동매매 시작/중지 · 열린 포지션 · 실행 로그.
class DashboardScreen extends StatelessWidget {
  final AppState app;
  const DashboardScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final cfg = app.config;
    final e = app.engine;
    final today = app.riskState.todayRealized;
    return RefreshIndicator(
      onRefresh: e.refresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          SectionCard(
            title: cfg.live ? '실전 계좌' : '데모 계좌 (모의투자)',
            trailing: Chip(
              label: Text(cfg.live ? '실전' : '데모'),
              backgroundColor: cfg.live ? kDown.withValues(alpha: .25) : null,
              visualDensity: VisualDensity.compact,
            ),
            child: Column(children: [
              KV('거래소', cfg.exchange.label),
              KV(cfg.live ? '실제 잔고' : '데모 잔고', app.money(app.equity)),
              KV('주문가능', app.money(e.balance)),
              KV('오늘 실현 손익', app.money(today, signed: true), color: pnlColor(today)),
              if (cfg.live && !app.creds.isCompleteFor(cfg.exchange))
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('API 키를 저장하면 실제 잔고가 표시됩니다.',
                      style: TextStyle(color: Colors.orange)),
                ),
            ]),
          ),
          _AutoTradingCard(app: app),
          _PositionCard(app: app),
          if (!cfg.live) _TestEntryCard(app: app),
          _LogCard(app: app),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '전략/구현 오류로 손실이 발생할 수 있으며, 그 책임은 사용자 본인에게 있습니다. '
              '이 앱은 수익을 보장하지 않습니다.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _AutoTradingCard extends StatelessWidget {
  final AppState app;
  const _AutoTradingCard({required this.app});

  Future<void> _toggle(BuildContext context) async {
    if (app.running) {
      await app.stopTrading();
      return;
    }
    if (app.config.live) {
      final ok = await confirm(
        context,
        '실전 자동매매 경고',
        '실전 모드는 입력하신 ${app.config.exchange.label} 키로 실제 자금을 이용해 주문을 전송합니다.\n\n'
            '전략/구현 오류로 손실이 발생할 수 있으며, 그 책임은 사용자 본인에게 있습니다.\n\n계속하시겠습니까?',
        ok: '실전 시작',
        danger: true,
      );
      if (!ok) return;
    }
    final err = await app.startTrading();
    if (err != null && context.mounted) toast(context, err);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = app.config;
    final e = app.engine;
    final watch = cfg.multiCoinScan ? '다중 코인 감시 (${kCoins.join('/')})' : cfg.coin;
    return SectionCard(
      title: '자동매매',
      trailing: Icon(Icons.circle, size: 12, color: app.running ? Colors.green : Colors.grey),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KV('상태', e.status, color: app.running ? Colors.green : null),
        KV('전략', '${cfg.strategy.label} · ${cfg.interval}'),
        KV('감시 코인', watch),
        KV('레버리지 / 마진', '${cfg.leverage}x / ${cfg.marginPerTrade} USDT'),
        KV('손절 / 익절',
            '${cfg.stopLossPct?.toString() ?? '-'}% / ${cfg.takeProfitPct?.toString() ?? '-'}%'),
        for (final s in e.signals.entries) KV('현재 신호 · ${s.key}', s.value),
        const SizedBox(height: 10),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: app.running ? kDown : (cfg.live ? Colors.orange : kUp),
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () => _toggle(context),
          icon: Icon(app.running ? Icons.stop : Icons.play_arrow),
          label: Text(app.running
              ? '자동매매 중지'
              : '자동매매 시작 (${cfg.live ? '실전' : '데모'})'),
        ),
      ]),
    );
  }
}

class _PositionCard extends StatelessWidget {
  final AppState app;
  const _PositionCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final e = app.engine;
    final p = e.position;
    if (p == null) {
      return const SectionCard(title: '열린 포지션', child: Text('현재 열려있는 포지션이 없습니다.'));
    }
    final price = e.ticker?.mid ?? p.entryPrice;
    final u = p.unrealizedPnl(price);
    final liq = estimateLiquidationPrice(p.entryPrice, p.leverage, p.side);
    final estLoss = app.engine.risk.estimatedStopLoss(p.qty, p.entryPrice);
    return SectionCard(
      title: '열린 포지션',
      trailing: Chip(
        label: Text('${p.coin} ${p.side.label} ${p.leverage}x'),
        backgroundColor: (p.side == Side.long ? kUp : kDown).withValues(alpha: .25),
        visualDensity: VisualDensity.compact,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!app.running)
          Container(
            padding: const EdgeInsets.all(8),
            margin: const EdgeInsets.only(bottom: 8),
            color: Colors.orange.withValues(alpha: .15),
            child: const Text(
                '관리되지 않는 포지션 발견 — 포지션이 열려 있는데 자동매매는 꺼져 있어 손절/익절이 관리되지 않고 있습니다.',
                style: TextStyle(color: Colors.orange)),
          ),
        KV('진입가', fmtPrice(p.entryPrice)),
        KV('현재가', fmtPrice(price)),
        KV('수량', '${p.qty}'),
        KV('미실현 손익', '${app.money(u, signed: true)} (${p.unrealizedPct(price).toStringAsFixed(2)}%)',
            color: pnlColor(u)),
        KV('손절가', e.stopLoss == null ? '-' : fmtPrice(e.stopLoss!), color: kDown),
        KV('익절가', e.takeProfit == null ? '-' : fmtPrice(e.takeProfit!), color: kUp),
        if (estLoss != null) KV('예상 손절 금액', '-${estLoss.toStringAsFixed(2)} USDT'),
        KV('예상 강제청산가', fmtPrice(liq), color: Colors.orange),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: kDown),
          icon: const Icon(Icons.close),
          label: const Text('포지션 종료'),
          onPressed: () async {
            final ok = await confirm(context, '지금 포지션을 종료할까요?',
                '현재 포지션을 시장가로 즉시 청산합니다. 이 동작은 되돌릴 수 없습니다.',
                ok: '포지션 종료', danger: true);
            if (!ok) return;
            final err = await app.closePosition();
            if (err != null && context.mounted) toast(context, err);
          },
        ),
      ]),
    );
  }
}

class _TestEntryCard extends StatelessWidget {
  final AppState app;
  const _TestEntryCard({required this.app});

  @override
  Widget build(BuildContext context) {
    Future<void> go(Side s) async {
      final err = await app.testEntry(s);
      if (context.mounted) toast(context, err ?? '테스트 ${s.label} 진입 완료');
    }

    final disabled = app.engine.position != null;
    return SectionCard(
      title: '테스트 진입 (데모)',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('이 버튼은 데모용이라 실제 거래소에 주문이 들어가지 않습니다.',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kUp),
              onPressed: disabled ? null : () => go(Side.long),
              child: const Text('테스트 롱 진입'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kDown),
              onPressed: disabled ? null : () => go(Side.short),
              child: const Text('테스트 숏 진입'),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _LogCard extends StatelessWidget {
  final AppState app;
  const _LogCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final logs = app.engine.logs;
    return SectionCard(
      title: '실행 로그',
      child: logs.isEmpty
          ? const Text('아직 기록이 없습니다', style: TextStyle(color: Colors.grey))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final l in logs.take(50))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('${fmtTime(l.time)}  ${l.message}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
              ],
            ),
    );
  }
}
