"""Meldingsregels, voorkeuren en ontdubbeling voor WattNu.

De regels zijn kanaalonafhankelijk: Telegram en Apple-push krijgen dezelfde
melding. Een alarm geldt als verstuurd zodra minstens één kanaal het aannam.
"""
from __future__ import annotations

import asyncio
import logging
import sqlite3
from contextlib import contextmanager
from dataclasses import asdict, dataclass, fields
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Iterator, Protocol
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)

PHASE_RESET_MARGIN_AMPS = 1.0
VOLTAGE_RESET_MARGIN = 2.0
VOLTAGE_HOLD = timedelta(minutes=1)
FREQUENCY_MIN_HZ = 49.8
FREQUENCY_MAX_HZ = 50.2
FREQUENCY_RESET_MARGIN = 0.05
FREQUENCY_HOLD = timedelta(minutes=1)
RETRY_AFTER = timedelta(minutes=5)
LOCAL_TZ = ZoneInfo("Europe/Amsterdam")
PHASES = ("L1", "L2", "L3")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def _parse(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


def _number(value: float) -> str:
    return f"{value:.1f}".replace(".", ",")


def _compact(value: float) -> str:
    """14.0 wordt '14', 14.5 wordt '14,5'."""
    return f"{value:g}".replace(".", ",")


def phase_direction(current: float | None, power: float | None) -> tuple[str, float] | None:
    """Bepaalt richting uit getekend vermogen; de SDM630-stroom is absoluut."""
    if current is None:
        return None
    amps = abs(float(current))
    return ("return" if power is not None and float(power) < 0 else "import", amps)


@dataclass(frozen=True)
class NotificationSettings:
    enabled: bool = False
    telegram_enabled: bool = True
    push_enabled: bool = True
    phase_alerts: bool = True
    phase_limit_amps: float = 14.0
    phase_hold_seconds: int = 60
    stale_alerts: bool = True
    daily_limit_kwh: float | None = None
    voltage_alerts: bool = False
    voltage_min: float = 207.0
    voltage_max: float = 253.0
    frequency_alerts: bool = False
    pieter_mode: bool = True
    price_import: float | None = None
    price_export: float | None = None

    def as_dict(self) -> dict:
        return asdict(self)


# Kolomdefinities voor de instellingentabel; ontbrekende kolommen worden bij het
# starten toegevoegd, zodat een bestaande database gewoon blijft werken.
_SETTINGS_COLUMNS = {
    "enabled": "INTEGER NOT NULL DEFAULT 0",
    "telegram_enabled": "INTEGER NOT NULL DEFAULT 1",
    "push_enabled": "INTEGER NOT NULL DEFAULT 1",
    "phase_alerts": "INTEGER NOT NULL DEFAULT 1",
    "phase_limit_amps": "REAL NOT NULL DEFAULT 14",
    "phase_hold_seconds": "INTEGER NOT NULL DEFAULT 60",
    "stale_alerts": "INTEGER NOT NULL DEFAULT 1",
    "daily_limit_kwh": "REAL",
    "voltage_alerts": "INTEGER NOT NULL DEFAULT 0",
    "voltage_min": "REAL NOT NULL DEFAULT 207",
    "voltage_max": "REAL NOT NULL DEFAULT 253",
    "frequency_alerts": "INTEGER NOT NULL DEFAULT 0",
    "pieter_mode": "INTEGER NOT NULL DEFAULT 1",
    "price_import": "REAL",
    "price_export": "REAL",
}
_FIELD_TYPES = {field.name: field.type for field in fields(NotificationSettings)}


def _from_storage(name: str, value):
    kind = _FIELD_TYPES[name]
    if value is None:
        return None
    if kind == "bool":
        return bool(value)
    if kind == "int":
        return int(value)
    return float(value)


def _to_storage(name: str, value):
    if value is None:
        return None
    return int(value) if _FIELD_TYPES[name] in ("bool", "int") else float(value)


@dataclass(frozen=True)
class AlertState:
    active: bool = False
    last_attempt_at: datetime | None = None
    condition_started_at: datetime | None = None


@dataclass(frozen=True)
class SendResult:
    sent: bool
    reason: str | None = None


@dataclass(frozen=True)
class PushDevice:
    token: str
    platform: str
    environment: str


class Sender(Protocol):
    async def send(self, title: str, body: str) -> SendResult: ...

    async def close(self) -> None: ...


class NotificationStore:
    """Lokale SQLite-opslag voor voorkeuren, apparaten en ontdubbeling van alarmen."""

    def __init__(self, path: str):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        """Eén transactie per blok; de verbinding wordt daarna echt gesloten."""
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        try:
            with connection:
                yield connection
        finally:
            connection.close()

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
                CREATE TABLE IF NOT EXISTS push_devices (
                    token TEXT PRIMARY KEY,
                    platform TEXT NOT NULL,
                    environment TEXT NOT NULL,
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
            existing = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(notification_settings)")
            }
            for name, definition in _SETTINGS_COLUMNS.items():
                if name not in existing:
                    connection.execute(
                        f"ALTER TABLE notification_settings ADD COLUMN {name} {definition}"
                    )

    # -- Voorkeuren ---------------------------------------------------------

    def settings(self) -> NotificationSettings:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM notification_settings WHERE id = 1"
            ).fetchone()
        if row is None:
            return NotificationSettings()
        return NotificationSettings(
            **{name: _from_storage(name, row[name]) for name in _SETTINGS_COLUMNS}
        )

    def update_settings(self, values: dict) -> NotificationSettings:
        """Werkt de genoemde velden bij; niet genoemde velden blijven staan."""
        merged = {**self.settings().as_dict(), **{
            name: value for name, value in values.items() if name in _SETTINGS_COLUMNS
        }}
        names = list(_SETTINGS_COLUMNS)
        placeholders = ", ".join("?" for _ in names)
        assignments = ", ".join(f"{name} = excluded.{name}" for name in names)
        with self._connect() as connection:
            connection.execute(
                f"""
                INSERT INTO notification_settings (id, {", ".join(names)}, updated_at)
                VALUES (1, {placeholders}, ?)
                ON CONFLICT(id) DO UPDATE SET {assignments},
                    updated_at = excluded.updated_at
                """,
                (*(_to_storage(name, merged[name]) for name in names), _iso(_now())),
            )
        return self.settings()

    # -- Apparaten voor Apple-push -----------------------------------------

    def register_device(self, token: str, platform: str, environment: str) -> None:
        with self._connect() as connection:
            connection.execute("""
                INSERT INTO push_devices (token, platform, environment, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(token) DO UPDATE SET
                    platform = excluded.platform,
                    environment = excluded.environment,
                    updated_at = excluded.updated_at
            """, (token, platform, environment, _iso(_now())))

    def remove_device(self, token: str) -> None:
        with self._connect() as connection:
            connection.execute("DELETE FROM push_devices WHERE token = ?", (token,))

    def devices(self) -> list[PushDevice]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT token, platform, environment FROM push_devices ORDER BY updated_at"
            ).fetchall()
        return [PushDevice(row["token"], row["platform"], row["environment"]) for row in rows]

    # -- Alarmstatus --------------------------------------------------------

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


class NotificationService:
    """Beoordeelt elke paar seconden de laatste meting en verstuurt meldingen."""

    def __init__(
        self,
        store: NotificationStore,
        senders: dict[str, Sender],
        snapshot_provider: Callable[[], dict],
        interval_seconds: int = 15,
    ):
        self.store = store
        self.senders = senders
        self.snapshot_provider = snapshot_provider
        self.interval_seconds = interval_seconds
        self._task: asyncio.Task | None = None

    def start(self) -> None:
        if self._task is None and self.senders:
            self._task = asyncio.create_task(self._run(), name="energy-notification-monitor")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        for sender in self.senders.values():
            await sender.close()

    async def _run(self) -> None:
        while True:
            try:
                await self.check_once()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("Meldingenmonitor kon de metingen niet verwerken")
            await asyncio.sleep(self.interval_seconds)

    async def check_once(self) -> None:
        settings = await asyncio.to_thread(self.store.settings)
        if not settings.enabled or not self._active_senders(settings):
            return
        snapshot = await asyncio.to_thread(self.snapshot_provider)
        checked_at = _now()
        await self._evaluate(settings, snapshot, checked_at)
        await asyncio.to_thread(self.store.prune_alerts)

    def _active_senders(self, settings: NotificationSettings) -> dict[str, Sender]:
        allowed = {"telegram": settings.telegram_enabled, "push": settings.push_enabled}
        return {
            name: sender for name, sender in self.senders.items() if allowed.get(name, True)
        }

    async def send_test(self, channel: str | None = None) -> dict[str, SendResult]:
        """Stuurt een testmelding naar één kanaal of naar alle geconfigureerde kanalen."""
        settings = await asyncio.to_thread(self.store.settings)
        body = (
            "De meldingen werken. Pieter heeft het gecontroleerd, dus dan weet je het wel."
            if settings.pieter_mode
            else "De meldingen voor je energiemeter werken."
        )
        targets = {
            name: sender for name, sender in self.senders.items()
            if channel is None or name == channel
        }
        return {name: await sender.send("Testmelding", body) for name, sender in targets.items()}

    async def _evaluate(
        self,
        settings: NotificationSettings,
        snapshot: dict,
        checked_at: datetime,
    ) -> None:
        stale = snapshot.get("stale", True)
        if settings.stale_alerts:
            if stale:
                body = (
                    "De meter denkt al meer dan een minuut na. Dat is bovengemiddeld grondig."
                    if settings.pieter_mode
                    else "Er is al meer dan een minuut geen nieuwe meterdata ontvangen."
                )
                await self._trigger(
                    "meter-stale", "Geen nieuwe meterdata", body, checked_at, settings
                )
            else:
                await asyncio.to_thread(self.store.clear_alert, "meter-stale")

        if stale:
            # Zonder verse meting mag geen wachttijd doorlopen.
            pending = [f"phase:{phase}:{flow}" for phase in PHASES for flow in ("import", "return")]
            pending += [f"voltage:{phase}:{side}" for phase in PHASES for side in ("high", "low")]
            pending += ["frequency:high", "frequency:low"]
            for key in pending:
                await asyncio.to_thread(self.store.cancel_pending, key)
            return

        if settings.phase_alerts:
            for phase in PHASES:
                suffix = phase.lower()
                direction = phase_direction(
                    snapshot.get(f"current_{suffix}"), snapshot.get(f"power_{suffix}")
                )
                await self._evaluate_phase(phase, direction, settings, checked_at)

        if settings.voltage_alerts:
            for phase in PHASES:
                await self._evaluate_voltage(
                    phase, snapshot.get(f"voltage_{phase.lower()}"), settings, checked_at
                )

        if settings.frequency_alerts:
            await self._evaluate_frequency(snapshot.get("frequency"), settings, checked_at)

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
                await self._trigger(
                    f"daily:{day}", "Daglimiet bereikt", body, checked_at, settings
                )

    async def _evaluate_phase(
        self,
        phase: str,
        direction: tuple[str, float] | None,
        settings: NotificationSettings,
        checked_at: datetime,
    ) -> None:
        import_key = f"phase:{phase}:import"
        return_key = f"phase:{phase}:return"
        limit = settings.phase_limit_amps
        hold = timedelta(seconds=settings.phase_hold_seconds)
        limit_text = _compact(limit)
        if direction is None:
            await asyncio.to_thread(self.store.clear_alert, import_key)
            await asyncio.to_thread(self.store.clear_alert, return_key)
            return

        flow, amps = direction
        if amps < limit - PHASE_RESET_MARGIN_AMPS:
            await asyncio.to_thread(self.store.clear_alert, import_key)
            await asyncio.to_thread(self.store.clear_alert, return_key)
            return

        if flow == "return":
            await asyncio.to_thread(self.store.clear_alert, import_key)
            if amps < limit:
                await asyncio.to_thread(self.store.cancel_pending, return_key)
                return
            body = (
                f"{phase} levert {_number(amps)} A terug. De meter heeft de achteruit gevonden."
                if settings.pieter_mode
                else f"{phase} levert {_number(amps)} A terug; de grens is {limit_text} ampère."
            )
            await self._trigger_after_hold(
                return_key, f"{limit_text} ampère retour op {phase}", body,
                checked_at, hold, settings,
            )
        else:
            await asyncio.to_thread(self.store.clear_alert, return_key)
            if amps < limit:
                await asyncio.to_thread(self.store.cancel_pending, import_key)
                return
            body = (
                f"{phase} trekt {_number(amps)} A. De elektronen hebben hun pauze overgeslagen."
                if settings.pieter_mode
                else f"{phase} gebruikt {_number(amps)} A; de grens is {limit_text} ampère."
            )
            await self._trigger_after_hold(
                import_key, f"{limit_text} ampère op {phase}", body,
                checked_at, hold, settings,
            )

    async def _evaluate_band(
        self,
        key_prefix: str,
        value: float | None,
        low: float,
        high: float,
        margin: float,
        hold: timedelta,
        messages: Callable[[str, float], tuple[str, str]],
        settings: NotificationSettings,
        checked_at: datetime,
    ) -> None:
        """Alarm als een waarde een minuut buiten [low, high] blijft, met hysterese."""
        high_key = f"{key_prefix}:high"
        low_key = f"{key_prefix}:low"
        if value is None:
            await asyncio.to_thread(self.store.clear_alert, high_key)
            await asyncio.to_thread(self.store.clear_alert, low_key)
            return
        value = float(value)

        if value >= high:
            title, body = messages("high", value)
            await self._trigger_after_hold(high_key, title, body, checked_at, hold, settings)
        elif value < high - margin:
            await asyncio.to_thread(self.store.clear_alert, high_key)
        else:
            await asyncio.to_thread(self.store.cancel_pending, high_key)

        if value <= low:
            title, body = messages("low", value)
            await self._trigger_after_hold(low_key, title, body, checked_at, hold, settings)
        elif value > low + margin:
            await asyncio.to_thread(self.store.clear_alert, low_key)
        else:
            await asyncio.to_thread(self.store.cancel_pending, low_key)

    async def _evaluate_voltage(
        self,
        phase: str,
        voltage: float | None,
        settings: NotificationSettings,
        checked_at: datetime,
    ) -> None:
        def messages(side: str, value: float) -> tuple[str, str]:
            volts = f"{value:.0f}"
            if side == "high":
                limit = _compact(settings.voltage_max)
                body = (
                    f"{phase} staat op {volts} V. Het net doet enthousiast; je omvormer straks minder."
                    if settings.pieter_mode
                    else f"{phase} staat op {volts} V; de bovengrens is {limit} V."
                )
                return f"Hoge spanning op {phase}", body
            limit = _compact(settings.voltage_min)
            body = (
                f"{phase} staat op {volts} V. Dat is minder stopcontact dan afgesproken."
                if settings.pieter_mode
                else f"{phase} staat op {volts} V; de ondergrens is {limit} V."
            )
            return f"Lage spanning op {phase}", body

        await self._evaluate_band(
            f"voltage:{phase}", voltage, settings.voltage_min, settings.voltage_max,
            VOLTAGE_RESET_MARGIN, VOLTAGE_HOLD, messages, settings, checked_at,
        )

    async def _evaluate_frequency(
        self,
        frequency: float | None,
        settings: NotificationSettings,
        checked_at: datetime,
    ) -> None:
        def messages(side: str, value: float) -> tuple[str, str]:
            hertz = f"{value:.2f}".replace(".", ",")
            body = (
                f"Het net tikt op {hertz} Hz. Europa loopt even uit de maat."
                if settings.pieter_mode
                else f"De netfrequentie is {hertz} Hz; normaal is 49,8 tot 50,2 Hz."
            )
            return ("Hoge netfrequentie" if side == "high" else "Lage netfrequentie"), body

        await self._evaluate_band(
            "frequency", frequency, FREQUENCY_MIN_HZ, FREQUENCY_MAX_HZ,
            FREQUENCY_RESET_MARGIN, FREQUENCY_HOLD, messages, settings, checked_at,
        )

    async def _trigger_after_hold(
        self,
        key: str,
        title: str,
        body: str,
        checked_at: datetime,
        hold: timedelta,
        settings: NotificationSettings,
    ) -> None:
        state = await asyncio.to_thread(self.store.alert_state, key)
        if state.active:
            return
        if hold > timedelta(0):
            if state.condition_started_at is None:
                await asyncio.to_thread(self.store.start_condition, key, checked_at)
                return
            if checked_at - state.condition_started_at < hold:
                return
        await self._trigger(key, title, body, checked_at, settings)

    async def _trigger(
        self,
        key: str,
        title: str,
        body: str,
        checked_at: datetime,
        settings: NotificationSettings,
    ) -> None:
        state = await asyncio.to_thread(self.store.alert_state, key)
        if state.active:
            return
        if state.last_attempt_at and checked_at - state.last_attempt_at < RETRY_AFTER:
            return

        await asyncio.to_thread(self.store.record_attempt, key, checked_at)
        delivered = False
        for name, sender in self._active_senders(settings).items():
            try:
                result = await sender.send(title, body)
            except Exception:
                logger.exception("Kanaal %s kon de melding niet versturen", name)
                continue
            delivered = delivered or result.sent
        if delivered:
            await asyncio.to_thread(self.store.mark_sent, key, checked_at)
