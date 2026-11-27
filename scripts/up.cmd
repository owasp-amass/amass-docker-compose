@echo off
rem Copyright (c) by Jeff Foley 2017-2026. All rights reserved.
rem Use of this source code is governed by Apache 2 LICENSE in the LICENSE file.
rem SPDX-License-Identifier: Apache-2.0
rem Turnkey wrapper (Windows cmd): runs up.py in this directory. UNTESTED on Windows.
where python >nul 2>nul && (python "%~dp0up.py" %*) || (py "%~dp0up.py" %*)
