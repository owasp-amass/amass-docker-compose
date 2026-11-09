#!/usr/bin/env bash
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0

# Read-only, non-network smoke test after the isolated PostgreSQL and
# engine services have been explicitly started by the operator.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
declare -a files=(-f compose.yaml)
python3 scripts/check-ai-compose.py
docker compose "${files[@]}" exec -T assetdb pg_isready -U postgres -d postgres
docker compose "${files[@]}" exec -T engine /bin/ae_isready --host 127.0.0.1
# The .invalid TLD is reserved; this checks indexed PostgreSQL lookup only,
# never performs DNS resolution, collection, or inference.
result="$(docker compose "${files[@]}" run --rm --no-deps ai \
  -subject-type FQDN -subject-field name -subject-value amass-preflight-only.invalid \
  -target-types Organization -format json search)"
printf '%s\n' "$result" | python3 -c '
import json,sys
payload=json.load(sys.stdin)
status=payload.get("status")
if status not in ("not_found", "matched"):
    sys.exit("unexpected indexed lookup result: "+str(status))
if status=="matched":
    sys.exit("reserved smoke-test FQDN unexpectedly exists in this database")
print("PASS: OAM indexed asset lookup works against isolated PostgreSQL")
'
echo "PASS: engine API ready; no AI inference or Internet collection occurred"
