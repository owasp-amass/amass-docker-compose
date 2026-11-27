#!/usr/bin/env python3
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0

r"""Turnkey, cross-platform shutdown for the isolated Amass feature-branch stack.

Run it with the scripts/ wrappers (``./scripts/down`` on macOS/Linux, ``scripts\down.cmd``
or ``.\scripts\down.ps1`` on Windows) or directly: ``python3 scripts/down.py``.

Stops every service, including the optional-profile Ollama, training job, stdio
MCP and chat UI. The persistent test database and the Ollama models are
preserved.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _lifecycle import down_main  # noqa: E402

if __name__ == "__main__":
    down_main()
