import os
import tempfile
import unittest
from pathlib import Path

from unittest.mock import patch

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
        main.app.state.push_error = None

    def test_requests_without_token_are_rejected(self):
        for method, path in [("GET", "/api/now"), ("GET", "/api/settings"),
                             ("PUT", "/api/settings"), ("POST", "/api/devices"),
                             ("GET", "/api/compare"), ("GET", "/api/costs"),
                             ("POST", "/api/notifications/test")]:
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

    def test_device_registration_warns_on_bundle_id_mismatch(self):
        push = FakeSender()
        push.topic = "io.qman.wattnu"
        self.use_senders({"push": push})
        token = "AB" * 32
        response = self.client.post("/api/devices", headers=AUTH, json={
            "token": token,
            "platform": "ios",
            "environment": "sandbox",
            "bundle_id": "io.qman.WattNu",
        })
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["registered"])
        self.assertIn("Bundle-ID komt niet overeen", response.json()["warning"])

    def test_costs_endpoint_calculates_summary_and_entries(self):
        self.store.update_settings({
            "price_import": 0.30,
            "price_import_offpeak": 0.20,
            "price_export": 0.05,
            "fixed_daily_cost": 1.00,
        })
        fake_summary = [{
            "day_kwh": 10.0, "day_peak_kwh": 6.0, "day_offpeak_kwh": 4.0,
            "day_export_kwh": 2.0, "day_days": 1,
            "week_kwh": 50.0, "week_peak_kwh": 30.0, "week_offpeak_kwh": 20.0,
            "week_export_kwh": 10.0, "week_days": 5,
            "month_kwh": 200.0, "month_peak_kwh": 100.0, "month_offpeak_kwh": 100.0,
            "month_export_kwh": 20.0, "month_days": 20,
            "year_kwh": 2400.0, "year_peak_kwh": 1200.0, "year_offpeak_kwh": 1200.0,
            "year_export_kwh": 400.0, "year_days": 300,
        }]
        fake_entries = [
            {"start": "2026-11-21T23:00:00Z", "local_date": "2026-11-22",
             "kwh_import": 12.0, "kwh_import_peak": 0.0, "kwh_import_offpeak": 12.0,
             "kwh_export": 4.0, "days_count": 1},
            {"start": "2026-11-22T23:00:00Z", "local_date": "2026-11-23",
             "kwh_import": 10.0, "kwh_import_peak": 6.0, "kwh_import_offpeak": 4.0,
             "kwh_export": 2.0, "days_count": 1},
        ]
        with patch.object(main, "query", side_effect=[fake_summary, fake_entries]):
            response = self.client.get("/api/costs?period=day&count=7", headers=AUTH)
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["period"], "day")
        self.assertEqual(data["price_import"], 0.30)
        self.assertEqual(data["price_import_offpeak"], 0.20)
        self.assertEqual(data["fixed_daily_cost"], 1.00)
        # day: 6*0.30 + 4*0.20 - 2*0.05 + 1*1.00 = 1.80 + 0.80 - 0.10 + 1.00 = 3.50
        self.assertEqual(data["summary"]["day"]["cost"], 3.50)
        # week: 30*0.30 + 20*0.20 - 10*0.05 + 5*1.00 = 9 + 4 - 0.5 + 5 = 17.50
        self.assertEqual(data["summary"]["week"]["cost"], 17.50)
        # month: 100*0.30 + 100*0.20 - 20*0.05 + 20*1.00 = 30 + 20 - 1 + 20 = 69.00
        self.assertEqual(data["summary"]["month"]["cost"], 69.00)
        # year: 1200*0.30 + 1200*0.20 - 400*0.05 + 300*1.00 = 360 + 240 - 20 + 300 = 880.00
        self.assertEqual(data["summary"]["year"]["cost"], 880.00)
        self.assertEqual(len(data["entries"]), 2)
        # Sunday entry: 12*0.20 - 4*0.05 + 1*1.00 = 2.40 - 0.20 + 1.00 = 3.20
        self.assertEqual(data["entries"][0]["cost"], 3.20)

    def test_costs_endpoint_rejects_invalid_period(self):
        response = self.client.get("/api/costs?period=decade", headers=AUTH)
        self.assertEqual(response.status_code, 422)


if __name__ == "__main__":
    unittest.main()
