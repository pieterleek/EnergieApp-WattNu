"""Telegrammeldingen, opslag en meldingsregels voor WattNu."""
from __future__ import annotations

import asyncio
import html
import logging
import os
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable
from zoneinfo import ZoneInfo

import httpx

logger = logging.getLogger(__name__)

PHASE_LIMIT_AMPS = 14.0
PHASE_RESET_AMPS = 13.0
PHASE_HOLD_DURATION = timedelta(minutes=1)
RETRY_AFTER = timedelta(minutes=5)
LOCAL_TZ = ZoneInfo("Europe/Amsterdam")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def _parse(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


def _number(value: float) -> str:
    return f"{value:.1f}".replace(".", ",")


def phase_direction(current: float | None, power: float | None) -> tuple[str, float] | None:
    """Bepaalt richting uit getekend vermogen; de SDM630-stroom is absoluut."""
    if current is None:
        return None
    amps = abs(float(current))
    return ("return" if power is not None and float(power) < 0 else "import", amps)


@dataclass(frozen=True)
class NotificationSettings:
    enabled: bool = False
    phase_alerts: bool = True
    stale_alerts: bool = True
    daily_limit_kwh: float | None = None
    pieter_mode: bool = True


@dataclass(frozen=True)
class AlertState:
    active: bool = False
    last_attempt_at: datetime | None = None
    condition_started_at: datetime | None = None


@dataclass(frozen=True)
class TelegramResult:
    sent: bool
    reason: str | None = None


class NotificationStore:
    """Lokale SQLite-opslag voor voorkeuren en ontdubbeling van alarmen."""

    def __init__(self, path: str):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS notification_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    enabled INTEGER NOT NULL,
                    phase_alerts INTEGER NOT NULL,
                    stale_alerts INTEGER NOT NULL,
                    daily_limit_kwh REAL,
                    pieter_mode INTEGER NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS alert_state (
                    alert_key TEXT PRIMARY KEY,
                    active INTEGER NOT NULL DEFAULT 0,
                    last_attempt_at TEXT,
                    last_sent_at TEXT,
                    condition_started_at TEXT,
                    updated_at TEXT NOT NULL
                );
            """)
            columns = {
                row["name"] for row in connection.execute("PRAGMA table_info(alert_state)")
            }
            if "condition_started_at" not in columns:
                connection.execute(
                    "ALTER TABLE alert_state ADD COLUMN condition_started_at TEXT"
                )

    def update_settings(self, values: dict) -> None:
        with self._connect() as connection:
            connection.execute("""
                INSERT INTO notification_settings (
                    id, enabled, phase_alerts, stale_alerts,
                    daily_limit_kwh, pieter_mode, updated_at
                ) VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    enabled = excluded.enabled,
                    phase_alerts = excluded.phase_alerts,
                    stale_alerts = excluded.stale_alerts,
                    daily_limit_kwh = excluded.daily_limit_kwh,
                    pieter_mode = excluded.pieter_mode,
                    updated_at = excluded.updated_at
            """, (
                int(values["enabled"]), int(values["phase_alerts"]),
                int(values["stale_alerts"]), values["daily_limit_kwh"],
                int(values["pieter_mode"]), _iso(_now()),
            ))

    def settings(self) -> NotificationSettings:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM notification_settings WHERE id = 1"
            ).fetchone()
        if row is None:
            return NotificationSettings()
        return NotificationSettings(
            enabled=bool(row["enabled"]),
            phase_alerts=bool(row["phase_alerts"]),
            stale_alerts=bool(row["stale_alerts"]),
            daily_limit_kwh=row["daily_limit_kwh"],
            pieter_mode=bool(row["pieter_mode"]),
        )

    def alert_state(self, key: str) -> AlertState:
        with self._connect() as connection:
            row = connection.execute("""
                SELECT active, last_attempt_at, condition_started_at
                FROM alert_state WHERE alert_key = ?
            """, (key,)).fetchone()
        if row is None:
            return AlertState()
        return AlertState(
            bool(row["active"]),
            _parse(row["last_attempt_at"]),
            _parse(row["condition_started_at"]),
        )

    def start_condition(self, key: str, started_at: datetime) -> None:
        stamp = _iso(started_at)
        with self._connect() as connection:
            connection.execute("""
                INSERT INTO alert_state (
                    alert_key, active, condition_started_at, updated_at
                ) VALUES (?, 0, ?, ?)
                ON CONFLICT(alert_key) DO UPDATE SET
                    condition_started_at = coalesce(
                        alert_state.condition_started_at,
                        excluded.condition_started_at
                    ),
                    updated_at = excluded.updated_at
            """, (key, stamp, stamp))

    def cancel_pending(self, key: str) -> None:
        with self._connect() as connection:
            connection.execute("""
                UPDATE alert_state
                SET condition_started_at = NULL, updated_at = ?
                WHERE alert_key = ? AND active = 0
            """, (_iso(_now()), key))

    def record_attempt(self, key: str, attempted_at: datetime) -> None:
        stamp = _iso(attempted_at)
        with self._connect() as connection:
            connection.execute("""
                INSERT INTO alert_state (alert_key, active, last_attempt_at, updated_at)
                VALUES (?, 0, ?, ?)
                ON CONFLICT(alert_key) DO UPDATE SET
                    last_attempt_at = excluded.last_attempt_at,
                    updated_at = excluded.updated_at
            """, (key, stamp, stamp))

    def mark_sent(self, key: str, sent_at: datetime) -> None:
        stamp = _iso(sent_at)
        with self._connect() as connection:
            connection.execute("""
                UPDATE alert_state
                SET active = 1, last_sent_at = ?, condition_started_at = NULL,
                    updated_at = ?
                WHERE alert_key = ?
            """, (stamp, stamp, key))

    def clear_alert(self, key: str) -> None:
        with self._connect() as connection:
            connection.execute("""
                UPDATE alert_state
                SET active = 0, last_attempt_at = NULL,
                    condition_started_at = NULL, updated_at = ?
                WHERE alert_key = ?
            """, (_iso(_now()), key))

    def prune_alerts(self) -> None:
        cutoff = _iso(_now() - timedelta(days=14))
        with self._connect() as connection:
            connection.execute("""
                DELETE FROM alert_state
                WHERE alert_key LIKE 'daily:%' AND updated_at < ?
            """, (cutoff,))


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

    async def send(self, title: str, body: str) -> TelegramResult:
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
            return TelegramResult(False, "Telegram niet bereikbaar")

        try:
            result = response.json()
        except ValueError:
            return TelegramResult(False, f"Telegram gaf HTTP {response.status_code}")
        if response.status_code == 200 and result.get("ok") is True:
            return TelegramResult(True)
        reason = result.get("description", f"Telegram gaf HTTP {response.status_code}")
        logger.warning("Telegram weigerde een melding: %s", reason)
        return TelegramResult(False, reason)

    async def close(self) -> None:
        await self._client.aclose()


class NotificationService:
    def __init__(
        self,
        store: NotificationStore,
        sender: TelegramSender,
        snapshot_provider: Callable[[], dict],
        interval_seconds: int = 15,
    ):
        self.store = store
        self.sender = sender
        self.snapshot_provider = snapshot_provider
        self.interval_seconds = interval_seconds
        self._task: asyncio.Task | None = None

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run(), name="energy-telegram-monitor")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        await self.sender.close()

    async def _run(self) -> None:
        while True:
            try:
                await self.check_once()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("Telegrammonitor kon de metingen niet verwerken")
            await asyncio.sleep(self.interval_seconds)

    async def check_once(self) -> None:
        settings = await asyncio.to_thread(self.store.settings)
        if not settings.enabled:
            return
        snapshot = await asyncio.to_thread(self.snapshot_provider)
        checked_at = _now()
        await self._evaluate(settings, snapshot, checked_at)
        await asyncio.to_thread(self.store.prune_alerts)

    async def send_test(self) -> TelegramResult:
        settings = await asyncio.to_thread(self.store.settings)
        body = (
            "De meldingen werken. Pieter heeft het gecontroleerd, dus dan weet je het wel."
            if settings.pieter_mode
            else "De meldingen voor je energiemeter werken."
        )
        return await self.sender.send("Testmelding", body)

    async def _evaluate(
        self,
        settings: NotificationSettings,
        snapshot: dict,
        checked_at: datetime,
    ) -> None:
        if settings.stale_alerts:
            if snapshot.get("stale", True):
                body = (
                    "De meter denkt al meer dan een minuut na. Dat is bovengemiddeld grondig."
                    if settings.pieter_mode
                    else "Er is al meer dan een minuut geen nieuwe meterdata ontvangen."
                )
                await self._trigger("meter-stale", "Geen nieuwe meterdata", body, checked_at)
            else:
                await asyncio.to_thread(self.store.clear_alert, "meter-stale")

        if snapshot.get("stale", True):
            for phase in ("L1", "L2", "L3"):
                for flow in ("import", "return"):
                    await asyncio.to_thread(
                        self.store.cancel_pending, f"phase:{phase}:{flow}"
                    )
            return

        if settings.phase_alerts:
            for phase in ("l1", "l2", "l3"):
                direction = phase_direction(
                    snapshot.get(f"current_{phase}"), snapshot.get(f"power_{phase}")
                )
                await self._evaluate_phase(phase.upper(), direction, settings.pieter_mode, checked_at)

        if settings.daily_limit_kwh is not None:
            usage = float(snapshot.get("today_kwh") or 0)
            if usage >= settings.daily_limit_kwh:
                day = checked_at.astimezone(LOCAL_TZ).date().isoformat()
                body = (
                    f"Vandaag staat op {_number(usage)} kWh. De limiet van "
                    f"{_number(settings.daily_limit_kwh)} kWh heeft het niet gered."
                    if settings.pieter_mode
                    else f"Vandaag is {_number(usage)} kWh verbruikt; je limiet is "
                         f"{_number(settings.daily_limit_kwh)} kWh."
                )
                await self._trigger(f"daily:{day}", "Daglimiet bereikt", body, checked_at)

    async def _evaluate_phase(
        self,
        phase: str,
        direction: tuple[str, float] | None,
        pieter_mode: bool,
        checked_at: datetime,
    ) -> None:
        import_key = f"phase:{phase}:import"
        return_key = f"phase:{phase}:return"
        if direction is None:
            await asyncio.to_thread(self.store.clear_alert, import_key)
            await asyncio.to_thread(self.store.clear_alert, return_key)
            return

        flow, amps = direction
        if amps < PHASE_RESET_AMPS:
            await asyncio.to_thread(self.store.clear_alert, import_key)
            await asyncio.to_thread(self.store.clear_alert, return_key)
            return

        if flow == "return":
            await asyncio.to_thread(self.store.clear_alert, import_key)
            if amps < PHASE_LIMIT_AMPS:
                await asyncio.to_thread(self.store.cancel_pending, return_key)
                return
            body = (
                f"{phase} levert {_number(amps)} A terug. De meter heeft de achteruit gevonden."
                if pieter_mode
                else f"{phase} levert {_number(amps)} A terug; de grens is 14 ampère."
            )
            await self._trigger_after_hold(
                return_key, f"14 ampère retour op {phase}", body, checked_at
            )
        else:
            await asyncio.to_thread(self.store.clear_alert, return_key)
            if amps < PHASE_LIMIT_AMPS:
                await asyncio.to_thread(self.store.cancel_pending, import_key)
                return
            body = (
                f"{phase} trekt {_number(amps)} A. De elektronen hebben hun pauze overgeslagen."
                if pieter_mode
                else f"{phase} gebruikt {_number(amps)} A; de grens is 14 ampère."
            )
            await self._trigger_after_hold(
                import_key, f"14 ampère op {phase}", body, checked_at
            )

    async def _trigger_after_hold(
        self,
        key: str,
        title: str,
        body: str,
        checked_at: datetime,
    ) -> None:
        state = await asyncio.to_thread(self.store.alert_state, key)
        if state.active:
            return
        if state.condition_started_at is None:
            await asyncio.to_thread(self.store.start_condition, key, checked_at)
            return
        if checked_at - state.condition_started_at < PHASE_HOLD_DURATION:
            return
        await self._trigger(key, title, body, checked_at)

    async def _trigger(self, key: str, title: str, body: str, checked_at: datetime) -> None:
        state = await asyncio.to_thread(self.store.alert_state, key)
        if state.active:
            return
        if state.last_attempt_at and checked_at - state.last_attempt_at < RETRY_AFTER:
            return

        await asyncio.to_thread(self.store.record_attempt, key, checked_at)
        result = await self.sender.send(title, body)
        if result.sent:
            await asyncio.to_thread(self.store.mark_sent, key, checked_at)
