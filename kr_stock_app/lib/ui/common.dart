import 'package:flutter/material.dart';

/// 한국 증시 관례: 상승 빨강, 하락 파랑
const upColor = Color(0xFFEF4444);
const downColor = Color(0xFF3B82F6);
const mutedColor = Color(0xFF8B949E);

Color pnlColor(double v) => v > 0 ? upColor : (v < 0 ? downColor : mutedColor);

String won(double v, {bool sign = false}) {
  final s = v.abs().round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final prefix = v < 0 ? '-' : (sign && v > 0 ? '+' : '');
  return '$prefix$s';
}

String pct(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}%';

String hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

String mdhm(DateTime t) =>
    '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 4),
        child: Row(children: [
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, color: mutedColor))),
          ?trailing,
        ]),
      );
}

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));

Future<bool> confirm(BuildContext context, String title, String body, {String ok = '확인'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    ) ??
    false;
