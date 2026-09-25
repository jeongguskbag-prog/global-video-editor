"""텔레그램 알림. 토큰/채팅 ID 가 없으면 아무것도 하지 않는다."""

import logging

import requests

log = logging.getLogger(__name__)


class TelegramNotifier:
    def __init__(self, bot_token: str = "", chat_id: str = "", session=None):
        self.bot_token, self.chat_id = bot_token, chat_id
        self.session = session or requests.Session()

    @property
    def enabled(self) -> bool:
        return bool(self.bot_token and self.chat_id)

    def send(self, text: str) -> None:
        if not self.enabled:
            return
        try:
            self.session.post(
                f"https://api.telegram.org/bot{self.bot_token}/sendMessage",
                json={"chat_id": self.chat_id, "text": text},
                timeout=10,
            )
        except requests.RequestException as e:
            log.warning("텔레그램 전송 실패: %s", e)
