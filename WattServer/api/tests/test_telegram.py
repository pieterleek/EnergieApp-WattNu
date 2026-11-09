import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from telegram import (
    NotificationService,
    NotificationStore,
    TelegramResult,
    TelegramSender,
    phase_direction,
)


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


class FakeSender:
    def __init__(self):
        self.notifications = []

    async def send(self, title, body):
        self.notifications.append((title, body))
        return TelegramResult(True)

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


class TelegramRuleTests(unittest.IsolatedAsyncioTestCase):
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
        self.service = NotificationService(self.store, self.sender, lambda: self.snapshot)

    async def asyncTearDown(self):
        self.temporary_directory.cleanup()

    async def test_phase_only_notifies_after_one_minute_until_below_thirteen_amps(self):
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        direction = ("import", 14.2)

        await self.service._evaluate_phase("L1", direction, False, started)
        await self.service._evaluate_phase(
            "L1", direction, False, started + timedelta(seconds=59)
        )
        self.assertEqual(len(self.sender.notifications), 0)

        await self.service._evaluate_phase(
            "L1", direction, False, started + timedelta(seconds=60)
        )
        await self.service._evaluate_phase(
            "L1", direction, False, started + timedelta(seconds=75)
        )
        self.assertEqual(len(self.sender.notifications), 1)
        self.assertEqual(self.sender.notifications[0][0], "14 ampère op L1")

        await self.service._evaluate_phase(
            "L1", ("import", 12.9), False, started + timedelta(seconds=76)
        )
        await self.service._evaluate_phase(
            "L1", direction, False, started + timedelta(seconds=77)
        )
        await self.service._evaluate_phase(
            "L1", direction, False, started + timedelta(seconds=137)
        )
        self.assertEqual(len(self.sender.notifications), 2)

    async def test_short_phase_peak_restarts_the_minute(self):
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        await self.service._evaluate_phase("L1", ("import", 14.5), False, started)
        await self.service._evaluate_phase(
            "L1", ("import", 13.8), False, started + timedelta(seconds=45)
        )
        await self.service._evaluate_phase(
            "L1", ("import", 14.5), False, started + timedelta(seconds=50)
        )
        await self.service._evaluate_phase(
            "L1", ("import", 14.5), False, started + timedelta(seconds=109)
        )
        self.assertEqual(len(self.sender.notifications), 0)

        await self.service._evaluate_phase(
            "L1", ("import", 14.5), False, started + timedelta(seconds=110)
        )
        self.assertEqual(len(self.sender.notifications), 1)

    async def test_negative_phase_power_sends_return_notification(self):
        started = datetime(2026, 1, 1, tzinfo=timezone.utc)
        direction = ("return", 14.2)
        await self.service._evaluate_phase("L1", direction, False, started)
        await self.service._evaluate_phase(
            "L1", direction, False, started + timedelta(minutes=1)
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


if __name__ == "__main__":
    unittest.main()
