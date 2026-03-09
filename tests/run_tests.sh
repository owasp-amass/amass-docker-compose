#!/usr/bin/env bash
# Test runner for the amass Docker Compose stack.
#
# Usage:
#   ./tests/run_tests.sh                        # unit tests only (fast, no Docker)
#   ./tests/run_tests.sh --unit                 # same
#   ./tests/run_tests.sh --integration sqlite   # one DB backend smoke test
#   ./tests/run_tests.sh --integration postgres
#   ./tests/run_tests.sh --integration neo4j
#   ./tests/run_tests.sh --integration brute    # enum flag: -brute (SQLite)
#   ./tests/run_tests.sh --integration alts     # enum flag: -alts  (SQLite)
#   ./tests/run_tests.sh --integration active   # enum flag: -active (SQLite)
#   ./tests/run_tests.sh --integration flags    # all three enum flag tests
#   ./tests/run_tests.sh --integration all      # all DB backends + all flag tests
#   ./tests/run_tests.sh --all                  # unit + all integration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

run_unit() {
    echo "=== Running unit tests ==="
    bats "$SCRIPT_DIR/unit/config_init.bats"
}

run_integration() {
    local backend="${1:-all}"
    local scripts=()

    case "$backend" in
        sqlite)   scripts=("$SCRIPT_DIR/integration/smoke_sqlite.sh") ;;
        postgres) scripts=("$SCRIPT_DIR/integration/smoke_postgres.sh") ;;
        neo4j)    scripts=("$SCRIPT_DIR/integration/smoke_neo4j.sh") ;;
        brute)    scripts=("$SCRIPT_DIR/integration/enum_brute.sh") ;;
        alts)     scripts=("$SCRIPT_DIR/integration/enum_alts.sh") ;;
        active)   scripts=("$SCRIPT_DIR/integration/enum_active.sh") ;;
        flags)
            scripts=(
                "$SCRIPT_DIR/integration/enum_brute.sh"
                "$SCRIPT_DIR/integration/enum_alts.sh"
                "$SCRIPT_DIR/integration/enum_active.sh"
            )
            ;;
        all)
            scripts=(
                "$SCRIPT_DIR/integration/smoke_sqlite.sh"
                "$SCRIPT_DIR/integration/smoke_postgres.sh"
                "$SCRIPT_DIR/integration/smoke_neo4j.sh"
                "$SCRIPT_DIR/integration/enum_brute.sh"
                "$SCRIPT_DIR/integration/enum_alts.sh"
                "$SCRIPT_DIR/integration/enum_active.sh"
            )
            ;;
        *)
            echo "Unknown target: $backend" >&2
            echo "Use: sqlite, postgres, neo4j, brute, alts, active, flags, or all" >&2
            exit 1
            ;;
    esac

    for s in "${scripts[@]}"; do
        echo "=== Running $(basename "$s") ==="
        bash "$s"
    done
}

# Default: unit only
MODE="unit"
BACKEND="all"

while [ $# -gt 0 ]; do
    case "$1" in
        --unit)          MODE="unit" ;;
        --integration)   MODE="integration"; BACKEND="${2:-all}"; shift ;;
        --all)           MODE="all" ;;
        *)               echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

case "$MODE" in
    unit)        run_unit ;;
    integration) run_integration "$BACKEND" ;;
    all)         run_unit; run_integration "all" ;;
esac
