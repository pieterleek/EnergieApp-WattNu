import unittest
from datetime import datetime, timedelta, timezone

from grid_load import GridLoadClient


class FakeResponse:
    def raise_for_status(self):
        pass

    def json(self):
        return {
            "interval_minutes": 15,
            "license": "CC BY 4.0",
            "data": [
                {"timestamp": "2026-11-09T09:15:00+01:00", "values": {"load": 12001.04}},
                {"timestamp": "2026-11-09T09:00:00+01:00", "values": {"load": 11800.0}},
                {"timestamp": "2026-11-09T09:30:00+01:00", "values": {"Solar": 12.0}},
            ],
        }


class FakeClient:
    def __init__(self):
        self.calls = []

    def get(self, url, params):
        self.calls.append((url, params))
        return FakeResponse()


class GridLoadClientTests(unittest.TestCase):
    def setUp(self):
        self.current_time = datetime(2026, 11, 9, 8, tzinfo=timezone.utc)
        self.http = FakeClient()
        self.client = GridLoadClient(self.http, lambda: self.current_time)

    def test_parses_only_load_points_and_sorts_them(self):
        result = self.client.get(7)

        self.assertEqual(self.http.calls[0][1], {
            "country": "nl", "start": "2026-11-02", "end": "2026-11-09"
        })
        self.assertEqual([point["load_mw"] for point in result["points"]], [11800.0, 12001.0])
        self.assertEqual(result["interval_minutes"], 15)
        self.assertFalse(result["stale"])

    def test_reuses_result_for_fifteen_minutes(self):
        first = self.client.get(1)
        self.current_time += timedelta(minutes=14)
        second = self.client.get(1)

        self.assertEqual(len(self.http.calls), 1)
        self.assertEqual(first["points"], second["points"])

