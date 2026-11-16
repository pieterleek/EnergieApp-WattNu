"""Telegram als meldingskanaal voor WattNu."""
from __future__ import annotations

import html
import logging
import os

import httpx

from notifications import SendResult

logger = logging.getLogger(__name__)


class TelegramSender:
    def __init__(self, bot_token: str, chat_id: str):
        self.bot_token = bot_token
        self.chat_id = chat_id
        self._client = httpx.AsyncClient(timeout=10)

    @classmethod
    def from_environment(cls) -> TelegramSender | None:
        token = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
        chat_id = os.getenv("TELEGRAM_CHAT_ID", "").strip()
        if not token or not chat_id:
            logger.warning(
                "Telegrammeldingen uitgeschakeld: TELEGRAM_BOT_TOKEN of TELEGRAM_CHAT_ID ontbreekt"
            )
            return None
        return cls(token, chat_id)

    async def send(self, title: str, body: str) -> SendResult:
        text = f"<b>{html.escape(title)}</b>\n{html.escape(body)}"
        try:
            response = await self._client.post(
                f"https://api.telegram.org/bot{self.bot_token}/sendMessage",
                json={
                    "chat_id": self.chat_id,
                    "text": text,
                    "parse_mode": "HTML",
                },
            )
        except httpx.HTTPError as error:
            # Log nooit de fout-URL: daarin staat het geheime bottoken.
            logger.warning("Telegram is tijdelijk niet bereikbaar (%s)", type(error).__name__)
            return SendResult(False, "Telegram niet bereikbaar")

        try:
            result = response.json()
        except ValueError:
            return SendResult(False, f"Telegram gaf HTTP {response.status_code}")
        if response.status_code == 200 and result.get("ok") is True:
            return SendResult(True)
        reason = result.get("description", f"Telegram gaf HTTP {response.status_code}")
        logger.warning("Telegram weigerde een melding: %s", reason)
        return SendResult(False, reason)

    async def close(self) -> None:
        await self._client.aclose()
