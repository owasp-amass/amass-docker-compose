#!/usr/bin/env python3
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0

r"""Turnkey, cross-platform startup for the isolated Amass feature-branch stack.

Run it with the scripts/ wrappers (``./scripts/up`` on macOS/Linux, ``scripts\up.cmd``
or ``.\scripts\up.ps1`` on Windows) or directly: ``python3 scripts/up.py [options]``.

  up                 start collection + the always-on classifier (no LLM)
  up --llm           also start model inference, the MCP server, (opt.) chat
  up --no-llm        force the no-LLM core set
  up --local [PATH]  build amass from a local checkout (default ../amass)
  up --branch NAME   build amass and asset-db from a GitHub branch
  up --chat          also start the Open WebUI chat UI (implies/with --llm)

The first run asks whether to enable LLM features and records the answer in
.env; later runs reuse it unless --llm/--no-llm is given.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _lifecycle import up_main  # noqa: E402

if __name__ == "__main__":
    up_main()
