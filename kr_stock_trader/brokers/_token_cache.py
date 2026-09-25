"""접근 토큰 파일 캐시. KIS 는 토큰 발급이 1분 1회로 제한되어 재사용이 필수다."""

import hashlib
import json
import os
import time

CACHE_DIR = os.path.expanduser(os.environ.get("KR_TRADER_CACHE_DIR", "~/.kr_stock_trader"))


def _path(namespace: str, app_key: str) -> str:
    digest = hashlib.sha256(app_key.encode()).hexdigest()[:12]
    return os.path.join(CACHE_DIR, f"token_{namespace}_{digest}.json")


def load(namespace: str, app_key: str):
    try:
        with open(_path(namespace, app_key), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if data.get("expires_at", 0) - 300 > time.time():  # 5분 여유
        return data.get("token")
    return None


def save(namespace: str, app_key: str, token: str, expires_at: float) -> None:
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = _path(namespace, app_key)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"token": token, "expires_at": expires_at}, f)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
