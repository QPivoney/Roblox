"""Optional trade/alert notifications via Discord and/or Telegram webhooks.
Both are no-ops if their config values are left blank."""
from __future__ import annotations

import logging

import requests

logger = logging.getLogger(__name__)


class Notifier:
    def __init__(self, discord_webhook_url: str = "", telegram_bot_token: str = "", telegram_chat_id: str = ""):
        self.discord_webhook_url = discord_webhook_url
        self.telegram_bot_token = telegram_bot_token
        self.telegram_chat_id = telegram_chat_id

    def send(self, message: str) -> None:
        if self.discord_webhook_url:
            try:
                requests.post(self.discord_webhook_url, json={"content": message[:1900]}, timeout=5)
            except Exception:
                logger.exception("Discord notify failed")
        if self.telegram_bot_token and self.telegram_chat_id:
            try:
                requests.post(
                    f"https://api.telegram.org/bot{self.telegram_bot_token}/sendMessage",
                    json={"chat_id": self.telegram_chat_id, "text": message[:4000]},
                    timeout=5,
                )
            except Exception:
                logger.exception("Telegram notify failed")
