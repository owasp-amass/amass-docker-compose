#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# One-command AI environment startup. Requires an isolated feature checkout.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for command in docker python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "ERROR: $command is required" >&2
    exit 1
  fi
done
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not available" >&2
  exit 1
fi

mkdir -p data/ai data/models data/ollama data/classifier-training
# Avoid putting bearer secrets into Git-tracked .env. Reuse a persistent,
# mode-0600 secret under the isolated bind-mounted test data directory.
if [[ -z "${AMASS_AI_MCP_TOKEN:-}" ]]; then
  token_file=data/ai/.mcp-token
  if [[ ! -s "$token_file" ]]; then
    (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$token_file")
  fi
  export AMASS_AI_MCP_TOKEN="$(cat "$token_file")"
fi
if (( ${#AMASS_AI_MCP_TOKEN} < 32 )); then
  echo "ERROR: MCP token must be at least 32 characters" >&2
  exit 1
fi

# Respect existing Compose .env and exported model settings without evaluating
# shell from .env. Only the exact internal Ollama hostname is auto-provisioned.
model_endpoint="$(python3 - <<'PY'
import os
from pathlib import Path
value=os.environ.get("AMASS_AI_ENDPOINT","")
if not value and Path(".env").exists():
    for line in Path(".env").read_text().splitlines():
        if line.strip().startswith("AMASS_AI_ENDPOINT="):
            value=line.split("=",1)[1].strip().strip('"').strip("'")
print(value or "http://ollama:11434/v1/chat/completions")
PY
)"
provider="$(python3 - <<'PY'
import os
from pathlib import Path
value=os.environ.get("AMASS_AI_PROVIDER","")
if not value and Path(".env").exists():
    for line in Path(".env").read_text().splitlines():
        if line.strip().startswith("AMASS_AI_PROVIDER="):
            value=line.split("=",1)[1].strip().strip('"').strip("'")
print(value or "compatible")
PY
)"
if [[ "$model_endpoint" == http://ollama:11434/* && "$provider" == compatible ]]; then
  export AMASS_AI_ALLOW_HTTP=true
  local_model=1
else
  local_model=0
  if [[ "$model_endpoint" == http://* ]]; then
    echo "ERROR: external HTTP model endpoints are not enabled by this script. Configure HTTPS." >&2
    exit 1
  fi
fi

# The feature-branch Compose file now includes the original Amass services,
# dedicated `ai` subcommand, classifier, MCP, and the optional model.
declare -a compose=(docker compose)
# Resolve both Git branch tips before rendering Compose, so Docker will
# rebuild cloned Go sources only when either feature branch actually changes.
source scripts/resolve-ai-revisions.sh
python3 scripts/check-ai-compose.py
echo "Building the matching Amass and Asset Database feature image..."
"${compose[@]}" build ai

if [[ -s data/classifier-training/labeled.jsonl ]] && \
   { [[ ! -s data/models/classifier.json ]] || [[ data/classifier-training/labeled.jsonl -nt data/models/classifier.json ]]; }; then
  echo "Training the local classifier from curated labeled examples..."
  "${compose[@]}" --profile ai-train run --rm classifier-train
elif [[ ! -s data/models/classifier.json ]]; then
  echo "No trained classifier artifact found; default OAM evidence triage (review/escalation) will be used."
fi

if (( local_model == 1 )); then
  echo "Starting Ollama and ensuring the configured model is loaded..."
  "${compose[@]}" --profile ai-local up -d --wait --wait-timeout 180 ollama
  model_name="$("${compose[@]}" --profile ai-local config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["ollama-pull"]["command"][0])')"
  if "${compose[@]}" --profile ai-local exec -T ollama ollama show "$model_name" >/dev/null 2>&1; then
    echo "Ollama model $model_name already installed; skipping download."
  else
    "${compose[@]}" --profile ai-local run --rm ollama-pull
  fi
else
  echo "Using configured external inference provider ($provider); local Ollama not required."
fi

echo "Starting Amass, classifier, provider health checker and MCP..."
# The classifier loads its JSON artifact at process startup. Recreate it
# on each invocation so an updated trained model is never silently stale.
"${compose[@]}" --profile ai up -d --force-recreate --no-deps classifier
"${compose[@]}" --profile ai up -d --build --wait --wait-timeout 900 \
  assetdb syslog postal engine classifier provider-health ai-mcp

echo "AI profile is healthy; model inference connectivity was verified."
"${compose[@]}" --profile ai ps
echo "MCP URL: http://127.0.0.1:${AMASS_AI_MCP_PORT:-18090}/mcp"
echo "MCP bearer token: data/ai/.mcp-token (unless provided by environment)"
echo "Classifier state can be inspected with: ${compose[*]} exec -T classifier wget -qO- http://127.0.0.1:8092/v1/model"
echo "No Internet enumeration or inference-derived graph write was started."
