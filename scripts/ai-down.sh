#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Stop the disposable AI test deployment, including optional-profile Ollama.
# Does not remove bind-mounted database/model data or named volumes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker compose --profile ai-local --profile ai-train --profile ai-stdio down
network="${AMASS_TEST_NAMESPACE:-amass-ai-test}-net"
# Compose only removes an otherwise unused network. If another container
# remains attached, report the owner; never force-disconnect someone else's
# container or delete persistent data.
if docker network inspect "$network" >/dev/null 2>&1; then
  echo "Network $network remains attached to at least one container."
  echo "Attached containers (inspect before taking action):"
  docker ps -a --filter "network=$network" --format '  {{.ID}}  {{.Names}}  {{.Status}}'
  exit 1
fi
echo "AI test deployment stopped. Persistent test database and Ollama models preserved."
