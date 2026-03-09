#!/usr/bin/env bash
# Integration smoke test — SQLite backend
# Runs a short enum (-timeout 2) against example.com and verifies the DB was written.
set -euo pipefail

STACK="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$STACK/.env"
ENV_BAK="$STACK/.env.bak.$$"

cleanup() {
    docker compose -f "$STACK/compose.yaml" down --remove-orphans 2>/dev/null || true
    if [ -f "$ENV_BAK" ]; then
        mv "$ENV_BAK" "$ENV_FILE"
    fi
}
trap cleanup EXIT

echo "=== smoke_sqlite: starting ==="

cp "$ENV_FILE" "$ENV_BAK"
cat > "$ENV_FILE" <<'EOF'
COMPOSE_PROFILES=
AMASS_DB=assetdb
AMASS_USER=amass
AMASS_PASSWORD=test_amass_smoke
POSTGRES_PASSWORD=test_postgres_smoke
AMASS_LOGLEVEL=INFO
EOF

# Remove stale SQLite DB so we start clean
rm -f "$STACK/data/engine/asset.db" \
      "$STACK/data/engine/asset.db-shm" \
      "$STACK/data/engine/asset.db-wal"

docker compose -f "$STACK/compose.yaml" up -d --wait syslog postal engine

echo "=== smoke_sqlite: running enum -d example.com -timeout 2 ==="
docker compose -f "$STACK/compose.yaml" run --rm enum -d example.com -timeout 2

DB="$STACK/data/engine/asset.db"
if [ ! -f "$DB" ]; then
    echo "FAIL: $DB was not created" >&2
    exit 1
fi

# Count FQDNs stored
count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM fqdn;" 2>/dev/null || echo 0)
echo "=== smoke_sqlite: found $count FQDNs ==="
if [ "${count:-0}" -lt 1 ]; then
    echo "FAIL: no FQDNs stored in SQLite" >&2
    exit 1
fi

echo "=== smoke_sqlite: PASS ==="
