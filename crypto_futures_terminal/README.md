# 글로벌 선물 터미널 (4탭 구조 재작성판)

`global-crypto-terminal-arm64.apk`(패키지 `global_futures_terminal`)의 기능을
`kr-stock-app-arm64.apk`와 같은 **하단 4개 메뉴 + 모듈 분리 구조**로 다시 작성한 Flutter 소스입니다.

| 탭 | 내용 |
|---|---|
| 대시보드 | 계좌 요약(데모/실전 잔고, 오늘 실현 손익), 자동매매 시작/중지, 열린 포지션(손절·익절가, 예상 강제청산가, 포지션 종료), 데모 테스트 롱/숏 진입, 실행 로그 |
| 차트 | 코인·봉 간격 선택, 캔들 + EMA 9/21, 매수/매도 게이지, 시장 분석(RSI, 구간 고저, 현재 전략 신호) |
| 거래 내역 | 전체/데모/실전 필터, 승률·총손익·평균손익·손익비(PF), 청산 거래 목록, 기록 삭제 |
| 설정 | 데모/실전 모드(실전 전환 시 지문/PIN), 거래소 Top 5 + API 키(보안 저장소), 코인 Top 5·다중 코인 감시, 전략·봉 간격, 리스크 관리, 데모 계좌 초기화, 텔레그램, 표시 통화 |

## 구조 (kr_stock_app 과 동일한 계층)

```
lib/
  main.dart               앱 진입점 + 하단 NavigationBar(4탭)
  app_state.dart          4개 탭이 공유하는 상태 (ChangeNotifier)
  core/
    config.dart           TradingConfig (검증/JSON), ApiCredentials
    models.dart           Candle, Ticker, Position, TradeRecord, Signal ...
    indicators.dart       SMA/EMA/RSI, 예상 강제청산가, 매수/매도 게이지 점수
    strategies.dart       MA 크로스(9/21), RSI 과매수/과매도, 이평+RSI, 최저가 진입, 최고가 저항, 1h EMA200 추세 필터
    risk.dart             진입 수량(고정 마진 / 거래당 리스크 %), 손절·익절가, 물타기, 일일 손실 한도, 연속 손절 쿨다운
    market.dart           5개 거래소 공개 시세(캔들/호가) 조회
    engine.dart           자동매매 루프: 동기화 → 포지션 관리 또는 신호 스캔·진입
    history.dart          거래 내역 저장 + 통계
  exchanges/              (kr_stock_app 의 brokers/ 에 해당)
    exchange.dart         공통 인터페이스 + 서명/수량 반올림
    binance.dart  bybit.dart  okx.dart  bitget.dart  gate.dart
    paper.dart            데모(모의투자) 거래소 — 실제 시세로 가상 체결
  services/
    storage.dart          설정(SharedPreferences) / API 키(flutter_secure_storage)
    telegram.dart         텔레그램 알림
    foreground.dart       백그라운드 유지용 포그라운드 서비스
    app_lock.dart         지문/PIN 본인 확인
    currency.dart         USDT → 표시 통화 환산 (open.er-api.com)
  ui/
    dashboard_screen.dart  chart_screen.dart  history_screen.dart  settings_screen.dart  common.dart
```

## 실행

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

## 주의

- 실전 모드는 거래소 계정이 **단방향(One-way) 포지션 모드**라고 가정합니다. 격리 마진으로 설정합니다.
- 거래소 API 경로/서명은 각 거래소 공개 문서 기준으로 작성했으며, 실제 키로 소액 검증 후 사용하세요.
  API 키에 출금 권한은 절대 부여하지 마세요.
- 원본 APK 의 다국어(35개 언어)와 라이선스 검증(`AntiTamperLicenseVault`)은 이 재작성판에 포함하지 않았습니다(한국어 UI).
- 투자 손실에 대한 책임은 사용자에게 있으며, 이 앱은 수익을 보장하지 않습니다.
