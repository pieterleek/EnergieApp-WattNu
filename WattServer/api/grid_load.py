"""Nederlandse netbelasting uit de openbare Energy-Charts API."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from threading import Lock
from typing import Callable

import httpx


ENERGY_CHARTS_URL = "https://api.energy-charts.info/v2/public_power"


class GridLoadError(RuntimeError):
    """De externe netbelasting kon niet worden opgehaald of gelezen."""


class GridLoadClient:
    def __init__(
        self,
        client=None,
        now: Callable[[], datetime] | None = None,
        cache_duration: timedelta = timedelta(minutes=15),
    ):
        self._client = client or httpx.Client(timeout=12, follow_redirects=True)
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._cache_duration = cache_duration
        self._cache: dict[int, tuple[datetime, dict]] = {}
        self._lock = Lock()

    def get(self, days: int) -> dict:
        current_time = self._now().astimezone(timezone.utc)
        with self._lock:
            cached = self._cache.get(days)
            if cached and current_time - cached[0] < self._cache_duration:
                return {**cached[1], "stale": False}

        start = (current_time - timedelta(days=days)).date().isoformat()
        end = current_time.date().isoformat()
        try:
            response = self._client.get(
                ENERGY_CHARTS_URL,
                params={"country": "nl", "start": start, "end": end},
            )
            response.raise_for_status()
            result = self._parse(response.json(), current_time, current_time - timedelta(days=days))
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as error:
            with self._lock:
                cached = self._cache.get(days)
            if cached:
                return {**cached[1], "stale": True}
            raise GridLoadError("Nederlandse netbelasting is tijdelijk niet beschikbaar") from error

        with self._lock:
            self._cache[days] = (current_time, result)
        return result

    @staticmethod
    def _parse(payload: dict, generated_at: datetime, cutoff: datetime) -> dict:
        points = []
        for row in payload["data"]:
            load = row.get("values", {}).get("load")
            timestamp = row.get("timestamp")
            if load is None or timestamp is None:
                continue
            moment = datetime.fromisoformat(timestamp).astimezone(timezone.utc)
            if moment < cutoff:
                continue
            points.append({
                "time": moment.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "load_mw": round(float(load), 1),
            })

        if not points:
            raise ValueError("Geen netbelasting in antwoord")
        points.sort(key=lambda point: point["time"])
        return {
            "generated_at": generated_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "interval_minutes": int(payload.get("interval_minutes", 15)),
            "source": "Energy-Charts.info · ENTSO-E/TenneT",
            "license": payload.get("license", "CC BY 4.0"),
            "stale": False,
            "points": points,
        }

