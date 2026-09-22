# Repo orientation (read this first)

This repo (`jeongguskbag-prog/global-video-editor`) currently holds two unrelated things:

- `app.py`, `requirements.txt`, `Dockerfile` — a FastAPI video translator/dubbing service.
- `flutter_app/` — a Flutter prototype called "Global Futures Terminal" (crypto futures
  trading UI). This is the active target for any "선물 거래 터미널 앱 / Flutter futures
  trading app" work in this session.

## Important: don't confuse this with `global_crypto_terminal`

A separate GitHub repo, `jeongguskbag-prog/global_crypto_terminal`, exists and was the
subject of a large amount of earlier work in this same long-running session (candlestick
charts, a full `AutoTradeEngine`, biometric app-lock, background trading service, l10n,
Android/Windows CI, live order execution groundwork, etc.). **That work lives in that
other repo, not here.** `flutter_app/` in *this* repo started independently, from a much
smaller ~859-line single-file prototype, and should be treated as its own project — do
not assume the `global_crypto_terminal` feature set already exists here, and do not
re-ask the user which repo to use unless something is genuinely ambiguous. If asked to
continue "the trading app," default to `flutter_app/` in this repo unless the user
explicitly says otherwise.

## Current state of `flutter_app/`

- `lib/main.dart` — manual trading UI: multi-exchange WebSocket ticker (Binance/Bybit/
  Bitget/OKX/Gate.io), a credit-cost paywall stub (`CreditCostEngine`), and a local-only
  license check stub (`AntiTamperLicenseVault`, trust-on-first-use, no backend).
- `lib/trading_engine.dart` — a **demo/paper-trading** auto-trade engine: a stateless
  5/20 SMA-crossover strategy over public Binance futures klines, with multi-coin
  scanning (`AutoTradeEngine(symbols: [...])` scans all candidates while flat, locks
  onto one symbol once a position opens). No real exchange order execution — it
  simulates a virtual balance only.
- `test/trading_engine_test.dart` — unit tests for the pure PnL/sizing functions and the
  crossover strategy.
- No `android/`, `ios/`, or `web/` platform folders are scaffolded yet, so
  `flutter build ...` isn't available as a check — use `flutter analyze` and
  `flutter test` to verify changes.
- Known limitations (see `flutter_app/README.md`): no real payment integration, no
  server-side license verification, no live exchange order API integration.
