#!/usr/bin/env bats
# Unit tests for config/config-init.sh
# Requires: bats >= 1.5, no Docker needed.
# Run: bats tests/unit/config_init.bats

load '../helpers/common'

setup()    { :; }
teardown() { teardown_fixture; }

# ---------------------------------------------------------------------------
# Guard checks
# ---------------------------------------------------------------------------

@test "guard: AMASS_PASSWORD=ChangeMe! causes exit 1" {
    setup_fixture "" "ChangeMe!" "pgpass"
    run run_init
    [ "$status" -eq 1 ]
    [[ "$output" == *"AMASS_PASSWORD"* ]]
}

@test "guard: POSTGRES_PASSWORD=ChangeMe! causes exit 1" {
    setup_fixture "" "testpass" "ChangeMe!"
    run run_init
    [ "$status" -eq 1 ]
    [[ "$output" == *"POSTGRES_PASSWORD"* ]]
}

@test "guard: missing SECRETS_FILE causes non-zero exit" {
    setup_fixture ""
    export SECRETS_FILE="/nonexistent/secrets"
    run run_init
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# SQLite (default — no postgres or neo4j in COMPOSE_PROFILES)
# ---------------------------------------------------------------------------

@test "sqlite: both database lines are commented out" {
    setup_fixture ""
    run run_init
    [ "$status" -eq 0 ]
    # Neither database line should be active
    run grep -E '^  database:' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

@test "sqlite: no credential placeholders in active (non-commented) lines" {
    setup_fixture ""
    run run_init
    [ "$status" -eq 0 ]
    # DB lines are commented out; check only uncommented lines for stray placeholders
    run bash -c "grep -v '^[[:space:]]*#' '$CONFIG_FILE' | grep '\\\${AMASS_'"
    [ "$status" -ne 0 ]
}

@test "sqlite: config.yaml is mode 644" {
    setup_fixture ""
    run run_init
    [ "$status" -eq 0 ]
    perms="$(stat -c '%a' "$CONFIG_FILE")"
    [ "$perms" = "644" ]
}

@test "sqlite: graphql suffix stripped from engine URL" {
    setup_fixture ""
    # Inject /graphql into the engine line in the fixture
    sed -i 's|engine: "http://engine:4000"|engine: "http://engine:4000/graphql"|' "$CONFIG_FILE"
    run run_init
    [ "$status" -eq 0 ]
    run grep '/graphql' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Postgres
# ---------------------------------------------------------------------------

@test "postgres: postgres:// line is uncommented" {
    setup_fixture "postgres"
    run run_init
    [ "$status" -eq 0 ]
    run grep -E '^  database: "postgres://' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

@test "postgres: bolt:// line is commented out" {
    setup_fixture "postgres"
    run run_init
    [ "$status" -eq 0 ]
    run grep -E '^  database: "bolt://' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

@test "postgres: AMASS_USER substituted" {
    setup_fixture "postgres"
    run run_init
    [ "$status" -eq 0 ]
    # postgres URL becomes postgres://amass:testpass@assetdb:5432/testdb
    run grep '//amass:' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

@test "postgres: AMASS_PASSWORD substituted" {
    setup_fixture "postgres"
    run run_init
    [ "$status" -eq 0 ]
    run grep 'testpass@' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

@test "postgres: AMASS_DB substituted" {
    setup_fixture "postgres"
    run run_init
    [ "$status" -eq 0 ]
    run grep 'testdb' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

@test "postgres: no credential placeholders remain" {
    setup_fixture "postgres"
    run run_init
    [ "$status" -eq 0 ]
    run grep '\${AMASS_' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Neo4j
# ---------------------------------------------------------------------------

@test "neo4j: bolt:// line is uncommented" {
    setup_fixture "neo4j"
    run run_init
    [ "$status" -eq 0 ]
    run grep -E '^  database: "bolt://' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

@test "neo4j: postgres:// line is commented out" {
    setup_fixture "neo4j"
    run run_init
    [ "$status" -eq 0 ]
    run grep -E '^  database: "postgres://' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

@test "neo4j: AMASS_PASSWORD substituted" {
    setup_fixture "neo4j"
    run run_init
    [ "$status" -eq 0 ]
    run grep 'testpass@' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

@test "neo4j: no credential placeholders remain" {
    setup_fixture "neo4j"
    run run_init
    [ "$status" -eq 0 ]
    run grep '\${AMASS_' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Profile exactness
# ---------------------------------------------------------------------------

@test "profile: 'mypostgres' does not activate postgres (falls through to sqlite)" {
    setup_fixture "mypostgres"
    run run_init
    [ "$status" -eq 0 ]
    run grep -E '^  database: "postgres://' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

@test "profile: 'postgres,tor' activates postgres (other profiles ignored)" {
    setup_fixture "postgres,tor"
    run run_init
    [ "$status" -eq 0 ]
    run grep -E '^  database: "postgres://' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Special characters in credentials
# ---------------------------------------------------------------------------

@test "special chars: pipe '|' in password is substituted correctly" {
    setup_fixture "postgres" 'pass|word' "pgpass"
    run run_init
    [ "$status" -eq 0 ]
    run grep 'pass|word' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
    run grep '\${AMASS_PASSWORD}' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

@test "special chars: ampersand '&' and backslash in password are substituted correctly" {
    setup_fixture "postgres" 'pass&\word' "pgpass"
    run run_init
    [ "$status" -eq 0 ]
    run grep '\${AMASS_PASSWORD}' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# GraphQL stripping
# ---------------------------------------------------------------------------

@test "graphql: /graphql suffix is stripped from engine URL" {
    setup_fixture ""
    sed -i 's|engine: "http://engine:4000"|engine: "http://engine:4000/graphql"|' "$CONFIG_FILE"
    run run_init
    [ "$status" -eq 0 ]
    run grep '/graphql' "$CONFIG_FILE"
    [ "$status" -ne 0 ]
    run grep 'engine: "http://engine:4000"' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}

@test "graphql: URL without /graphql is unchanged" {
    setup_fixture ""
    run run_init
    [ "$status" -eq 0 ]
    run grep 'engine: "http://engine:4000"' "$CONFIG_FILE"
    [ "$status" -eq 0 ]
}
