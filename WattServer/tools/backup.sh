#!/bin/sh
# Dagelijkse databaseback-up. Draait als Compose-service `backup`.
# Schrijft eerst naar een tijdelijk bestand, zodat een afgebroken dump nooit
# voor een geldige back-up wordt aangezien.
set -eu

KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"
TARGET=/backups

while true; do
    stamp="$(date +%F-%H%M)"
    if pg_dump -h timescaledb -U energy -d energy -Fc -f "$TARGET/.wattnu-$stamp.partial"; then
        mv "$TARGET/.wattnu-$stamp.partial" "$TARGET/wattnu-$stamp.dump"
        echo "Back-up gemaakt: wattnu-$stamp.dump"
        find "$TARGET" -name 'wattnu-*.dump' -mtime "+$KEEP_DAYS" -delete
    else
        rm -f "$TARGET/.wattnu-$stamp.partial"
        echo "Back-up mislukt; over een uur opnieuw" >&2
        sleep 3600
        continue
    fi
    sleep "$INTERVAL"
done
