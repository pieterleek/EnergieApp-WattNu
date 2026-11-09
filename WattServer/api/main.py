"""Alleen-lezen API voor WattNu."""
import hmac
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from grid_load import GridLoadClient, GridLoadError
from telegram import NotificationService, NotificationStore, TelegramSender

API_TOKEN = os.environ["API_TOKEN"]
STALE_AFTER = timedelta(seconds=60)
LOCAL_TZ = "Europe/Amsterdam"

pool = ConnectionPool(os.environ["DATABASE_DSN"], min_size=1, max_size=4, open=False,
                      kwargs={"row_factory": dict_row, "autocommit": True})
grid_load_client = GridLoadClient()


@asynccontextmanager
async def lifespan(application: FastAPI):
    pool.open()
    store = NotificationStore(os.getenv("NOTIFICATION_DB_PATH", "/data/notifications.sqlite3"))
    sender = TelegramSender.from_environment()
    service = NotificationService(store, sender, now) if sender else None
    application.state.notification_store = store
    application.state.notification_service = service
    if service:
        service.start()
    try:
        yield
    finally:
        if service:
            await service.stop()
        pool.close()


def require_token(authorization: str = Header(default="")) -> None:
    if not hmac.compare_digest(authorization.encode(), f"Bearer {API_TOKEN}".encode()):
        raise HTTPException(status_code=401, detail="Ongeldig token")


app = FastAPI(title="WattNu", lifespan=lifespan, docs_url=None, redoc_url=None,
              openapi_url=None, dependencies=[Depends(require_token)])


class TelegramSettings(BaseModel):
    enabled: bool = True
    phase_alerts: bool = True
    stale_alerts: bool = True
    daily_limit_kwh: float | None = Field(default=None, gt=0, le=10_000)
    pieter_mode: bool = True


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


@app.get("/api/now")
def now() -> dict:
    rows = query("""
        SELECT time, voltage_l1, voltage_l2, voltage_l3,
               current_l1, current_l2, current_l3, current_n,
               power_l1, power_l2, power_l3, power_total, frequency
        FROM sdm630 ORDER BY time DESC LIMIT 1""")
    latest = rows[0] if rows else {"time": None}
    energy = query("""
        SELECT coalesce(sum(kwh_total) FILTER (WHERE bucket >= date_trunc('day', now(), %s)), 0) AS today_kwh,
               coalesce(sum(kwh_total), 0) AS month_kwh
        FROM energy_hourly WHERE bucket >= date_trunc('month', now(), %s)""", (LOCAL_TZ, LOCAL_TZ))[0]
    seen = latest["time"]
    stale = seen is None or datetime.now(timezone.utc) - datetime.fromisoformat(seen) > STALE_AFTER
    return {**latest, **energy, "stale": stale}


@app.get("/api/series")
def series(hours: int = Query(24, ge=1, le=24 * 366), points: int = Query(300, ge=10, le=1000)) -> list[dict]:
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    step_ms = int(hours * 3_600_000 / points)
    return query("""
        SELECT time, current_l1, current_l2, current_l3, current_n,
               power_l1, power_l2, power_l3, power_total,
               voltage_l1, voltage_l2, voltage_l3
        FROM energy_series(%s, %s, %s)""", (start, end, step_ms))


@app.get("/api/daily")
def daily(days: int = Query(30, ge=1, le=3660)) -> list[dict]:
    return query("""
        SELECT date_trunc('day', bucket, %s) AS day,
               sum(kwh_total) AS kwh_total, sum(kwh_l1) AS kwh_l1,
               sum(kwh_l2) AS kwh_l2, sum(kwh_l3) AS kwh_l3
        FROM energy_hourly
        WHERE bucket >= now() - make_interval(days => %s)
        GROUP BY 1 ORDER BY 1""", (LOCAL_TZ, days))


@app.get("/api/heatmap")
def heatmap(days: int = Query(90, ge=7, le=3660)) -> list[dict]:
    return query("""
        SELECT extract(isodow FROM bucket AT TIME ZONE %s)::int AS weekday,
               extract(hour FROM bucket AT TIME ZONE %s)::int AS hour,
               avg(kwh_total) AS kwh
        FROM energy_hourly
        WHERE whole_hour AND bucket >= now() - make_interval(days => %s)
        GROUP BY 1, 2 ORDER BY 1, 2""", (LOCAL_TZ, LOCAL_TZ, days))


@app.get("/api/peaks")
def peaks(days: int = Query(30, ge=1, le=3660), limit: int = Query(10, ge=1, le=50)) -> list[dict]:
    return query("""
        SELECT bucket AS time, power_total_max AS power_total,
               current_l1_max AS current_l1, current_l2_max AS current_l2,
               current_l3_max AS current_l3, current_n_max AS current_n
        FROM sdm630_1m
        WHERE bucket >= now() - make_interval(days => %s)
        ORDER BY power_total_max DESC NULLS LAST LIMIT %s""", (days, limit))


@app.get("/api/grid-load")
def grid_load(days: int = Query(7, ge=1, le=30)) -> dict:
    try:
        return grid_load_client.get(days)
    except GridLoadError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


@app.put("/api/telegram/settings")
def update_telegram_settings(settings: TelegramSettings) -> dict:
    app.state.notification_store.update_settings(settings.model_dump())
    return {"configured": app.state.notification_service is not None}


@app.post("/api/telegram/test")
async def send_test_telegram() -> dict:
    service: NotificationService | None = app.state.notification_service
    if service is None:
        raise HTTPException(
            status_code=503,
            detail="Telegram is nog niet geconfigureerd op de server",
        )
    result = await service.send_test()
    if not result.sent:
        raise HTTPException(status_code=502, detail=f"Telegram-fout: {result.reason}")
    return {"sent": True}
