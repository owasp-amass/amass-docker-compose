#!/usr/bin/env bash
# Integration smoke test — PostgreSQL backend
set -euo pipefail

STACK="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$STACK/.env"
ENV_BAK="$STACK/.env.bak.$$"

cleanup() {
    docker compose -f "$STACK/compose.yaml" --profile postgres down --remove-orphans 2>/dev/null || true
    if [ -f "$ENV_BAK" ]; then
        mv "$ENV_BAK" "$ENV_FILE"
    fi
}
trap cleanup EXIT

echo "=== smoke_postgres: starting ==="

cp "$ENV_FILE" "$ENV_BAK"
cat > "$ENV_FILE" <<'EOF'
COMPOSE_PROFILES=postgres
AMASS_DB=assetdb
AMASS_USER=amass
AMASS_PASSWORD=test_amass_smoke
POSTGRES_PASSWORD=test_postgres_smoke
AMASS_LOGLEVEL=INFO
EOF

# Wipe postgres data so init scripts run fresh
rm -rf "$STACK/assetdb/postgres"

docker compose -f "$STACK/compose.yaml" --profile postgres up -d --wait syslog postal assetdb engine

echo "=== smoke_postgres: running enum -d example.com -timeout 2 ==="
docker compose -f "$STACK/compose.yaml" --profile postgres run --rm enum -d example.com -timeout 2

count=$(docker exec assetdb psql -U amass -d assetdb -t -c \
    "SELECT COUNT(*) FROM fqdn;" 2>/dev/null | tr -d ' \n' || echo 0)
echo "=== smoke_postgres: found $count FQDNs ==="
if [ "${count:-0}" -lt 1 ]; then
    echo "FAIL: no FQDNs stored in postgres" >&2
    exit 1
fi

echo "=== smoke_postgres: PASS ==="
