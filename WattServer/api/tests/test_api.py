import os
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("API_TOKEN", "test-token")
os.environ.setdefault("DATABASE_DSN", "host=127.0.0.1 port=1 dbname=none connect_timeout=1")

from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402
from notifications import NotificationService, NotificationStore, SendResult  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}


class FakeSender:
    def __init__(self, result=SendResult(True)):
        self.result = result
        self.notifications = []

    async def send(self, title, body):
        self.notifications.append((title, body))
        return self.result

    async def close(self):
        pass


class ApiTests(unittest.TestCase):
    """Alles wat zonder database werkt: toegang, instellingen, apparaten, tests."""

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = NotificationStore(
            str(Path(self.temporary_directory.name) / "notifications.sqlite3")
        )
        self.use_senders({})
        self.client = TestClient(main.app)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def use_senders(self, senders):
        main.app.state.notification_store = self.store
        main.app.state.notification_service = NotificationService(
            self.store, senders, lambda: {"stale": True}
        )

    def test_requests_without_token_are_rejected(self):
        for method, path in [("GET", "/api/now"), ("GET", "/api/settings"),
                             ("PUT", "/api/settings"), ("POST", "/api/devices"),
                             ("GET", "/api/compare"), ("POST", "/api/notifications/test")]:
            with self.subTest(path=path):
                self.assertEqual(self.client.request(method, path).status_code, 401)
        wrong = {"Authorization": "Bearer nope"}
        self.assertEqual(self.client.get("/api/settings", headers=wrong).status_code, 401)

    def test_health_needs_no_token_and_reports_database_failure(self):
        response = self.client.get("/api/health")
        self.assertEqual(response.status_code, 503)

    def test_settings_round_trip(self):
        initial = self.client.get("/api/settings", headers=AUTH).json()
        self.assertFalse(initial["settings"]["enabled"])
        self.assertEqual(initial["channels"],
                         {"telegram": False, "push": False, "push_devices": 0})

        body = {**initial["settings"], "enabled": True, "phase_limit_amps": 22,
                "phase_hold_seconds": 30, "price_import": 0.27}
        saved = self.client.put("/api/settings", headers=AUTH, json=body)
        self.assertEqual(saved.status_code, 200)

        again = self.client.get("/api/settings", headers=AUTH).json()["settings"]
        self.assertTrue(again["enabled"])
        self.assertEqual(again["phase_limit_amps"], 22)
        self.assertEqual(again["phase_hold_seconds"], 30)
        self.assertEqual(again["price_import"], 0.27)
        self.assertIsNone(again["price_export"])

    def test_omitted_optional_values_are_cleared(self):
        self.store.update_settings({"daily_limit_kwh": 20, "price_import": 0.3})
        self.client.put("/api/settings", headers=AUTH, json={"enabled": True})
        current = self.store.settings()
        self.assertIsNone(current.daily_limit_kwh)
        self.assertIsNone(current.price_import)

    def test_invalid_settings_are_refused(self):
        for body in [{"phase_limit_amps": 0}, {"phase_hold_seconds": -1},
                     {"voltage_min": 240, "voltage_max": 230}, {"price_import": -1}]:
            with self.subTest(body=body):
                response = self.client.put("/api/settings", headers=AUTH, json=body)
                self.assertEqual(response.status_code, 422)

    def test_legacy_telegram_settings_keep_new_fields(self):
        self.store.update_settings({"phase_limit_amps": 20, "push_enabled": False})
        self.use_senders({"telegram": FakeSender()})
        response = self.client.put("/api/telegram/settings", headers=AUTH, json={
            "enabled": True, "phase_alerts": True, "stale_alerts": False,
            "daily_limit_kwh": None, "pieter_mode": False,
        })
        self.assertEqual(response.json(), {"configured": True})
        current = self.store.settings()
        self.assertTrue(current.enabled)
        self.assertFalse(current.stale_alerts)
        self.assertEqual(current.phase_limit_amps, 20.0)
        self.assertFalse(current.push_enabled)

    def test_device_registration(self):
        token = "AB" * 32
        body = {"token": token, "platform": "ios", "environment": "sandbox"}
        response = self.client.post("/api/devices", headers=AUTH, json=body)
        self.assertEqual(response.json(), {"registered": True, "configured": False})
        self.assertEqual(self.store.devices()[0].token, token.lower())

        bad = self.client.post("/api/devices", headers=AUTH,
                               json={**body, "token": "zz" * 32})
        self.assertEqual(bad.status_code, 422)
        bad = self.client.post("/api/devices", headers=AUTH,
                               json={**body, "platform": "android"})
        self.assertEqual(bad.status_code, 422)

        self.client.delete(f"/api/devices/{token}", headers=AUTH)
        self.assertEqual(self.store.devices(), [])

    def test_test_notification_per_channel(self):
        response = self.client.post("/api/notifications/test", headers=AUTH)
        self.assertEqual(response.status_code, 503)

        telegram = FakeSender()
        push = FakeSender(SendResult(False, "APNs: BadDeviceToken"))
        self.use_senders({"telegram": telegram, "push": push})

        both = self.client.post("/api/notifications/test", headers=AUTH)
        self.assertEqual(both.json(), {"sent": {"telegram": True, "push": False}})

        only_push = self.client.post("/api/notifications/test?channel=push", headers=AUTH)
        self.assertEqual(only_push.status_code, 502)
        self.assertEqual(only_push.json()["detail"], "APNs: BadDeviceToken")

        legacy = self.client.post("/api/telegram/test", headers=AUTH)
        self.assertEqual(legacy.json(), {"sent": True})
        self.assertEqual(len(telegram.notifications), 2)


if __name__ == "__main__":
    unittest.main()
