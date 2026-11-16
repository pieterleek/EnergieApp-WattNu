import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from apns import ApnsSender, valid_device_token
from notifications import NotificationStore

IOS = "a" * 64
MAC = "b" * 64


class FakeResponse:
    def __init__(self, status_code=200, reason=None):
        self.status_code = status_code
        self._reason = reason

    def json(self):
        if self._reason is None:
            raise ValueError("leeg")
        return {"reason": self._reason}


class CaptureClient:
    def __init__(self, responses=None):
        self.requests = []
        self.responses = responses or {}

    async def post(self, url, json, headers):
        self.requests.append((url, json, headers))
        return self.responses.get(url.rsplit("/", 1)[1], FakeResponse())

    async def aclose(self):
        pass


class ApnsSenderTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = NotificationStore(
            str(Path(self.temporary_directory.name) / "notifications.sqlite3")
        )
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.pem = self.key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ).decode()
        self.clock = datetime(2026, 1, 1, tzinfo=timezone.utc)

    async def asyncTearDown(self):
        self.temporary_directory.cleanup()

    def sender(self, client):
        return ApnsSender(
            self.store, self.pem, "KEYID12345", "TEAMID1234", "io.qman.wattnu",
            client=client, now=lambda: self.clock,
        )

    async def test_without_devices_nothing_is_sent(self):
        client = CaptureClient()
        result = await self.sender(client).send("Titel", "Tekst")
        self.assertFalse(result.sent)
        self.assertEqual(client.requests, [])

    async def test_request_targets_environment_and_carries_signed_token(self):
        self.store.register_device(IOS, "ios", "sandbox")
        self.store.register_device(MAC, "macos", "production")
        client = CaptureClient()

        result = await self.sender(client).send("14 ampère op L1", "L1 gebruikt 14,2 A")

        self.assertTrue(result.sent)
        urls = sorted(url for url, _, _ in client.requests)
        self.assertEqual(urls, [
            f"https://api.push.apple.com/3/device/{MAC}",
            f"https://api.sandbox.push.apple.com/3/device/{IOS}",
        ])
        _, payload, headers = client.requests[0]
        self.assertEqual(payload["aps"]["alert"],
                         {"title": "14 ampère op L1", "body": "L1 gebruikt 14,2 A"})
        self.assertEqual(headers["apns-topic"], "io.qman.wattnu")
        self.assertEqual(headers["apns-push-type"], "alert")
        token = headers["authorization"].removeprefix("bearer ")
        self.assertEqual(jwt.get_unverified_header(token)["kid"], "KEYID12345")
        claims = jwt.decode(token, self.key.public_key(), algorithms=["ES256"],
                            options={"verify_iat": False})
        self.assertEqual(claims["iss"], "TEAMID1234")

    async def test_provider_token_is_reused_then_refreshed(self):
        self.store.register_device(IOS, "ios", "production")
        client = CaptureClient()
        sender = self.sender(client)
        await sender.send("a", "b")
        self.clock += timedelta(minutes=10)
        await sender.send("a", "b")
        self.clock += timedelta(minutes=40)
        await sender.send("a", "b")
        tokens = [headers["authorization"] for _, _, headers in client.requests]
        self.assertEqual(tokens[0], tokens[1])
        self.assertNotEqual(tokens[1], tokens[2])

    async def test_unregistered_device_is_removed_and_other_still_counts(self):
        self.store.register_device(IOS, "ios", "production")
        self.store.register_device(MAC, "macos", "production")
        client = CaptureClient({IOS: FakeResponse(410, "Unregistered")})

        result = await self.sender(client).send("a", "b")

        self.assertTrue(result.sent)
        self.assertEqual([device.token for device in self.store.devices()], [MAC])

    async def test_rejection_keeps_device_and_reports_reason(self):
        self.store.register_device(IOS, "ios", "production")
        client = CaptureClient({IOS: FakeResponse(429, "TooManyRequests")})

        result = await self.sender(client).send("a", "b")

        self.assertFalse(result.sent)
        self.assertEqual(result.reason, "APNs: TooManyRequests")
        self.assertEqual(len(self.store.devices()), 1)

    async def test_unusable_key_does_not_raise(self):
        self.store.register_device(IOS, "ios", "production")
        sender = ApnsSender(self.store, "geen sleutel", "K", "T", "io.qman.wattnu",
                            client=CaptureClient())
        result = await sender.send("a", "b")
        self.assertFalse(result.sent)

    def test_device_token_validation(self):
        self.assertTrue(valid_device_token("0f" * 32))
        self.assertFalse(valid_device_token("0f" * 31))
        self.assertFalse(valid_device_token("zz" * 32))
        self.assertFalse(valid_device_token("0f" * 32 + "/../x"))


if __name__ == "__main__":
    unittest.main()
