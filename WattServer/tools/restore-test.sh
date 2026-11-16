#!/bin/sh
# Hersteltest: zet de nieuwste back-up terug in een wegwerpdatabase en telt de
# metingen. Raakt de echte database niet aan.
#
#   ./tools/restore-test.sh [pad/naar/wattnu-....dump]
set -eu

cd "$(dirname "$0")/.."
DUMP="${1:-$(ls -t backups/wattnu-*.dump 2>/dev/null | head -n 1)}"
if [ -z "$DUMP" ] || [ ! -f "$DUMP" ]; then
    echo "Geen back-up gevonden in backups/." >&2
    exit 1
fi

NAME=wattnu-restore-test
IMAGE=timescale/timescaledb:2.17.2-pg16
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "Hersteltest met $DUMP"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=test -e POSTGRES_USER=energy \
    -e POSTGRES_DB=energy -e NO_TS_TUNE=true "$IMAGE" >/dev/null
until docker exec "$NAME" pg_isready -U energy -d energy >/dev/null 2>&1; do sleep 1; done
sleep 2

# De rollen uit de dump bestaan hier niet; rechten doen er voor de test niet toe.
docker exec "$NAME" psql -q -U energy -d energy -c "SELECT timescaledb_pre_restore();" >/dev/null
docker exec -i "$NAME" pg_restore -U energy -d energy --no-owner --no-acl < "$DUMP"
docker exec "$NAME" psql -q -U energy -d energy -c "SELECT timescaledb_post_restore();" >/dev/null

docker exec "$NAME" psql -U energy -d energy -c \
    "SELECT count(*) AS metingen, min(time) AS oudste, max(time) AS nieuwste FROM sdm630;"
echo "Hersteltest geslaagd."
