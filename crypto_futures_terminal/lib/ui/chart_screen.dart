import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/indicators.dart';
import '../core/models.dart';
import '../core/strategies.dart';
import 'common.dart';

/// 차트 · 시장 분석: 캔들 + EMA9/21, RSI, 매수/매도 게이지, 현재 전략 신호.
class ChartScreen extends StatefulWidget {
  final AppState app;
  const ChartScreen({super.key, required this.app});

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  static const _intervals = ['1m', '5m', '15m', '1h'];

  late String _coin = widget.app.config.coin;
  late String _interval = widget.app.config.interval;
  List<Candle> _candles = [];
  String? _error;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final c = await widget.app.market
          .candles(widget.app.config.exchange, _coin, _interval, limit: 120);
      if (!mounted) return;
      setState(() {
        _candles = c;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '차트 불러오기 실패: $e');
    } finally {
      _loading = false;
    }
  }

  void _select({String? coin, String? interval}) {
    setState(() {
      _coin = coin ?? _coin;
      _interval = interval ?? _interval;
      _candles = [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _candles;
    final cl = closes(c);
    final r = c.isEmpty ? double.nan : lastValid(rsi(cl));
    final score = buySellScore(c);
    final sig = evaluateStrategy(widget.app.config.strategy, c);
    final last = c.isEmpty ? null : c.last;
    final change = (c.length > 1) ? (c.last.close - c.first.open) / c.first.open * 100 : 0.0;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 6, children: [
              for (final k in kCoins)
                ChoiceChip(label: Text(k), selected: k == _coin, onSelected: (_) => _select(coin: k)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 6, children: [
              for (final i in _intervals)
                ChoiceChip(
                    label: Text(i), selected: i == _interval, onSelected: (_) => _select(interval: i)),
            ]),
          ),
          SectionCard(
            title: '$_coin/USDT · ${widget.app.config.exchange.label}',
            trailing: last == null
                ? null
                : Text('${fmtPrice(last.close)}  ${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
                    style: TextStyle(color: pnlColor(change), fontWeight: FontWeight.bold)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_error != null) Text(_error!, style: const TextStyle(color: kDown)),
              SizedBox(
                height: 300,
                child: c.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : CustomPaint(painter: _CandlePainter(c)),
              ),
              const SizedBox(height: 6),
              const Row(children: [
                _Legend(color: Colors.amber, text: 'EMA 9'),
                SizedBox(width: 12),
                _Legend(color: Colors.lightBlueAccent, text: 'EMA 21'),
              ]),
            ]),
          ),
          SectionCard(
            title: '매수/매도 게이지',
            child: _Gauge(score: score),
          ),
          SectionCard(
            title: '시장 분석',
            child: Column(children: [
              KV('RSI(14)', r.isNaN ? '-' : r.toStringAsFixed(1),
                  color: r > 70 ? kDown : (r < 30 ? kUp : null)),
              KV('EMA 9', fmtPrice(lastValid(ema(cl, 9)))),
              KV('EMA 21', fmtPrice(lastValid(ema(cl, 21)))),
              KV('구간 최고가', c.isEmpty ? '-' : fmtPrice(c.map((e) => e.high).reduce(math.max))),
              KV('구간 최저가', c.isEmpty ? '-' : fmtPrice(c.map((e) => e.low).reduce(math.min))),
              KV('전략 (${widget.app.config.strategy.label})',
                  sig.side == null ? sig.reason : '${sig.side!.label} 신호 — ${sig.reason}',
                  color: sig.side == null ? null : (sig.side == Side.long ? kUp : kDown)),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String text;
  const _Legend({required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 3, color: color),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ]);
}

class _Gauge extends StatelessWidget {
  final double score; // -100 ~ 100
  const _Gauge({required this.score});

  @override
  Widget build(BuildContext context) {
    final label = score > 40
        ? '강한 매수'
        : score > 10
            ? '매수'
            : score < -40
                ? '강한 매도'
                : score < -10
                    ? '매도'
                    : '중립';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('$label (${score.toStringAsFixed(0)})',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: pnlColor(score))),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, box) {
        final x = (score + 100) / 200 * box.maxWidth;
        return SizedBox(
          height: 18,
          child: Stack(children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                gradient: const LinearGradient(colors: [kDown, Colors.grey, kUp]),
              ),
            ),
            Positioned(
              left: (x - 3).clamp(0, box.maxWidth - 6),
              top: 0,
              bottom: 0,
              child: Container(width: 6, color: Colors.white),
            ),
          ]),
        );
      }),
      const SizedBox(height: 4),
      const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('매도', style: TextStyle(color: kDown)),
        Text('매수', style: TextStyle(color: kUp)),
      ]),
      const SizedBox(height: 4),
      const Text('RSI·이평·모멘텀을 합산한 참고 지표입니다. 매매 신호로 단독 사용하지 마세요.',
          style: TextStyle(color: Colors.grey, fontSize: 11)),
    ]);
  }
}

class _CandlePainter extends CustomPainter {
  final List<Candle> c;
  _CandlePainter(this.c);

  @override
  void paint(Canvas canvas, Size size) {
    final hi = c.map((e) => e.high).reduce(math.max);
    final lo = c.map((e) => e.low).reduce(math.min);
    final range = (hi - lo) == 0 ? 1 : hi - lo;
    const rightPad = 60.0;
    final w = (size.width - rightPad) / c.length;
    double y(double p) => size.height - (p - lo) / range * size.height;

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final p = lo + range * i / 4;
      final yy = y(p);
      canvas.drawLine(Offset(0, yy), Offset(size.width - rightPad, yy), grid);
      final tp = TextPainter(
        text: TextSpan(text: fmtPrice(p), style: const TextStyle(color: Colors.grey, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - rightPad + 4, (yy - tp.height / 2).clamp(0, size.height - tp.height)));
    }

    for (var i = 0; i < c.length; i++) {
      final k = c[i];
      final up = k.close >= k.open;
      final paint = Paint()..color = up ? kUp : kDown;
      final cx = i * w + w / 2;
      canvas.drawLine(Offset(cx, y(k.high)), Offset(cx, y(k.low)), paint..strokeWidth = 1);
      final top = y(math.max(k.open, k.close));
      final bot = y(math.min(k.open, k.close));
      canvas.drawRect(
          Rect.fromLTRB(i * w + w * .15, top, (i + 1) * w - w * .15, math.max(bot, top + 1)), paint);
    }

    void line(List<double> v, Color color) {
      final path = Path();
      var started = false;
      for (var i = 0; i < v.length; i++) {
        if (v[i].isNaN) continue;
        final o = Offset(i * w + w / 2, y(v[i]));
        started ? path.lineTo(o.dx, o.dy) : path.moveTo(o.dx, o.dy);
        started = true;
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }

    final cl = closes(c);
    line(ema(cl, 9), Colors.amber);
    line(ema(cl, 21), Colors.lightBlueAccent);
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) => old.c != c;
}
