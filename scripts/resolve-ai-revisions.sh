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

export AMASS_AI_AMASS_REF="${AMASS_AI_AMASS_REF:-feature/ai-investigation-inference}"
export AMASS_AI_ASSETDB_REF="${AMASS_AI_ASSETDB_REF:-feature/ai-investigation-inference}"
AMASS_AI_AMASS_SHA="$(_amass_resolve_revision amass "$AMASS_AI_AMASS_REF" amass)" || return 1 2>/dev/null || exit 1
AMASS_AI_ASSETDB_SHA="$(_amass_resolve_revision asset-db "$AMASS_AI_ASSETDB_REF" asset-db)" || return 1 2>/dev/null || exit 1
export AMASS_AI_AMASS_SHA AMASS_AI_ASSETDB_SHA
printf 'Building amass@%.12s and asset-db@%.12s (resolved from feature branches)\n' \
  "$AMASS_AI_AMASS_SHA" "$AMASS_AI_ASSETDB_SHA"
