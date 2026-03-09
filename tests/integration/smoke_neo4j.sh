#!/usr/bin/env bash
# Integration smoke test — Neo4j backend
set -euo pipefail

STACK="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$STACK/.env"
ENV_BAK="$STACK/.env.bak.$$"

cleanup() {
    docker compose -f "$STACK/compose.yaml" --profile neo4j down --remove-orphans 2>/dev/null || true
    if [ -f "$ENV_BAK" ]; then
        mv "$ENV_BAK" "$ENV_FILE"
    fi
}
trap cleanup EXIT

echo "=== smoke_neo4j: starting ==="

cp "$ENV_FILE" "$ENV_BAK"
cat > "$ENV_FILE" <<'EOF'
COMPOSE_PROFILES=neo4j
AMASS_DB=assetdb
AMASS_USER=amass
AMASS_PASSWORD=test_amass_smoke
POSTGRES_PASSWORD=test_postgres_smoke
AMASS_LOGLEVEL=INFO
EOF

# Wipe neo4j data so it initialises fresh
rm -rf "$STACK/assetdb/neo4j"/*

docker compose -f "$STACK/compose.yaml" --profile neo4j up -d --wait syslog postal neo4j engine

echo "=== smoke_neo4j: running enum -d example.com -timeout 2 ==="
docker compose -f "$STACK/compose.yaml" --profile neo4j run --rm enum -d example.com -timeout 2

count=$(docker exec neo4j cypher-shell -u neo4j -p test_amass_smoke \
    "MATCH (n:FQDN) RETURN count(n) AS c;" --format plain 2>/dev/null \
    | tail -1 | tr -d ' \n' || echo 0)
echo "=== smoke_neo4j: found $count FQDN nodes ==="
if [ "${count:-0}" -lt 1 ]; then
    echo "FAIL: no FQDN nodes stored in neo4j" >&2
    exit 1
fi

echo "=== smoke_neo4j: PASS ==="
