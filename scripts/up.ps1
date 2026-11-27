# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0
# Turnkey wrapper (PowerShell 5.1+ and PowerShell 7): runs up.py in this directory.
# UNTESTED on Windows.
$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "up.py"
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error "python (or py) is required on PATH"; exit 1 }
& $py.Source $script @args
exit $LASTEXITCODE
