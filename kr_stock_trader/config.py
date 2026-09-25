"""설정. 거래 규칙은 JSON 파일에서, API 키 같은 비밀값은 환경변수에서 읽는다."""

import json
import os
from dataclasses import asdict, dataclass, field, fields
from typing import List, Optional


@dataclass
class RiskConfig:
    budget_per_trade: float = 1_000_000      # 1회 매수 금액 (원). risk_per_trade_pct 가 없을 때 사용
    risk_per_trade_pct: Optional[float] = None  # 손절 시 손실이 자본의 이 % 를 넘지 않게 수량 자동 계산
    stop_loss_pct: Optional[float] = 3.0     # 평단 대비 손절 %
    take_profit_pct: Optional[float] = 6.0   # 평단 대비 익절 %
    trailing_stop_pct: Optional[float] = None  # 수익 구간에서 고점 대비 이 % 하락 시 청산
    average_down_pct: Optional[float] = None   # 손절 전 이 % 하락 시 같은 수량 1회 추가매수 (손절 % 보다 작아야 함)
    daily_loss_limit_pct: Optional[float] = 5.0  # 당일 실현손실이 자본의 이 % 에 도달하면 전량 청산 + 당일 신규진입 중단
    max_consecutive_losses: Optional[int] = 3    # 연속 손실 횟수가 이 값에 도달하면 쿨다운
    cooldown_hours: float = 24.0
    max_spread_pct: Optional[float] = 0.5    # 매수/매도 1호가 스프레드가 이 % 를 넘으면 진입 보류
    max_positions: int = 5
    fee_rate: float = 0.00015                # 증권사 매매수수료 (편도)
    tax_rate: float = 0.0020                 # 증권거래세 (매도 시). 2026년 코스피·코스닥 0.20%
    exit_minutes_before_close: Optional[float] = None  # 설정 시 장 마감 N분 전 전량 청산 (당일 매매)

    def validate(self) -> None:
        if self.average_down_pct is not None:
            if self.stop_loss_pct is None or self.average_down_pct >= self.stop_loss_pct:
                raise ValueError("average_down_pct 는 stop_loss_pct 보다 작아야 합니다")
        if self.risk_per_trade_pct is not None and not self.stop_loss_pct:
            raise ValueError("risk_per_trade_pct 를 쓰려면 stop_loss_pct 가 필요합니다")
        if self.budget_per_trade <= 0 and self.risk_per_trade_pct is None:
            raise ValueError("budget_per_trade 는 0보다 커야 합니다")


@dataclass
class StrategyConfig:
    name: str = "ma_rsi"                  # ma_cross | rsi | ma_rsi
    params: dict = field(default_factory=dict)
    interval: str = "5m"                  # D(일봉) 또는 1m/3m/5m/10m/15m/30m/60m
    candles: int = 120
    trend_filter_period: Optional[int] = 60  # 일봉 N일 이동평균 위에서만 매수. None 이면 끔


@dataclass
class AppConfig:
    broker: str = "paper"                 # paper | kis | kiwoom | ls | db
    env: str = "demo"                     # demo(모의투자) | real(실전)
    symbols: List[str] = field(default_factory=lambda: ["005930", "000660"])
    order_type: str = "market"            # market | limit (limit 은 1호가에 맞춘 지정가)
    poll_seconds: int = 30
    order_cooldown_seconds: int = 90      # 주문 직후 같은 종목 재주문 방지
    paper_cash: float = 10_000_000        # paper 브로커 시작 현금
    paper_data: str = "synthetic"         # paper 시세 출처: synthetic | kis | kiwoom | ls | db
    history_file: str = "trade_history.jsonl"
    holidays: List[str] = field(default_factory=list)  # 휴장일 YYYYMMDD
    strategy: StrategyConfig = field(default_factory=StrategyConfig)
    risk: RiskConfig = field(default_factory=RiskConfig)

    @classmethod
    def load(cls, path: Optional[str]) -> "AppConfig":
        if not path:
            cfg = cls()
        else:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            cfg = cls(
                **{k: v for k, v in data.items() if k in _names(cls) and k not in ("strategy", "risk")},
                strategy=StrategyConfig(**_pick(StrategyConfig, data.get("strategy", {}))),
                risk=RiskConfig(**_pick(RiskConfig, data.get("risk", {}))),
            )
        cfg.validate()
        return cfg

    def validate(self) -> None:
        if self.env not in ("demo", "real"):
            raise ValueError("env 는 demo 또는 real 이어야 합니다")
        if self.order_type not in ("market", "limit"):
            raise ValueError("order_type 은 market 또는 limit 이어야 합니다")
        self.symbols = [s.strip() for s in self.symbols if s.strip()]
        for s in self.symbols:
            if len(s) != 6 or not s.isalnum():
                raise ValueError(f"종목코드는 6자리여야 합니다: {s}")
        self.risk.validate()

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False, indent=2)


def _names(cls) -> set:
    return {f.name for f in fields(cls)}


def _pick(cls, data: dict) -> dict:
    unknown = set(data) - _names(cls)
    if unknown:
        raise ValueError(f"{cls.__name__} 에 없는 설정: {', '.join(sorted(unknown))}")
    return data


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()
