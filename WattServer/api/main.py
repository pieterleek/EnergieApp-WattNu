"""API voor WattNu: metingen lezen, meldingen instellen."""
import hmac
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field, model_validator
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from apns import ApnsSender, valid_device_token
from grid_load import GridLoadClient, GridLoadError
from notifications import NotificationService, NotificationStore
from telegram import TelegramSender

API_TOKEN = os.environ["API_TOKEN"]
STALE_AFTER = timedelta(seconds=60)
LOCAL_TZ = "Europe/Amsterdam"
# Sluipverbruik: het rustigste deel van de nacht, lokale tijd.
BASELOAD_HOURS = (0, 5)

pool = ConnectionPool(os.environ["DATABASE_DSN"], min_size=1, max_size=4, open=False,
                      kwargs={"row_factory": dict_row, "autocommit": True})
grid_load_client = GridLoadClient()


@asynccontextmanager
async def lifespan(application: FastAPI):
    pool.open()
    store = NotificationStore(os.getenv("NOTIFICATION_DB_PATH", "/data/notifications.sqlite3"))
    senders = {}
    if telegram := TelegramSender.from_environment():
        senders["telegram"] = telegram
    if push := ApnsSender.from_environment(store):
        senders["push"] = push
    service = NotificationService(store, senders, now)
    application.state.notification_store = store
    application.state.notification_service = service
    service.start()
    try:
        yield
    finally:
        await service.stop()
        pool.close()


def require_token(authorization: str = Header(default="")) -> None:
    if not hmac.compare_digest(authorization.encode(), f"Bearer {API_TOKEN}".encode()):
        raise HTTPException(status_code=401, detail="Ongeldig token")


app = FastAPI(title="WattNu", lifespan=lifespan, docs_url=None, redoc_url=None,
              openapi_url=None)
api = APIRouter(prefix="/api", dependencies=[Depends(require_token)])


class Settings(BaseModel):
    """Alle gedeelde voorkeuren; de server is de bron van waarheid."""
    enabled: bool = False
    telegram_enabled: bool = True
    push_enabled: bool = True
    phase_alerts: bool = True
    phase_limit_amps: float = Field(default=14, ge=1, le=100)
    phase_hold_seconds: int = Field(default=60, ge=0, le=3600)
    stale_alerts: bool = True
    daily_limit_kwh: float | None = Field(default=None, gt=0, le=10_000)
    voltage_alerts: bool = False
    voltage_min: float = Field(default=207, ge=150, le=240)
    voltage_max: float = Field(default=253, ge=220, le=280)
    frequency_alerts: bool = False
    pieter_mode: bool = True
    price_import: float | None = Field(default=None, ge=0, le=10)
    price_export: float | None = Field(default=None, ge=0, le=10)

    @model_validator(mode="after")
    def voltage_band_is_ordered(self):
        if self.voltage_min >= self.voltage_max:
            raise ValueError("voltage_min moet lager zijn dan voltage_max")
        return self


class LegacyTelegramSettings(BaseModel):
    """Vorm van vóór de gedeelde instellingen; oudere appversies sturen dit nog."""
    enabled: bool = True
    phase_alerts: bool = True
    stale_alerts: bool = True
    daily_limit_kwh: float | None = Field(default=None, gt=0, le=10_000)
    pieter_mode: bool = True


class Device(BaseModel):
    token: str = Field(min_length=64, max_length=200)
    platform: Literal["ios", "macos"]
    environment: Literal["sandbox", "production"]


def clean(row: dict) -> dict:
    """Tijden als ISO 8601 in UTC, getallen compact."""
    result = {}
    for key, value in row.items():
        if isinstance(value, datetime):
            value = value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        elif isinstance(value, float):
            value = round(value, 3)
        result[key] = value
    return result


def query(sql: str, params: tuple = ()) -> list[dict]:
    with pool.connection() as conn:
        return [clean(row) for row in conn.execute(sql, params).fetchall()]


def store() -> NotificationStore:
    return app.state.notification_store


def service() -> NotificationService:
    return app.state.notification_service


def settings_response() -> dict:
    return {
        "settings": store().settings().as_dict(),
        "channels": {
            "telegram": "telegram" in service().senders,
            "push": "push" in service().senders,
            "push_devices": len(store().devices()),
        },
    }


@app.get("/api/health")
def health() -> dict:
    """Zonder token, voor de Docker-healthcheck. Geeft geen meetgegevens prijs."""
    try:
        with pool.connection(timeout=3) as conn:
            conn.execute("SELECT 1")
    except Exception as error:
        raise HTTPException(status_code=503, detail="Database niet bereikbaar") from error
    return {"status": "ok"}


@api.get("/now")
def now() -> dict:
    rows = query("""
        SELECT time, voltage_l1, voltage_l2, voltage_l3,
               current_l1, current_l2, current_l3, current_n,
               power_l1, power_l2, power_l3, power_total, frequency,
               current_thd_l1, current_thd_l2, current_thd_l3
        FROM sdm630 ORDER BY time DESC LIMIT 1""")
    latest = rows[0] if rows else {"time": None}
    energy = query("""
        SELECT coalesce(sum(kwh_total) FILTER (WHERE bucket >= date_trunc('day', now(), %s)), 0) AS today_kwh,
               coalesce(sum(kwh_export) FILTER (WHERE bucket >= date_trunc('day', now(), %s)), 0) AS today_export_kwh,
               coalesce(sum(kwh_total), 0) AS month_kwh,
               coalesce(sum(kwh_export), 0) AS month_export_kwh
        FROM energy_hourly WHERE bucket >= date_trunc('month', now(), %s)""",
                   (LOCAL_TZ, LOCAL_TZ, LOCAL_TZ))[0]
    seen = latest["time"]
    stale = seen is None or datetime.now(timezone.utc) - datetime.fromisoformat(seen) > STALE_AFTER
    return {**latest, **energy, "stale": stale}


@api.get("/series")
def series(hours: int = Query(24, ge=1, le=24 * 366), points: int = Query(300, ge=10, le=1000)) -> list[dict]:
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    step_ms = int(hours * 3_600_000 / points)
    return query("""
        SELECT time, current_l1, current_l2, current_l3, current_n,
               power_l1, power_l2, power_l3, power_total,
               voltage_l1, voltage_l2, voltage_l3
        FROM energy_series(%s, %s, %s)""", (start, end, step_ms))


@api.get("/daily")
def daily(days: int = Query(30, ge=1, le=3660)) -> list[dict]:
    return query("""
        SELECT date_trunc('day', bucket, %s) AS day,
               sum(kwh_total) AS kwh_total, sum(kwh_export) AS kwh_export,
               sum(kwh_l1) AS kwh_l1, sum(kwh_l2) AS kwh_l2, sum(kwh_l3) AS kwh_l3
        FROM energy_hourly
        WHERE bucket >= now() - make_interval(days => %s)
        GROUP BY 1 ORDER BY 1""", (LOCAL_TZ, days))


@api.get("/heatmap")
def heatmap(days: int = Query(90, ge=7, le=3660)) -> list[dict]:
    return query("""
        SELECT extract(isodow FROM bucket AT TIME ZONE %s)::int AS weekday,
               extract(hour FROM bucket AT TIME ZONE %s)::int AS hour,
               avg(kwh_total) AS kwh
        FROM energy_hourly
        WHERE whole_hour AND bucket >= now() - make_interval(days => %s)
        GROUP BY 1, 2 ORDER BY 1, 2""", (LOCAL_TZ, LOCAL_TZ, days))


@api.get("/peaks")
def peaks(days: int = Query(30, ge=1, le=3660), limit: int = Query(10, ge=1, le=50)) -> list[dict]:
    return query("""
        SELECT bucket AS time, power_total_max AS power_total,
               current_l1_max AS current_l1, current_l2_max AS current_l2,
               current_l3_max AS current_l3, current_n_max AS current_n
        FROM sdm630_1m
        WHERE bucket >= now() - make_interval(days => %s)
        ORDER BY power_total_max DESC NULLS LAST LIMIT %s""", (days, limit))


@api.get("/baseload")
def baseload(days: int = Query(30, ge=1, le=366)) -> list[dict]:
    """Sluipverbruik per nacht: het 10e percentiel van het minuutvermogen."""
    return query("""
        SELECT date_trunc('day', bucket, %s) AS day,
               percentile_cont(0.1) WITHIN GROUP (ORDER BY power_total_avg) AS watts
        FROM sdm630_1m
        WHERE bucket >= now() - make_interval(days => %s)
          AND extract(hour FROM bucket AT TIME ZONE %s) >= %s
          AND extract(hour FROM bucket AT TIME ZONE %s) < %s
          AND power_total_avg IS NOT NULL
        GROUP BY 1
        HAVING count(*) >= 60
        ORDER BY 1""", (LOCAL_TZ, days, LOCAL_TZ, BASELOAD_HOURS[0], LOCAL_TZ, BASELOAD_HOURS[1]))


@api.get("/compare")
def compare() -> dict:
    """Deze week en maand tot nu toe, naast hetzelfde stuk van de vorige periode."""
    row = query("""
        WITH edge AS (
            SELECT now() AS n,
                   date_trunc('week', now(), %(tz)s) AS week_start,
                   date_trunc('month', now(), %(tz)s) AS month_start
        ), span AS (
            SELECT *,
                   week_start - INTERVAL '7 days' AS prev_week_start,
                   ((month_start AT TIME ZONE %(tz)s) - INTERVAL '1 month') AT TIME ZONE %(tz)s AS prev_month_start,
                   ((month_start AT TIME ZONE %(tz)s) - INTERVAL '1 year') AT TIME ZONE %(tz)s AS last_year_start,
                   n - month_start AS month_elapsed
            FROM edge
        )
        SELECT
            sum(kwh_total)  FILTER (WHERE bucket >= week_start) AS week_kwh,
            sum(kwh_export) FILTER (WHERE bucket >= week_start) AS week_export_kwh,
            sum(kwh_total)  FILTER (WHERE bucket >= prev_week_start
                                      AND bucket < n - INTERVAL '7 days') AS previous_week_kwh,
            sum(kwh_export) FILTER (WHERE bucket >= prev_week_start
                                      AND bucket < n - INTERVAL '7 days') AS previous_week_export_kwh,
            sum(kwh_total)  FILTER (WHERE bucket >= month_start) AS month_kwh,
            sum(kwh_export) FILTER (WHERE bucket >= month_start) AS month_export_kwh,
            sum(kwh_total)  FILTER (WHERE bucket >= prev_month_start
                                      AND bucket < least(prev_month_start + month_elapsed, month_start)) AS previous_month_kwh,
            sum(kwh_export) FILTER (WHERE bucket >= prev_month_start
                                      AND bucket < least(prev_month_start + month_elapsed, month_start)) AS previous_month_export_kwh,
            sum(kwh_total)  FILTER (WHERE bucket >= last_year_start
                                      AND bucket < last_year_start + month_elapsed) AS last_year_month_kwh,
            sum(kwh_export) FILTER (WHERE bucket >= last_year_start
                                      AND bucket < last_year_start + month_elapsed) AS last_year_month_export_kwh
        FROM energy_hourly, span
        WHERE bucket >= last_year_start""", {"tz": LOCAL_TZ})[0]
    return row


@api.get("/grid-load")
def grid_load(days: int = Query(7, ge=1, le=30)) -> dict:
    try:
        return grid_load_client.get(days)
    except GridLoadError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


@api.get("/settings")
def read_settings() -> dict:
    return settings_response()


@api.put("/settings")
def update_settings(settings: Settings) -> dict:
    store().update_settings(settings.model_dump())
    return settings_response()


@api.post("/devices")
def register_device(device: Device) -> dict:
    token = device.token.lower()
    if not valid_device_token(token):
        raise HTTPException(status_code=422, detail="Ongeldig apparaattoken")
    store().register_device(token, device.platform, device.environment)
    return {"registered": True, "configured": "push" in service().senders}


@api.delete("/devices/{token}")
def remove_device(token: str) -> dict:
    store().remove_device(token.lower())
    return {"registered": False}


@api.post("/notifications/test")
async def send_test_notification(channel: Literal["telegram", "push"] | None = None) -> dict:
    """Testmelding naar één kanaal, of naar alle geconfigureerde kanalen."""
    if channel and channel not in service().senders:
        label = "Telegram" if channel == "telegram" else "Apple-push"
        raise HTTPException(status_code=503,
                            detail=f"{label} is nog niet geconfigureerd op de server")
    results = await service().send_test(channel)
    if not results:
        raise HTTPException(status_code=503,
                            detail="Er is nog geen meldingskanaal geconfigureerd op de server")
    failed = [result.reason for result in results.values() if not result.sent]
    if len(failed) == len(results):
        raise HTTPException(status_code=502, detail=failed[0] or "Versturen mislukt")
    return {"sent": {name: result.sent for name, result in results.items()}}


# -- Oude paden, voor appversies van vóór de gedeelde instellingen ----------

@api.put("/telegram/settings")
def update_telegram_settings(settings: LegacyTelegramSettings) -> dict:
    store().update_settings(settings.model_dump())
    return {"configured": "telegram" in service().senders}


@api.post("/telegram/test")
async def send_test_telegram() -> dict:
    await send_test_notification("telegram")
    return {"sent": True}


app.include_router(api)
