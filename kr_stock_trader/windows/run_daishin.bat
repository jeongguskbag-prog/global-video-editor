@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion
rem ===== 대신증권 CYBOS Plus 자동매매 실행기 =====
rem 1) CYBOS Plus 를 먼저 실행해 로그인 (모의투자는 '모의투자 접속' 선택)
rem 2) 이 파일을 마우스 오른쪽 버튼 → '관리자 권한으로 실행'

net session > nul 2>&1
if errorlevel 1 (
  echo [오류] 관리자 권한이 필요합니다. 이 파일을 마우스 오른쪽 버튼으로 눌러 '관리자 권한으로 실행' 하세요.
  pause
  exit /b 1
)

cd /d "%~dp0\..\.."
set PY=py -3-32
%PY% -c "import struct,sys; sys.exit(0 if struct.calcsize('P')==4 else 1)" > nul 2>&1
if errorlevel 1 (
  echo [오류] 32비트 Python 이 필요합니다. python.org 에서 'Windows installer (32-bit)' 를 설치하세요.
  pause
  exit /b 1
)

%PY% -m pip install -q -r kr_stock_trader\requirements-windows.txt
if not exist config.json copy kr_stock_trader\config.example.json config.json > nul

:menu
echo.
echo  1. 잔고 조회
echo  2. 현재가 조회
echo  3. 자동매매 시작 (모의투자)
echo  4. 자동매매 시작 (실전 - 실제 주문이 나갑니다)
echo  5. 거래 기록
echo  0. 종료
set /p CHOICE=번호를 입력하세요: 
if "%CHOICE%"=="1" %PY% -m kr_stock_trader -c config.json --broker daishin balance
if "%CHOICE%"=="2" (
  set /p CODE=종목코드 6자리: 
  %PY% -m kr_stock_trader -c config.json --broker daishin quote !CODE!
)
if "%CHOICE%"=="3" %PY% -m kr_stock_trader -c config.json --broker daishin --env demo run
if "%CHOICE%"=="4" (
  set /p OK=실전 계좌로 주문합니다. 계속하려면 YES 입력: 
  if /i "!OK!"=="YES" %PY% -m kr_stock_trader -c config.json --broker daishin --env real run --live
)
if "%CHOICE%"=="5" %PY% -m kr_stock_trader -c config.json history
if "%CHOICE%"=="0" exit /b 0
goto menu
