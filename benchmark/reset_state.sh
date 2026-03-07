#!/bin/bash
# Reset all benchmark state between runs:
#   1. Delete SQLite database
#   2. Delete nlp_learned.bin
#   3. Flush DNS resolver cache (restart resolver containers)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "[reset] Removing SQLite database..."
rm -f data/engine/assetdb.db

echo "[reset] Removing nlp_learned.bin..."
rm -f data/engine/nlp_learned.bin

echo "[reset] Restarting engine to pick up clean state..."
docker compose restart engine
sleep 10
docker compose ps engine

echo "[reset] Done."
