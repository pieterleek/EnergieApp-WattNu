"""Brengt een bestaande WattNu-database bij naar de huidige versie.

Draait bij elke start als eenmalige Compose-service, vóór de API:

1. voert nog niet toegepaste bestanden uit db/migrations uit, op naam gesorteerd;
2. zorgt dat de alleen-lezen rol van de API bestaat, met het huidige wachtwoord.

Het basisschema (db/init) blijft het werk van de eerste databasestart.

Een migratie draait in één transactie. Sommige TimescaleDB-opdrachten mogen
dat niet; zet dan `-- migrate: no-transaction` op de eerste regel en houd het
bestand bij één opdracht.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg
from psycopg import sql

NO_TRANSACTION = "-- migrate: no-transaction"
API_ROLE = "wattnu_api"


def pending(directory: Path, applied: set[str]) -> list[Path]:
    return [path for path in sorted(directory.glob("*.sql")) if path.name not in applied]


def apply_migrations(connection: psycopg.Connection, directory: Path) -> list[str]:
    connection.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            name text PRIMARY KEY,
            applied_at timestamptz NOT NULL DEFAULT now()
        )""")
    applied = {row[0] for row in connection.execute("SELECT name FROM schema_migrations")}
    done = []
    for path in pending(directory, applied):
        text = path.read_text()
        record = sql.SQL("INSERT INTO schema_migrations (name) VALUES ({})").format(
            sql.Literal(path.name))
        if text.lstrip().startswith(NO_TRANSACTION):
            connection.execute(text)
            connection.execute(record)
        else:
            with connection.transaction():
                connection.execute(text)
                connection.execute(record)
        done.append(path.name)
    return done


def ensure_api_role(connection: psycopg.Connection, password: str) -> None:
    """Eigen leesrol voor de API, los van Grafana. Herhaalbaar; zet ook een nieuw wachtwoord."""
    role = sql.Identifier(API_ROLE)
    exists = connection.execute(
        "SELECT 1 FROM pg_roles WHERE rolname = %s", (API_ROLE,)).fetchone()
    verb = sql.SQL("ALTER") if exists else sql.SQL("CREATE")
    with connection.transaction():
        connection.execute(sql.SQL("{} ROLE {} LOGIN PASSWORD {}").format(
            verb, role, sql.Literal(password)))
        connection.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(role))
        connection.execute(
            sql.SQL("GRANT SELECT ON ALL TABLES IN SCHEMA public TO {}").format(role))
        connection.execute(sql.SQL(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO {}"
        ).format(role))


def main() -> int:
    directory = Path(os.getenv("MIGRATIONS_DIR", "/migrations"))
    password = os.environ["API_DB_PASSWORD"]
    with psycopg.connect(os.environ["MIGRATION_DSN"], autocommit=True) as connection:
        for name in apply_migrations(connection, directory):
            print(f"Migratie toegepast: {name}")
        ensure_api_role(connection, password)
    print("Database is bij.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
