#!/usr/bin/env bash
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
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
print(value or "http://ollama:11434")
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
print(value or "ollama")
PY
)"
# The internal Ollama service, through its native API or the OpenAI-compatible /v1 API.
if [[ ( "$model_endpoint" == http://ollama:11434 || "$model_endpoint" == http://ollama:11434/* ) &&
      ( "$provider" == ollama || "$provider" == compatible ) ]]; then
  export AMASS_AI_ALLOW_HTTP=true
  local_model=1

else
  local_model=0
  if [[ "$model_endpoint" == http://* ]]; then
    echo "ERROR: external HTTP model endpoints are not enabled by this script. Configure HTTPS." >&2
    exit 1
  fi
  export AMASS_AI_ALLOW_HTTP=false
fi

# Keep Docker Compose lifecycle commands consistent across shell invocations.
# Without COMPOSE_PROFILES=ai-local in .env, plain "docker compose down"
# omits the previously started profiled Ollama container and cannot
# remove the project network ("Resource is still in use").
# Retain any pre-existing other profiles; update only the two managed keys.
python3 - "$local_model" <<'PY'
from pathlib import Path
import sys

local = sys.argv[1] == "1"
path = Path(".env")
lines = path.read_text().splitlines() if path.exists() else []
profiles = []
for line in lines:
    if line.strip().startswith("COMPOSE_PROFILES="):
        raw = line.split("=", 1)[1].strip().strip('"').strip("'")
        profiles = [p.strip() for p in raw.split(",") if p.strip()]
        break
profiles = [p for p in profiles if p != "ai-local"]
if local:
    profiles.append("ai-local")

values = {
    "AMASS_AI_ALLOW_HTTP": "true" if local else "false",
    "COMPOSE_PROFILES": ",".join(profiles),
}
updated = []
written = set()
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line else ""
    if key in values:
        if key not in written and (values[key] or key == "AMASS_AI_ALLOW_HTTP"):
            updated.append(f"{key}={values[key]}")
        written.add(key)
    else:
        updated.append(line)
for key, value in values.items():
    if key not in written and (value or key == "AMASS_AI_ALLOW_HTTP"):
        updated.append(f"{key}={value}")
after = "\n".join(updated).rstrip() + "\n"
if not path.exists() or path.read_text() != after:
    path.write_text(after)
print("Compose lifecycle profile:", values["COMPOSE_PROFILES"] or "default only")
PY
if [[ -n "${COMPOSE_PROFILES:-}" && "$local_model" == "1" &&
      ",$COMPOSE_PROFILES," != *",ai-local,"* ]]; then
  echo "WARNING: exported COMPOSE_PROFILES overrides .env. Include ai-local when stopping this stack." >&2
fi

# The feature-branch Compose file now includes the original Amass services,
# dedicated `ai` subcommand, classifier, MCP, and the optional model.
declare -a compose=(docker compose)
# Resolve both Git branch tips before rendering Compose, so Docker will
# rebuild cloned Go sources only when either feature branch actually changes.
source scripts/resolve-ai-revisions.sh
python3 scripts/check-ai-compose.py
if [[ -n "$AMASS_AI_LOCAL_AMASS" ]]; then
  # Build from the local checkout; every later compose call in this script
  # uses the same overlay so --build never falls back to the GitHub branch.
  compose=(docker compose -f compose.yaml -f compose.local-src.yaml)
fi
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
"${compose[@]}" up -d --force-recreate --no-deps classifier
"${compose[@]}" up -d --build --wait --wait-timeout 900 \
  assetdb syslog postal engine classifier provider-health ai-mcp

echo "AI profile is healthy; model inference connectivity was verified."
"${compose[@]}" ps
echo "MCP URL: http://127.0.0.1:${AMASS_AI_MCP_PORT:-18090}/mcp"
echo "MCP bearer token: data/ai/.mcp-token (unless provided by environment)"
echo "Classifier state can be inspected with: ${compose[*]} exec -T classifier wget -qO- http://127.0.0.1:8092/v1/model"
echo "No Internet enumeration or inference-derived graph write was started."
