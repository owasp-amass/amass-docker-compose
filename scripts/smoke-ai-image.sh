#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Non-destructive feature-image smoke test. Requires Docker, no network
# discovery, no PostgreSQL startup, and no model downloads.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is required to test the Compose image" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: Python 3 is required for static topology verification" >&2
  exit 1
fi
source scripts/resolve-ai-revisions.sh
python3 scripts/check-ai-compose.py
declare -a files=(-f compose.yaml -f compose.ai.yaml -f compose.ai-stack.yaml -f compose.ai-isolation.yaml)
docker compose "${files[@]}" --profile ai-tools build ai
# Assert every expected legacy and new binary is present and executable.
docker compose "${files[@]}" --profile ai-tools run --rm --no-deps \
  --entrypoint /bin/sh ai -euc '
  for bin in /bin/amass /bin/amass-ai-mcp /bin/amass-ai-mcp-http \
    /bin/amass-ai-classifier /bin/amass-ai-classifier-train \
    /bin/amass-ai-provider-health /bin/enum /bin/engine \
    /bin/ae_isready /bin/subs /bin/assoc /bin/viz /bin/track; do
    test -x "$bin" || { echo "MISSING: $bin" >&2; exit 1; }
  done
  echo "PASS: AI and legacy Amass binaries are executable"
'
# Exercise the standalone entrypoint without starting PostgreSQL,
# performing network collection, or opening an inference connection.
docker compose "${files[@]}" --profile ai-tools run --rm --no-deps \
  --entrypoint /bin/amass ai -version
echo "PASS: image smoke check; no legacy service or database started"
