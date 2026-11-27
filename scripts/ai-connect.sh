#!/usr/bin/env bash
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0

# Connect AI assistants and agents (Claude, Cursor, VS Code, Codex, Gemini
# CLI and others) to this stack's Amass MCP server. See AI.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 1
fi
exec python3 scripts/ai-connect.py "$@"
