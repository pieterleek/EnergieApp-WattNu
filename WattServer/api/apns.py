"""Apple Push Notification service als meldingskanaal voor WattNu.

Gebruikt tokenauthenticatie: een .p8-sleutel uit het Apple Developer-account
ondertekent een kortlevend JWT. Apple eist HTTP/2.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

import httpx
import jwt

from notifications import NotificationStore, PushDevice, SendResult

logger = logging.getLogger(__name__)

APNS_HOSTS = {
    "production": "https://api.push.apple.com",
    "sandbox": "https://api.sandbox.push.apple.com",
}
# Apple weigert tokens ouder dan een uur en straft te vaak vernieuwen af.
PROVIDER_TOKEN_LIFETIME = timedelta(minutes=45)
# Bij deze redenen komt het apparaat nooit meer terug en mag het token weg.
# DeviceTokenNotForTopic wijst meestal op een verkeerde APNS_BUNDLE_ID op de
# server, dus daarbij laten we het token staan en geven we een duidelijke melding.
DEAD_DEVICE_REASONS = {"BadDeviceToken", "Unregistered"}
DEVICE_TOKEN_PATTERN = re.compile(r"^[0-9a-f]{64,200}$")


def valid_device_token(token: str) -> bool:
    return bool(DEVICE_TOKEN_PATTERN.fullmatch(token))


class ApnsSender:
    def __init__(
        self,
        store: NotificationStore,
        private_key: str,
        key_id: str,
        team_id: str,
        topic: str,
        client=None,
        now: Callable[[], datetime] | None = None,
    ):
        self.store = store
        self.topic = topic
        self._private_key = private_key
        self._key_id = key_id
        self._team_id = team_id
        self._client = client or httpx.AsyncClient(http2=True, timeout=10)
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._provider_token: tuple[datetime, str] | None = None

    @classmethod
    def diagnose_environment(cls) -> str | None:
        """Geeft een leesbare oorzaak terug als APNs niet gestart kan worden, anders None."""
        key_file = os.getenv("APNS_KEY_FILE", "").strip()
        key_id = os.getenv("APNS_KEY_ID", "").strip()
        team_id = os.getenv("APNS_TEAM_ID", "").strip()
        topic = os.getenv("APNS_BUNDLE_ID", "").strip()
        missing = [
            name for name, value in (
                ("APNS_KEY_FILE", key_file),
                ("APNS_KEY_ID", key_id),
                ("APNS_TEAM_ID", team_id),
                ("APNS_BUNDLE_ID", topic),
            )
            if not value
        ]
        if missing:
            return f"Ontbrekend in .env op de Pi: {', '.join(missing)}"
        path = Path(key_file)
        if not path.exists():
            return f"APNs-sleutelbestand niet gevonden ({key_file})"
        try:
            content = path.read_text()
        except PermissionError:
            return f"Geen leesrechten op {key_file} (gebruik chmod 644)"
        except OSError as error:
            return f"APNs-sleutelbestand niet leesbaar ({type(error).__name__})"
        if "PRIVATE KEY" not in content:
            return f"APNs-sleutelbestand ({key_file}) bevat geen geldige .p8-sleutel"
        return None

    @classmethod
    def from_environment(cls, store: NotificationStore) -> ApnsSender | None:
        issue = cls.diagnose_environment()
        if issue:
            logger.warning("Apple-push uitgeschakeld: %s", issue)
            return None
        key_file = os.getenv("APNS_KEY_FILE", "").strip()
        key_id = os.getenv("APNS_KEY_ID", "").strip()
        team_id = os.getenv("APNS_TEAM_ID", "").strip()
        topic = os.getenv("APNS_BUNDLE_ID", "").strip()
        private_key = Path(key_file).read_text()
        return cls(store, private_key, key_id, team_id, topic)

    def _bearer(self) -> str:
        current = self._now()
        if self._provider_token and current - self._provider_token[0] < PROVIDER_TOKEN_LIFETIME:
            return self._provider_token[1]
        token = jwt.encode(
            {"iss": self._team_id, "iat": int(current.timestamp())},
            self._private_key,
            algorithm="ES256",
            headers={"kid": self._key_id},
        )
        self._provider_token = (current, token)
        return token

    async def send(self, title: str, body: str) -> SendResult:
        devices = await asyncio.to_thread(self.store.devices)
        if not devices:
            return SendResult(False, "Geen apparaten aangemeld voor pushmeldingen")
        try:
            bearer = self._bearer()
        except Exception as error:
            logger.warning("APNs-sleutel is onbruikbaar (%s)", type(error).__name__)
            return SendResult(False, "APNs-sleutel is onbruikbaar")

        payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}}
        results = await asyncio.gather(
            *(self._send_to(device, bearer, payload) for device in devices)
        )
        if any(result.sent for result in results):
            return SendResult(True)
        return SendResult(False, next(r.reason for r in results if not r.sent))

    async def _send_to(self, device: PushDevice, bearer: str, payload: dict) -> SendResult:
        host = APNS_HOSTS.get(device.environment, APNS_HOSTS["production"])
        try:
            response = await self._client.post(
                f"{host}/3/device/{device.token}",
                json=payload,
                headers={
                    "authorization": f"bearer {bearer}",
                    "apns-topic": self.topic,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                },
            )
        except httpx.HTTPError as error:
            # Log de URL niet: daarin staat het apparaattoken.
            logger.warning("APNs is tijdelijk niet bereikbaar (%s)", type(error).__name__)
            return SendResult(False, "APNs niet bereikbaar")

        if response.status_code == 200:
            return SendResult(True)
        try:
            reason = response.json().get("reason", "")
        except ValueError:
            reason = ""
        reason = reason or f"HTTP {response.status_code}"
        if response.status_code == 410 or reason in DEAD_DEVICE_REASONS:
            await asyncio.to_thread(self.store.remove_device, device.token)
            logger.info(
                "Verlopen apparaat verwijderd uit pushlijst (%s, omgeving=%s, topic=%s)",
                reason, device.environment, self.topic,
            )
        elif reason == "DeviceTokenNotForTopic":
            logger.warning(
                "APNs weigerde melding: DeviceTokenNotForTopic — controleer of APNS_BUNDLE_ID (%s) exact overeenkomt met de app",
                self.topic,
            )
            return SendResult(
                False,
                f"APNs: DeviceTokenNotForTopic (controleer APNS_BUNDLE_ID={self.topic} in .env)",
            )
        elif response.status_code == 403:
            self._provider_token = None
            logger.warning("APNs weigerde de aanmelding: %s", reason)
        else:
            logger.warning("APNs weigerde een melding (%s, omgeving=%s): %s",
                           device.platform, device.environment, reason)
        return SendResult(False, f"APNs: {reason}")

    async def close(self) -> None:
        await self._client.aclose()
