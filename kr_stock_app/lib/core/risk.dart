// 리스크 관리: 수량 계산, 청산 조건, 진입 차단 조건.
import 'config.dart';
import 'market.dart';

class RiskManager {
  final RiskConfig cfg;
  RiskManager(this.cfg);

  int positionSize(double price, double equity, double cash) {
    if (price <= 0) return 0;
    int qty;
    if (cfg.riskPerTradePct != null && (cfg.stopLossPct ?? 0) > 0) {
      final maxLoss = equity * cfg.riskPerTradePct! / 100;
      qty = (maxLoss / (price * cfg.stopLossPct! / 100)).floor();
    } else {
      qty = (cfg.budgetPerTrade / price).floor();
    }
    while (qty > 0 && buyCost(price, qty, cfg.feeRate) > cash) {
      qty--;
    }
    return qty < 0 ? 0 : qty;
  }

  /// 청산 사유 또는 null
  String? checkExit(double avg, double price, double peak) {
    if (avg <= 0) return null;
    final pnl = (price / avg - 1) * 100;
    if (cfg.stopLossPct != null && pnl <= -cfg.stopLossPct!) return '손절 ${pnl.toStringAsFixed(2)}%';
    if (cfg.takeProfitPct != null && pnl >= cfg.takeProfitPct!) return '익절 ${pnl.toStringAsFixed(2)}%';
    if (cfg.trailingStopPct != null && peak > avg) {
      final drop = (1 - price / peak) * 100;
      if (drop >= cfg.trailingStopPct!) {
        return '트레일링 스탑 (고점 대비 -${drop.toStringAsFixed(2)}%)';
      }
    }
    return null;
  }

  bool shouldAverageDown(double avg, double price) {
    if (cfg.averageDownPct == null || avg <= 0) return false;
    return (price / avg - 1) * 100 <= -cfg.averageDownPct!;
  }

  bool dailyLimitHit(double realizedToday, double startEquity) {
    if (cfg.dailyLossLimitPct == null || startEquity <= 0) return false;
    return realizedToday <= -startEquity * cfg.dailyLossLimitPct! / 100;
  }

  DateTime? cooldownUntil(int consecutiveLosses, DateTime? lastLoss) {
    final n = cfg.maxConsecutiveLosses;
    if (n == null || n <= 0 || consecutiveLosses < n || lastLoss == null) return null;
    return lastLoss.add(Duration(minutes: (cfg.cooldownHours * 60).round()));
  }

  bool spreadOk(double? spreadPct) => cfg.maxSpreadPct == null || spreadPct == null || spreadPct <= cfg.maxSpreadPct!;
}
