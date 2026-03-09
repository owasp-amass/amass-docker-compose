#!/usr/bin/env bash
# Shared setup/teardown helpers for bats unit tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_INIT="$REPO_ROOT/config/config-init.sh"
FIXTURE="$SCRIPT_DIR/../unit/fixtures/config.yaml"

# setup_fixture COMPOSE_PROFILES [AMASS_PASSWORD] [POSTGRES_PASSWORD]
#   Creates a temp working dir, copies the config fixture, writes a fake secrets file.
#   Exports WORK_DIR, CONFIG_FILE, SECRETS_FILE, COMPOSE_PROFILES.
setup_fixture() {
    local profiles="${1:-}"
    local amass_pass="${2:-testpass}"
    local pg_pass="${3:-pgpass}"

    export WORK_DIR
    WORK_DIR="$(mktemp -d)"
    export CONFIG_FILE="$WORK_DIR/config.yaml"
    cp "$FIXTURE" "$CONFIG_FILE"

    export SECRETS_FILE="$WORK_DIR/secrets"
    # Use %q so shell metacharacters in passwords (|, &, \) are properly escaped
    # when the secrets file is sourced by config-init.sh.
    {
        printf 'AMASS_USER=amass\n'
        printf 'AMASS_PASSWORD=%q\n' "$amass_pass"
        printf 'AMASS_DB=testdb\n'
        printf 'POSTGRES_PASSWORD=%q\n' "$pg_pass"
        printf 'COMPOSE_PROFILES=%s\n' "$profiles"
    } > "$SECRETS_FILE"
}

teardown_fixture() {
    rm -rf "${WORK_DIR:-}"
}

# run_init — wrapper: run config-init.sh under the current SECRETS_FILE/CONFIG_FILE
run_init() {
    bash "$CONFIG_INIT"
}
