#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Source this file from the AI startup/smoke scripts.
# Resolve BOTH development-branch tips to immutable commits before Compose
# builds the image. Branch names alone cannot invalidate Docker clone cache.
if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required to resolve feature-branch revisions" >&2
  return 1 2>/dev/null || exit 1
fi

_amass_resolve_revision() {
  local repository="$1" branch="$2" name="$3" resolved sha rest
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "ERROR: invalid $name branch name: $branch" >&2
    return 1
  fi
  if ! resolved="$(git ls-remote --exit-code "https://github.com/owasp-amass/$repository.git" "refs/heads/$branch")" || [[ -z "$resolved" ]]; then
    echo "ERROR: cannot resolve $repository branch $branch. Check network access and branch spelling." >&2
    return 1
  fi
  read -r sha rest <<< "$resolved"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]] || [[ "$rest" != "refs/heads/$branch" ]]; then
    echo "ERROR: unexpected Git reference returned for $repository:$branch" >&2
    return 1
  fi
  printf '%s' "$sha"
}

# Match Docker Compose precedence: exported variables override the local .env.
# Read only these two literal values; never execute contents of .env.
_amass_dotenv_ref() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
key = sys.argv[1]
path = Path(".env")
if path.exists():
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith(key + "="):
            value = line.split("=", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            print(value)
            break
PY
}
export AMASS_AI_AMASS_REF="${AMASS_AI_AMASS_REF:-$(_amass_dotenv_ref AMASS_AI_AMASS_REF)}"
export AMASS_AI_ASSETDB_REF="${AMASS_AI_ASSETDB_REF:-$(_amass_dotenv_ref AMASS_AI_ASSETDB_REF)}"
export AMASS_AI_AMASS_REF="${AMASS_AI_AMASS_REF:-feature/ai-investigation-inference}"
export AMASS_AI_ASSETDB_REF="${AMASS_AI_ASSETDB_REF:-feature/ai-investigation-inference}"
AMASS_AI_AMASS_SHA="$(_amass_resolve_revision amass "$AMASS_AI_AMASS_REF" amass)" || return 1 2>/dev/null || exit 1
AMASS_AI_ASSETDB_SHA="$(_amass_resolve_revision asset-db "$AMASS_AI_ASSETDB_REF" asset-db)" || return 1 2>/dev/null || exit 1
export AMASS_AI_AMASS_SHA AMASS_AI_ASSETDB_SHA
printf 'Building amass@%.12s and asset-db@%.12s (resolved from feature branches)\n' \
  "$AMASS_AI_AMASS_SHA" "$AMASS_AI_ASSETDB_SHA"
