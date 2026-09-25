# 국내주식 자동매매 앱 (Android)

`kr_stock_trader`(Python)의 전략·리스크 관리·자동매매 엔진을 Dart 로 옮긴 Flutter 앱입니다.
참고한 코인 선물 앱처럼 **휴대폰에서 직접** 증권사 API 를 호출해 자동매매합니다.

## 설치
GitHub 저장소의 **Releases** 에서 최신 `kr-stock-app-build-N` 을 열고 휴대폰으로 APK 를 받습니다.
- 대부분의 휴대폰: `kr-stock-app-arm64.apk`
- 설치가 안 되면: `kr-stock-app-universal.apk`

처음 설치 시 "출처를 알 수 없는 앱 설치 허용"이 필요합니다.

## 지원 증권사
| 증권사 | 필요한 값 | 모의투자 |
|---|---|---|
| 모의매매 (가상 시세) | 없음 | 항상 |
| 한국투자증권 | App Key, App Secret, 계좌번호 | 별도 서버 자동 |
| 키움증권 | App Key, Secret Key | 별도 서버 자동 |
| LS증권 | App Key, App Secret | 모의투자용 키 사용 |
| DB증권 | App Key, App Secret | 모의투자용 키 사용 |
| NH투자증권 (NHPLUG) | App Key, App Secret (계좌번호 선택) | 별도 서버 + 모의 계좌 자동 선택 |

대신증권(CYBOS Plus)과 신한(indi)은 Windows 전용이라 앱에는 없습니다 (PC용 `kr_stock_trader` 사용).

## 화면
- **대시보드**: 총자산·주문가능·평가손익·오늘 실현손익, 자동매매 시작/중지, 수동 주문, 종목별 상태, 실행 로그
- **차트**: 일봉/분봉 캔들 + EMA 9/21, 현재 전략 신호와 RSI
- **기록**: 체결 기록, 승률·손익비·누적손익
- **설정**: 증권사·키, 모의/실전, 감시 종목, 전략(MA 크로스 / RSI / MA+RSI), 봉 간격, 리스크(손절·익절·트레일링·물타기·일일 손실 한도·연속 손실 쿨다운·스프레드·최대 보유 수·마감 전 청산), 텔레그램 알림

## 동작 방식
- 자동매매를 켜면 상단 알림(포그라운드 서비스)이 떠서 화면이 꺼져도 계속 동작합니다.
  배터리 최적화 제외를 허용해야 제조사 절전 기능에 의해 멈추지 않습니다.
- 정규장(평일 09:00~15:30 KST)에만 주문하고, 설정에 넣은 휴장일은 쉽니다. 가상 시세 모드는 시간과 무관하게 동작합니다.
- 감시 종목만 사고팔며 계좌의 다른 보유 종목은 건드리지 않습니다.
- API 키는 Android Keystore 기반 보안 저장소에만 저장됩니다.

## 개발
```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```
APK 는 `.github/workflows/kr-stock-app-apk.yml` 이 `kr_stock_app/` 변경 시 자동으로 빌드해 Actions 아티팩트와 GitHub Release 로 올립니다.

## 주의
- 투자 손실 책임은 사용자에게 있습니다. 반드시 모의투자로 먼저 검증하세요.
- 매도 손익은 주문 시점 호가로 추정한 값입니다.
- 증권사 서버 연결은 공식 명세·샘플과 대조했지만 실제 계좌로는 검증되지 않았습니다.
