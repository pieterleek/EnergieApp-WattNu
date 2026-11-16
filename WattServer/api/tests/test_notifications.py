import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from notifications import (
    NotificationService,
    NotificationSettings,
    NotificationStore,
    SendResult,
    phase_direction,
)
from telegram import TelegramSender


def settings(**overrides) -> dict:
    values = {
        "enabled": True,
        "phase_alerts": True,
        "stale_alerts": True,
        "daily_limit_kwh": None,
        "pieter_mode": False,
    }
    values.update(overrides)
    return values


PLAIN = NotificationSettings(enabled=True, pieter_mode=False)


class FakeSender:
    def __init__(self):
        self.notifications = []

    async def send(self, title, body):
        self.notifications.append((title, body))
        return SendResult(True)

    async def close(self):
        pass


class FakeResponse:
    status_code = 200

    @staticmethod
    def json():
        return {"ok": True}


class CaptureClient:
    def __init__(self):
        self.url = None
        self.payload = None

    async def post(self, url, json):
        self.url = url
        self.payload = json
        return FakeResponse()

    async def aclose(self):
        pass


class PhaseDirectionTests(unittest.TestCase):
    def test_positive_power_is_import(self):
        self.assertEqual(phase_direction(10.5, 2400), ("import", 10.5))

    def test_negative_power_is_return(self):
        self.assertEqual(phase_direction(10.5, -2400), ("return", 10.5))

    def test_current_is_treated_as_absolute(self):
        self.assertEqual(phase_direction(-11, -2500), ("return", 11.0))


class TelegramSenderTests(unittest.IsolatedAsyncioTestCase):
    async def test_send_message_escapes_html_and_targets_chat(self):
        sender = TelegramSender("secret-token", "12345")
        client = CaptureClient()
        sender._client = client

        result = await sender.send("14 ampère < L1", "Pieter & de meter")

        self.assertTrue(result.sent)
        self.assertTrue(client.url.endswith("/botsecret-token/sendMessage"))
        self.assertEqual(client.payload["chat_id"], "12345")
        self.assertIn("14 ampère &lt; L1", client.payload["text"])
        self.assertIn("Pieter &amp; de meter", client.payload["text"])


class NotificationStoreMigrationTests(unittest.TestCase):
    def test_existing_alert_database_gets_hold_timer_column(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "notifications.sqlite3"
            with sqlite3.connect(database) as connection:
                connection.execute("""
                    CREATE TABLE alert_state (
                        alert_key TEXT PRIMARY KEY,
                        active INTEGER NOT NULL DEFAULT 0,
                        last_attempt_at TEXT,
                        last_sent_at TEXT,
                        updated_at TEXT NOT NULL
                    )
                """)

            NotificationStore(str(database))

            with sqlite3.connect(database) as connection:
                columns = {
                    row[1] for row in connection.execute("PRAGMA table_info(alert_state)")
                }
            self.assertIn("condition_started_at", columns)


class NotificationRuleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        database = Path(self.temporary_directory.name) / "notifications.sqlite3"
        self.store = NotificationStore(str(database))
        self.store.update_settings(settings())
        self.sender = FakeSender()
        self.snapshot = {
            "stale": False,
            "today_kwh": 4.0,
            "current_l1": 14.2,
            "power_l1": 2300.0,
            "current_l2": 2.0,
            "power_l2": 400.0,
            "current_l3": 3.0,
            "power_l3": 600.0,
        }
        self.service = NotificationService(
            self.store, {"telegram": self.sender}, lambda: self.snapshot
        )

    async def asyncTearDown(self):
        self.temporary_directory.cleanup()

    async def test_phase_only_notifies_after_one_minute_until_below_thirteen_amps(self):
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        direction = ("import", 14.2)

        await self.service._evaluate_phase("L1", direction, PLAIN, started)
        await self.service._evaluate_phase(
            "L1", direction, PLAIN, started + timedelta(seconds=59)
        )
        self.assertEqual(len(self.sender.notifications), 0)

        await self.service._evaluate_phase(
            "L1", direction, PLAIN, started + timedelta(seconds=60)
        )
        await self.service._evaluate_phase(
            "L1", direction, PLAIN, started + timedelta(seconds=75)
        )
        self.assertEqual(len(self.sender.notifications), 1)
        self.assertEqual(self.sender.notifications[0][0], "14 ampère op L1")

        await self.service._evaluate_phase(
            "L1", ("import", 12.9), PLAIN, started + timedelta(seconds=76)
        )
        await self.service._evaluate_phase(
            "L1", direction, PLAIN, started + timedelta(seconds=77)
        )
        await self.service._evaluate_phase(
            "L1", direction, PLAIN, started + timedelta(seconds=137)
        )
        self.assertEqual(len(self.sender.notifications), 2)

    async def test_short_phase_peak_restarts_the_minute(self):
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        await self.service._evaluate_phase("L1", ("import", 14.5), PLAIN, started)
        await self.service._evaluate_phase(
            "L1", ("import", 13.8), PLAIN, started + timedelta(seconds=45)
        )
        await self.service._evaluate_phase(
            "L1", ("import", 14.5), PLAIN, started + timedelta(seconds=50)
        )
        await self.service._evaluate_phase(
            "L1", ("import", 14.5), PLAIN, started + timedelta(seconds=109)
        )
        self.assertEqual(len(self.sender.notifications), 0)

        await self.service._evaluate_phase(
            "L1", ("import", 14.5), PLAIN, started + timedelta(seconds=110)
        )
        self.assertEqual(len(self.sender.notifications), 1)

    async def test_negative_phase_power_sends_return_notification(self):
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        direction = ("return", 14.2)
        await self.service._evaluate_phase("L1", direction, PLAIN, started)
        await self.service._evaluate_phase(
            "L1", direction, PLAIN, started + timedelta(minutes=1)
        )
        self.assertEqual(self.sender.notifications[0][0], "14 ampère retour op L1")

    async def test_stale_notification_is_deduplicated(self):
        self.snapshot["stale"] = True
        await self.service.check_once()
        await self.service.check_once()
        self.assertEqual(len(self.sender.notifications), 1)
        self.assertEqual(self.sender.notifications[0][0], "Geen nieuwe meterdata")

    async def test_daily_limit_is_once_per_local_day(self):
        self.store.update_settings(settings(phase_alerts=False, daily_limit_kwh=3.0))
        await self.service.check_once()
        await self.service.check_once()
        self.assertEqual(len(self.sender.notifications), 1)
        self.assertEqual(self.sender.notifications[0][0], "Daglimiet bereikt")

    async def test_phase_limit_and_hold_time_are_configurable(self):
        custom = NotificationSettings(
            enabled=True, pieter_mode=False, phase_limit_amps=20, phase_hold_seconds=10
        )
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        await self.service._evaluate_phase("L2", ("import", 19.5), custom, started)
        await self.service._evaluate_phase(
            "L2", ("import", 19.5), custom, started + timedelta(minutes=5)
        )
        self.assertEqual(len(self.sender.notifications), 0)

        await self.service._evaluate_phase("L2", ("import", 20.5), custom, started)
        await self.service._evaluate_phase(
            "L2", ("import", 20.5), custom, started + timedelta(seconds=10)
        )
        self.assertEqual(self.sender.notifications[0][0], "20 ampère op L2")
        self.assertIn("de grens is 20 ampère", self.sender.notifications[0][1])

    async def test_zero_hold_time_notifies_immediately(self):
        custom = NotificationSettings(enabled=True, pieter_mode=False, phase_hold_seconds=0)
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        await self.service._evaluate_phase("L1", ("import", 15.0), custom, started)
        self.assertEqual(len(self.sender.notifications), 1)

    async def test_high_voltage_notifies_after_a_minute_with_hysteresis(self):
        custom = NotificationSettings(enabled=True, pieter_mode=False, voltage_alerts=True)
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        await self.service._evaluate_voltage("L3", 254.0, custom, started)
        self.assertEqual(len(self.sender.notifications), 0)
        await self.service._evaluate_voltage(
            "L3", 254.0, custom, started + timedelta(seconds=60)
        )
        self.assertEqual(self.sender.notifications[0][0], "Hoge spanning op L3")

        # 252 V ligt binnen de hysterese: nog geen nieuw alarm mogelijk.
        await self.service._evaluate_voltage(
            "L3", 252.0, custom, started + timedelta(seconds=70)
        )
        await self.service._evaluate_voltage(
            "L3", 254.0, custom, started + timedelta(seconds=200)
        )
        self.assertEqual(len(self.sender.notifications), 1)

        await self.service._evaluate_voltage(
            "L3", 240.0, custom, started + timedelta(seconds=210)
        )
        await self.service._evaluate_voltage(
            "L3", 254.0, custom, started + timedelta(seconds=220)
        )
        await self.service._evaluate_voltage(
            "L3", 254.0, custom, started + timedelta(seconds=280)
        )
        self.assertEqual(len(self.sender.notifications), 2)

    async def test_low_voltage_and_frequency_alerts(self):
        custom = NotificationSettings(
            enabled=True, pieter_mode=False, voltage_alerts=True, frequency_alerts=True
        )
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        later = started + timedelta(seconds=60)
        await self.service._evaluate_voltage("L1", 200.0, custom, started)
        await self.service._evaluate_voltage("L1", 200.0, custom, later)
        await self.service._evaluate_frequency(50.0, custom, started)
        await self.service._evaluate_frequency(50.0, custom, later)
        await self.service._evaluate_frequency(49.7, custom, started)
        await self.service._evaluate_frequency(49.7, custom, later)
        titles = [title for title, _ in self.sender.notifications]
        self.assertEqual(titles, ["Lage spanning op L1", "Lage netfrequentie"])

    async def test_voltage_alerts_are_off_by_default(self):
        self.snapshot.update(current_l1=1.0, voltage_l1=260.0, voltage_l2=230.0, voltage_l3=230.0)
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        await self.service._evaluate(self.store.settings(), self.snapshot, started)
        await self.service._evaluate(
            self.store.settings(), self.snapshot, started + timedelta(minutes=2)
        )
        self.assertEqual(len(self.sender.notifications), 0)

    async def test_alert_goes_to_every_enabled_channel(self):
        push = FakeSender()
        self.service.senders["push"] = push
        self.snapshot["stale"] = True
        await self.service.check_once()
        self.assertEqual(len(self.sender.notifications), 1)
        self.assertEqual(len(push.notifications), 1)

    async def test_disabled_channel_is_skipped(self):
        push = FakeSender()
        self.service.senders["push"] = push
        self.store.update_settings({"telegram_enabled": False})
        self.snapshot["stale"] = True
        await self.service.check_once()
        self.assertEqual(len(self.sender.notifications), 0)
        self.assertEqual(len(push.notifications), 1)

    async def test_alert_is_retried_when_every_channel_fails(self):
        class FailingSender(FakeSender):
            async def send(self, title, body):
                self.notifications.append((title, body))
                return SendResult(False, "kapot")

        failing = FailingSender()
        self.service.senders = {"telegram": failing}
        current = PLAIN
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        await self.service._trigger("k", "t", "b", started, current)
        await self.service._trigger("k", "t", "b", started + timedelta(minutes=1), current)
        self.assertEqual(len(failing.notifications), 1)
        await self.service._trigger("k", "t", "b", started + timedelta(minutes=5), current)
        self.assertEqual(len(failing.notifications), 2)


class SettingsStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary_directory.name) / "notifications.sqlite3"

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_defaults_before_anything_is_saved(self):
        current = NotificationStore(str(self.database)).settings()
        self.assertFalse(current.enabled)
        self.assertEqual(current.phase_limit_amps, 14.0)
        self.assertEqual(current.phase_hold_seconds, 60)

    def test_partial_update_keeps_other_fields(self):
        store = NotificationStore(str(self.database))
        store.update_settings({"enabled": True, "phase_limit_amps": 20, "price_import": 0.28})
        store.update_settings({"enabled": False, "unknown": 1})
        current = store.settings()
        self.assertFalse(current.enabled)
        self.assertEqual(current.phase_limit_amps, 20.0)
        self.assertEqual(current.price_import, 0.28)
        self.assertIsNone(current.daily_limit_kwh)

    def test_existing_settings_row_survives_new_columns(self):
        with sqlite3.connect(self.database) as connection:
            connection.execute("""
                CREATE TABLE notification_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    enabled INTEGER NOT NULL,
                    phase_alerts INTEGER NOT NULL,
                    stale_alerts INTEGER NOT NULL,
                    daily_limit_kwh REAL,
                    pieter_mode INTEGER NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """)
            connection.execute(
                "INSERT INTO notification_settings VALUES (1, 1, 0, 1, 12.5, 0, 'x')"
            )

        current = NotificationStore(str(self.database)).settings()

        self.assertTrue(current.enabled)
        self.assertFalse(current.phase_alerts)
        self.assertEqual(current.daily_limit_kwh, 12.5)
        self.assertFalse(current.pieter_mode)
        self.assertEqual(current.phase_limit_amps, 14.0)
        self.assertTrue(current.push_enabled)
        self.assertEqual(current.voltage_max, 253.0)

    def test_devices_are_registered_once_and_removed(self):
        store = NotificationStore(str(self.database))
        store.register_device("a" * 64, "ios", "sandbox")
        store.register_device("a" * 64, "ios", "production")
        store.register_device("b" * 64, "macos", "production")
        self.assertEqual(
            [(d.token[0], d.environment) for d in store.devices()],
            [("a", "production"), ("b", "production")],
        )
        store.remove_device("a" * 64)
        self.assertEqual(len(store.devices()), 1)


if __name__ == "__main__":
    unittest.main()
