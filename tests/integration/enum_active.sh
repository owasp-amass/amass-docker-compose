#!/usr/bin/env bash
# Integration test: -active flag (SQLite backend)
# Verifies that active enumeration (zone transfers, TLS cert pulls) runs
# successfully and stores FQDNs. Uses example.com — a domain maintained by
# IANA for testing; zone transfers are expected to be refused, which is fine.
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

echo "=== enum_active: starting ==="

cp "$ENV_FILE" "$ENV_BAK"
cat > "$ENV_FILE" <<'EOF'
COMPOSE_PROFILES=
AMASS_DB=assetdb
AMASS_USER=amass
AMASS_PASSWORD=test_amass_smoke
POSTGRES_PASSWORD=test_postgres_smoke
AMASS_LOGLEVEL=INFO
EOF

rm -f "$STACK/data/engine/asset.db" \
      "$STACK/data/engine/asset.db-shm" \
      "$STACK/data/engine/asset.db-wal"

docker compose -f "$STACK/compose.yaml" up -d --wait syslog postal engine

echo "=== enum_active: running enum -active -d example.com -timeout 2 ==="
docker compose -f "$STACK/compose.yaml" run --rm enum -active -d example.com -timeout 2

DB="$STACK/data/engine/asset.db"
if [ ! -f "$DB" ]; then
    echo "FAIL: $DB was not created" >&2
    exit 1
fi

count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM fqdn;" 2>/dev/null || echo 0)
echo "=== enum_active: found $count FQDNs ==="
if [ "${count:-0}" -lt 1 ]; then
    echo "FAIL: no FQDNs stored (active mode)" >&2
    exit 1
fi

echo "=== enum_active: PASS ==="
