import tempfile
import unittest
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

        result = await sender.send("10 A < L1", "Pieter & de meter")

        self.assertTrue(result.sent)
        self.assertTrue(client.url.endswith("/botsecret-token/sendMessage"))
        self.assertEqual(client.payload["chat_id"], "12345")
        self.assertIn("10 A &lt; L1", client.payload["text"])
        self.assertIn("Pieter &amp; de meter", client.payload["text"])


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
            "current_l1": 10.2,
            "power_l1": 2300.0,
            "current_l2": 2.0,
            "power_l2": 400.0,
            "current_l3": 3.0,
            "power_l3": 600.0,
        }
        self.service = NotificationService(self.store, self.sender, lambda: self.snapshot)

    async def asyncTearDown(self):
        self.temporary_directory.cleanup()

    async def test_phase_only_notifies_once_until_below_nine_amps(self):
        await self.service.check_once()
        await self.service.check_once()
        self.assertEqual(len(self.sender.notifications), 1)
        self.assertEqual(self.sender.notifications[0][0], "10 A op L1")

        self.snapshot["current_l1"] = 8.9
        await self.service.check_once()
        self.snapshot["current_l1"] = 10.1
        await self.service.check_once()
        self.assertEqual(len(self.sender.notifications), 2)

    async def test_negative_phase_power_sends_return_notification(self):
        self.snapshot["power_l1"] = -2300.0
        await self.service.check_once()
        self.assertEqual(self.sender.notifications[0][0], "10 A retour op L1")

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
