import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/indicators.dart';
import '../core/models.dart';
import '../core/strategies.dart';
import 'common.dart';

class ChartScreen extends StatefulWidget {
  final AppController controller;
  const ChartScreen({super.key, required this.controller});
  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  String? _symbol;
  String _interval = 'D';
  List<Candle> _candles = [];
  Quote? _quote;
  String? _error;
  bool _loading = false;

  static const intervals = ['D', '60m', '30m', '15m', '5m', '1m'];

  Future<void> _load() async {
    final c = widget.controller;
    final symbol = _symbol ?? (c.config.symbols.isNotEmpty ? c.config.symbols.first : null);
    if (symbol == null) return;
    setState(() {
      _symbol = symbol;
      _loading = true;
      _error = null;
    });
    try {
      final b = await c.broker();
      final candles = await b.getCandles(symbol, _interval, 120);
      final quote = await b.getQuote(symbol);
      setState(() {
        _candles = candles;
        _quote = quote;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final symbols = c.config.symbols;
    final closes = _candles.map((e) => e.close).toList();
    final r = closes.length > 15 ? rsi(closes).last : null;
    final signal = _candles.isEmpty ? null : buildStrategy(c.config.strategy).evaluate(_candles);
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          DropdownButton<String>(
            value: symbols.contains(_symbol) ? _symbol : (symbols.isEmpty ? null : symbols.first),
            items: symbols.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
            onChanged: (v) {
              _symbol = v;
              _load();
            },
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _interval,
            items: intervals.map((s) => DropdownMenuItem(value: s, child: Text(s == 'D' ? '일봉' : '${s.replaceAll('m', '')}분'))).toList(),
            onChanged: (v) {
              _interval = v!;
              _load();
            },
          ),
          const Spacer(),
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ]),
      ),
      if (_quote != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text('${won(_quote!.price)}원', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            Text('매수 ${_quote!.bid == null ? '-' : won(_quote!.bid!)} / 매도 ${_quote!.ask == null ? '-' : won(_quote!.ask!)}',
                style: const TextStyle(color: mutedColor)),
          ]),
        ),
      if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Color(0xFFF85149)))),
      if (_candles.isEmpty && _error == null)
        Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : FilledButton(onPressed: _load, child: const Text('차트 불러오기'))),
        ),
      if (_candles.isNotEmpty) ...[
        SizedBox(height: 300, child: CustomPaint(painter: CandlePainter(_candles), size: Size.infinite)),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(children: [
            _Legend(color: Color(0xFFF2CC60), text: 'EMA 9'),
            SizedBox(width: 12),
            _Legend(color: Color(0xFFA371F7), text: 'EMA 21'),
          ]),
        ),
        Card(
          child: ListTile(
            title: Text('현재 신호: ${switch (signal?.signal) { Signal.buy => '매수', Signal.sell => '매도', _ => '대기' }}'),
            subtitle: Text('${strategyNames[c.config.strategy]} · ${signal?.reason ?? ''}${r == null ? '' : ' · RSI ${r.toStringAsFixed(1)}'}'),
          ),
        ),
      ],
    ]);
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String text;
  const _Legend({required this.color, required this.text});
  @override
  Widget build(BuildContext context) =>
      Row(children: [Container(width: 12, height: 3, color: color), const SizedBox(width: 4), Text(text, style: const TextStyle(fontSize: 12))]);
}

class CandlePainter extends CustomPainter {
  final List<Candle> candles;
  CandlePainter(this.candles);

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    const pad = 12.0, right = 56.0;
    final w = size.width - pad - right, h = size.height - pad * 2;
    var hi = candles.map((c) => c.high).reduce((a, b) => a > b ? a : b);
    var lo = candles.map((c) => c.low).reduce((a, b) => a < b ? a : b);
    if (hi == lo) {
      hi += 1;
      lo -= 1;
    }
    double y(double v) => pad + (hi - v) / (hi - lo) * h;
    final step = w / candles.length;
    final grid = Paint()..color = const Color(0xFF21262D);
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= 4; i++) {
      final v = lo + (hi - lo) * i / 4;
      canvas.drawLine(Offset(pad, y(v)), Offset(pad + w, y(v)), grid);
      text.text = TextSpan(text: won(v), style: const TextStyle(fontSize: 10, color: mutedColor));
      text.layout();
      text.paint(canvas, Offset(pad + w + 4, y(v) - 6));
    }
    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final x = pad + step * i + step / 2;
      final color = c.close >= c.open ? upColor : downColor;
      final p = Paint()..color = color;
      canvas.drawLine(Offset(x, y(c.high)), Offset(x, y(c.low)), p..strokeWidth = 1);
      final top = y(c.close > c.open ? c.close : c.open), bottom = y(c.close > c.open ? c.open : c.close);
      canvas.drawRect(Rect.fromLTRB(x - step * 0.35, top, x + step * 0.35, bottom < top + 1 ? top + 1 : bottom), p);
    }
    final closes = candles.map((e) => e.close).toList();
    for (final (period, color) in [(9, const Color(0xFFF2CC60)), (21, const Color(0xFFA371F7))]) {
      final line = ema(closes, period);
      final path = Path();
      var started = false;
      for (var i = 0; i < line.length; i++) {
        final v = line[i];
        if (v == null) continue;
        final pt = Offset(pad + step * i + step / 2, y(v));
        started ? path.lineTo(pt.dx, pt.dy) : path.moveTo(pt.dx, pt.dy);
        started = true;
      }
      canvas.drawPath(path, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(CandlePainter old) => old.candles != candles;
}
