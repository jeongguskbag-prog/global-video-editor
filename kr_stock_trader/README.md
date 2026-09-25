# 국내 주식 자동매매 터미널 (kr_stock_trader)

`global-crypto-terminal` 앱(바이낸스·바이비트·OKX 등 코인 선물 자동매매)의 구조를
**국내 주식(코스피·코스닥)** 에 맞게 옮긴 Python 패키지입니다.

| 코인 앱 | 이 패키지 |
|---|---|
| Binance / Bybit / OKX / Bitget / Gate 클라이언트 | **한국투자증권(KIS)**, **키움**, **LS증권**, **DB증권** Open API, 로컬 모의(paper) |
| MA Crossover(9/21), RSI 과매수/과매도, MA+RSI 결합 | 동일 (`ma_cross`, `rsi`, `ma_rsi`) |
| 손절/익절, 1회 위험 % 기반 수량, 물타기 1회, 일일 손실 한도, 연속 손실 쿨다운, 스프레드 필터, 1h EMA200 추세 필터 | 동일 (추세 필터는 일봉 N일 이동평균) |
| 텔레그램 알림, 거래 기록/승률 | 동일 |
| 롱/숏, 레버리지, 격리 마진 | **없음** – 현금 계좌는 매수 후 매도(롱)만 가능 |

국내 주식에 맞춘 추가 사항
- 호가가격단위(1·5·10·50·100·500·1,000원) 자동 맞춤
- 정규장(평일 09:00~15:30 KST)에만 동작, 휴장일 목록 설정 가능, 마감 N분 전 전량 청산 옵션
- 매수 수수료 + 매도 수수료 + 증권거래세(기본 0.20%) 반영한 손익 계산
- 실전 계좌 주문은 `--live` 옵션이 있어야만 실행 (기본은 모의투자 서버)

## 설치

```bash
pip install -r kr_stock_trader/requirements.txt
```

## 지원 증권사

| 설정값 `broker` | 증권사 | 필요한 환경변수 | 모의투자 |
|---|---|---|---|
| `kis` | 한국투자증권 | `KIS_APP_KEY`, `KIS_APP_SECRET`, `KIS_ACCOUNT` | 별도 서버 (`env: demo`) |
| `kiwoom` | 키움증권 (REST) | `KIWOOM_APP_KEY`, `KIWOOM_SECRET_KEY` | 별도 서버 (`env: demo`) |
| `ls` | LS증권 (구 이베스트) | `LS_APP_KEY`, `LS_APP_SECRET` | 같은 서버, **모의투자용 App Key** 사용 |
| `db` | DB증권 (구 DB금융투자) | `DB_APP_KEY`, `DB_APP_SECRET` | 같은 서버, **모의투자용 App Key** 사용 |
| `daishin` | 대신증권 CYBOS Plus (**Windows 전용**) | 없음 (`DAISHIN_ACCOUNT` 는 선택) | CYBOS Plus 로그인 시 '모의투자 접속' |
| `paper` | 로컬 모의 | 없음 | 항상 모의 |

LS·DB는 실전/모의 주소가 같고 발급받은 키 종류로 구분됩니다. `env` 값은 이 프로그램의 실전 주문 안전장치(`--live`)에만 쓰이므로,
모의투자 키를 넣었다면 `env: demo`, 실전 키를 넣었다면 `env: real` 로 맞춰 주세요.

### 연결하지 못하는 증권사

| 증권사 | 이유 |
|---|---|
| 미래에셋, 삼성, NH투자(나무), KB, 신한, 토스, 카카오페이 등 | 개인에게 공개된 REST 주문 API가 없음 (앱·HTS 전용) |
| NH (QV Open API), 신한 (indi) | Windows 전용 OCX 방식. 대신증권처럼 Windows 모듈로 추가 가능하지만 아직 미포함 |

## 대신증권 (Windows)

대신증권은 REST API 가 없고 CYBOS Plus 프로그램이 제공하는 COM 객체로 거래합니다.

준비물
1. 대신증권 계좌 + [CYBOS Plus 서비스 신청](https://money2.daishin.com) (모의투자는 모의투자 신청)
2. **32비트** Python 3 (python.org 에서 "Windows installer (32-bit)") — CYBOS Plus 가 32비트 전용
3. CYBOS Plus 실행 → 로그인 (모의투자는 로그인 창에서 '모의투자 접속'), 계좌 비밀번호 저장

실행
- `kr_stock_trader\windows\run_daishin.bat` 을 **마우스 오른쪽 → 관리자 권한으로 실행** 하면
  pywin32 설치, 설정 파일 생성 후 메뉴(잔고/현재가/자동매매/거래기록)가 나옵니다.
- 직접 실행하려면 관리자 권한 명령 프롬프트에서
  ```bat
  py -3-32 -m pip install -r kr_stock_trader\requirements-windows.txt
  py -3-32 -m kr_stock_trader -c config.json --broker daishin balance
  py -3-32 -m kr_stock_trader -c config.json --broker daishin run
  ```

참고
- 조회 15초당 60건, 주문 15초당 20건 제한을 CYBOS 가 알려 주는 남은 횟수로 자동 대기합니다.
- 계좌가 여러 개면 `DAISHIN_ACCOUNT` 환경변수로 지정하세요(비우면 첫 계좌).
- 모의투자/실전 구분은 CYBOS 로그인으로 결정됩니다. 설정의 `env` 는 이 프로그램의 실전 주문 안전장치(`--live`)에만 쓰이니 로그인한 쪽과 맞춰 주세요.

## 1) 계좌 없이 바로 체험 (가상 시세)

```bash
python -m kr_stock_trader quote 005930
python -m kr_stock_trader backtest 005930 --interval D --count 500
python -m kr_stock_trader run --cycles 300 --fast     # 가상 시세로 자동매매 시뮬레이션
python -m kr_stock_trader history
```

## 2) 한국투자증권 모의투자로 연결

1. [KIS Developers](https://apiportal.koreainvestment.com)에서 모의투자 계좌를 신청하고 App Key/Secret 발급
2. 환경변수 설정 (`.env.example` 참고)
   ```bash
   export KIS_APP_KEY=...  KIS_APP_SECRET=...  KIS_ACCOUNT=50123456-01
   ```
3. 설정 파일 복사 후 실행
   ```bash
   cp kr_stock_trader/config.example.json config.json
   python -m kr_stock_trader -c config.json balance
   python -m kr_stock_trader -c config.json quote 005930
   python -m kr_stock_trader -c config.json order buy 005930 1          # 시장가 1주 (확인 질문)
   python -m kr_stock_trader -c config.json order buy 005930 1 --price 70000   # 지정가
   python -m kr_stock_trader -c config.json run                        # 자동매매
   ```

다른 증권사는 `"broker"` 값을 `kiwoom` / `ls` / `db` 로 바꾸고 위 표의 환경변수를 설정하면 됩니다.
명령줄에서 `--broker ls` 처럼 일시적으로 바꿀 수도 있습니다.
실제 시세로 로컬 모의매매만 하려면 `"broker": "paper", "paper_data": "kis"` 로 두면
시세는 KIS에서 받고 주문은 로컬에서만 체결됩니다.

## 3) 실전 계좌

`"env": "real"` 로 바꾸고 명령에 `--live` 를 붙여야 주문이 나갑니다.
모의투자에서 충분히 검증한 뒤 적은 금액으로 시작하세요.

```bash
python -m kr_stock_trader -c config.json --env real run --live
```

## 설정 항목 (`config.example.json`)

| 항목 | 설명 |
|---|---|
| `symbols` | 감시 종목 6자리 코드. 엔진은 이 종목만 사고팔며 계좌의 다른 보유 종목은 건드리지 않음 |
| `order_type` | `market`(시장가) 또는 `limit`(매수는 매도1호가, 매도는 매수1호가 지정가) |
| `order_cooldown_seconds` | 주문 직후 같은 종목 재주문 방지 시간 |
| `strategy.interval` | `D`(일봉) 또는 `1m`,`3m`,`5m`,`10m`,`15m`,`30m`,`60m`. 분봉은 당일 데이터만 사용 |
| `strategy.trend_filter_period` | 일봉 N일 이동평균 위에서만 신규 매수 (`null` 이면 끔) |
| `risk.budget_per_trade` | 1회 매수 금액(원) |
| `risk.risk_per_trade_pct` | 손절 시 손실이 자본의 이 %를 넘지 않도록 수량 자동 계산 (손절 % 필요) |
| `risk.stop_loss_pct` / `take_profit_pct` / `trailing_stop_pct` | 평단 대비 손절 / 익절 / 고점 대비 트레일링 |
| `risk.average_down_pct` | 손절 전 이 % 하락 시 같은 수량 1회 추가매수 (손절 %보다 작아야 함) |
| `risk.daily_loss_limit_pct` | 당일 실현손실이 자본의 이 %에 도달하면 감시 종목 전량 청산 + 당일 신규 진입 중단 |
| `risk.max_consecutive_losses` / `cooldown_hours` | 연속 손실 후 쿨다운 |
| `risk.max_spread_pct` | 1호가 스프레드가 이 %를 넘으면 진입 보류 |
| `risk.exit_minutes_before_close` | 장 마감 N분 전 전량 청산 (당일 매매용) |
| `risk.fee_rate` / `tax_rate` | 증권사 수수료(편도) / 증권거래세 |

## 구조

```
kr_stock_trader/
  brokers/kis.py      한국투자증권 Open API (토큰 캐시, 시세/호가/일봉/분봉, 잔고, 현금주문)
  brokers/kiwoom.py   키움 REST API (ka10001/ka10004/ka10080/ka10081, kt00001/kt00018, kt10000/kt10001)
  brokers/ls.py       LS증권 Open API (t1101/t8410/t8412, t0424/CSPAQ12200, CSPAT00601)
  brokers/db.py       DB증권 Open API (현재가/일·분차트, 잔고/예수금, 주식종합주문)
  brokers/daishin.py  대신증권 CYBOS Plus COM (StockMst, StockChart, CpTd6033, CpTdNew5331A, CpTd0311)
  windows/            대신증권용 Windows 실행기 (run_daishin.bat)
  brokers/paper.py    로컬 모의 브로커 + 가상 시세
  strategies.py       MA 크로스 / RSI / MA+RSI
  risk.py             수량 계산, 청산 조건, 진입 차단 조건
  engine.py           자동매매 루프
  backtest.py         백테스트 (신호는 다음 봉 시가 체결, 봉 내 손절 우선)
  history.py          체결 기록(JSONL) + 승률/손익 통계
  notifier.py         텔레그램 알림
  cli.py              명령줄 인터페이스
```

테스트: `python -m pytest tests`

## 주의

- 투자 손실에 대한 책임은 사용자에게 있습니다. 이 코드는 수익을 보장하지 않습니다.
- 매도 손익은 주문 시점 호가로 추정한 값이며 실제 체결가와 다를 수 있습니다.
- 증권사 API는 초당 호출 수 제한이 있습니다(KIS 모의 약 2건/초, LS 차트 1건/초, DB 예수금 1건/초). 감시 종목이 많으면 `poll_seconds` 를 늘리세요.
- 모든 증권사 접근 토큰은 `~/.kr_stock_trader/` 에 캐시됩니다(KIS는 발급 1분 1회 제한). API 키는 절대 커밋하지 마세요.
