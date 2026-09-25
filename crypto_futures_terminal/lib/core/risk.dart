import 'dart:math' as math;

import 'config.dart';
import 'models.dart';

/// 진입 수량, 손절/익절가, 일일 손실 한도, 연속 손절 쿨다운을 계산한다.
class RiskManager {
  final TradingConfig cfg;
  RiskManager(this.cfg);

  /// 진입 수량(코인 개수). 거래당 리스크 % 가 있으면 손절 시 손실이 그 비율을 넘지 않게 계산,
  /// 없으면 고정 마진 × 레버리지.
  double entryQty({required double price, required double balance}) {
    if (price <= 0) return 0;
    double notional = cfg.marginPerTrade * cfg.leverage;
    final risk = cfg.riskPerTradePct, sl = cfg.stopLossPct;
    if (risk != null && sl != null && sl > 0) {
      final maxLoss = balance * risk / 100;
      notional = maxLoss / (sl / 100);
      // 가용 잔고 × 레버리지를 넘지 않도록 제한
      notional = math.min(notional, balance * cfg.leverage * 0.95);
    }
    return notional / price;
  }

  double? stopLossPrice(Side side, double entry) {
    final p = cfg.stopLossPct;
    if (p == null) return null;
    return side == Side.long ? entry * (1 - p / 100) : entry * (1 + p / 100);
  }

  double? takeProfitPrice(Side side, double entry) {
    final p = cfg.takeProfitPct;
    if (p == null) return null;
    return side == Side.long ? entry * (1 + p / 100) : entry * (1 - p / 100);
  }

  /// 가격 기준 불리한 이동 % (진입가 대비).
  static double adverseMovePct(Position p, double price) =>
      (p.entryPrice - price) / p.entryPrice * 100 * p.side.sign;

  bool shouldAverageDown(Position p, double price, bool alreadyAveraged) {
    if (!cfg.averageDownEnabled || alreadyAveraged) return false;
    final a = cfg.averageDownPct;
    return a != null && adverseMovePct(p, price) >= a;
  }

  /// 예상 손절 금액 (USDT, 양수).
  double? estimatedStopLoss(double qty, double entry) {
    final p = cfg.stopLossPct;
    return p == null ? null : qty * entry * p / 100;
  }
}

/// 날짜가 바뀌면 리셋되는 일일 손익과 연속 손절 카운터.
class RiskState {
  DateTime _day = _today();
  double todayRealized = 0;
  double dayStartBalance = 0;
  int consecutiveLosses = 0;
  DateTime? cooldownUntil;
  bool dailyLimitHit = false;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void rollDay(double balance) {
    final t = _today();
    if (t != _day || dayStartBalance == 0) {
      if (t != _day) {
        todayRealized = 0;
        dailyLimitHit = false;
      }
      _day = t;
      dayStartBalance = balance;
    }
  }

  void onClosed(double pnl, TradingConfig cfg) {
    todayRealized += pnl;
    if (pnl < 0) {
      consecutiveLosses++;
      if (cfg.cooldownLosses > 0 && consecutiveLosses >= cfg.cooldownLosses) {
        cooldownUntil = DateTime.now()
            .add(Duration(minutes: (cfg.cooldownHours * 60).round()));
        consecutiveLosses = 0;
      }
    } else {
      consecutiveLosses = 0;
    }
  }

  Duration? cooldownRemaining() {
    final u = cooldownUntil;
    if (u == null) return null;
    final d = u.difference(DateTime.now());
    return d.isNegative ? null : d;
  }

  /// 오늘 누적 손실(실현+미실현)이 한도 이상인지.
  bool exceedsDailyLimit(TradingConfig cfg, double unrealized) {
    final lim = cfg.dailyLossLimitPct;
    if (lim == null || dayStartBalance <= 0) return false;
    final loss = -(todayRealized + unrealized);
    return loss >= dayStartBalance * lim / 100;
  }
}
