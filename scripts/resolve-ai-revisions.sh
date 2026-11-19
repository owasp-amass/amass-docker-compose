#!/usr/bin/env bash
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
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
export AMASS_SRC_REF="${AMASS_SRC_REF:-$(_amass_dotenv_ref AMASS_SRC_REF)}"
export ASSETDB_SRC_REF="${ASSETDB_SRC_REF:-$(_amass_dotenv_ref ASSETDB_SRC_REF)}"
export AMASS_SRC_REF="${AMASS_SRC_REF:-feature/ai-investigation-inference}"
export ASSETDB_SRC_REF="${ASSETDB_SRC_REF:-feature/ai-investigation-inference}"
# AMASS_LOCAL_SRC (exported or in .env) builds Amass from that local
# checkout instead of the GitHub branch; asset-db still resolves from GitHub.
# A key appended to a .env whose last line lacked a newline is glued onto the
# previous value and silently ignored; refuse to continue in that case.
if [[ -f .env ]] && grep -Eq '^[^#].*[^[:space:]]AMASS_AI_[A-Z_]+=' .env; then
  echo "ERROR: .env has an AMASS_AI_* setting joined to the end of another line;" \
    "put each KEY=value on its own line" >&2
  return 1 2>/dev/null || exit 1
fi
export AMASS_LOCAL_SRC="${AMASS_LOCAL_SRC:-$(_amass_dotenv_ref AMASS_LOCAL_SRC)}"
if [[ -n "$AMASS_LOCAL_SRC" ]]; then
  if [[ ! -f "$AMASS_LOCAL_SRC/go.mod" ]] || ! grep -q '^module github.com/owasp-amass/amass/' "$AMASS_LOCAL_SRC/go.mod"; then
    echo "ERROR: AMASS_LOCAL_SRC=$AMASS_LOCAL_SRC is not an Amass checkout" >&2
    return 1 2>/dev/null || exit 1
  fi
  AMASS_LOCAL_SRC="$(cd "$AMASS_LOCAL_SRC" && pwd)"
  export AMASS_LOCAL_SRC
  _local_desc="$(git -C "$AMASS_LOCAL_SRC" describe --always --dirty 2>/dev/null || echo unknown)"
  _local_branch="$(git -C "$AMASS_LOCAL_SRC" branch --show-current 2>/dev/null || true)"
  AMASS_SRC_SHA="local"
else
  AMASS_SRC_SHA="$(_amass_resolve_revision amass "$AMASS_SRC_REF" amass)" || return 1 2>/dev/null || exit 1
fi
ASSETDB_SRC_SHA="$(_amass_resolve_revision asset-db "$ASSETDB_SRC_REF" asset-db)" || return 1 2>/dev/null || exit 1
export AMASS_SRC_SHA ASSETDB_SRC_SHA
if [[ -n "$AMASS_LOCAL_SRC" ]]; then
  printf 'Building LOCAL amass %s (%s, branch %s) with asset-db@%.12s\n' \
    "$AMASS_LOCAL_SRC" "$_local_desc" "${_local_branch:-detached}" "$ASSETDB_SRC_SHA"
else
  printf 'Building amass@%.12s and asset-db@%.12s (resolved from feature branches)\n' \
    "$AMASS_SRC_SHA" "$ASSETDB_SRC_SHA"
fi
