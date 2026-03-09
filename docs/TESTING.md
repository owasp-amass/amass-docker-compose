# TESTING.md — Amass Docker Compose Test Suite

## Overview

The test suite lives in `tests/` and covers two layers:

| Layer | Tool | Speed | Requires Docker |
|---|---|---|---|
| **Unit** | bats | ~2 seconds | No |
| **Integration** | bash + docker compose | ~2 min per test | Yes |

Unit tests run `config/config-init.sh` directly on the host (no container). Integration tests spin up the real Docker stack, run a short `enum -d example.com -timeout 2` against it, and verify results were stored.

---

## Prerequisites

| Tool | Required for | Install |
|---|---|---|
| `bats` ≥ 1.5 | Unit tests | `apt install bats` or `brew install bats-core` |
| `sqlite3` | Integration (SQLite checks) | `apt install sqlite3` |
| `docker compose` ≥ v2 | Integration tests | Docker Desktop or Engine |
| `.env` file | Integration tests | See `README.md`; must not have default credentials |

---

## Running the Tests

All tests are driven by a single runner:

```bash
# From the repo root (~/Docker/amass or ~/Docker/amass-test):
./tests/run_tests.sh [OPTIONS]
```

### Options

| Command | What runs | Time |
|---|---|---|
| `./tests/run_tests.sh` | Unit tests only (default) | ~2s |
| `./tests/run_tests.sh --unit` | Unit tests only | ~2s |
| `./tests/run_tests.sh --integration sqlite` | SQLite backend smoke test | ~2 min |
| `./tests/run_tests.sh --integration postgres` | PostgreSQL backend smoke test | ~3 min |
| `./tests/run_tests.sh --integration neo4j` | Neo4j backend smoke test | ~5 min |
| `./tests/run_tests.sh --integration brute` | `-brute` flag test (SQLite) | ~2 min |
| `./tests/run_tests.sh --integration alts` | `-alts` flag test (SQLite) | ~2 min |
| `./tests/run_tests.sh --integration active` | `-active` flag test (SQLite) | ~2 min |
| `./tests/run_tests.sh --integration flags` | All three flag tests | ~6 min |
| `./tests/run_tests.sh --integration all` | All DB backends + all flag tests | ~16 min |
| `./tests/run_tests.sh --all` | Unit + all integration | ~16 min |

---

## When to Run Each Layer

**Before every commit to `harden-docker-compose`:**
```bash
./tests/run_tests.sh --unit
```
Unit tests are fast and catch regressions in `config-init.sh` without needing Docker.

**Before pushing to `origin` or opening a PR:**
```bash
./tests/run_tests.sh --unit
./tests/run_tests.sh --integration sqlite
./tests/run_tests.sh --integration flags
```
This covers: unit correctness + one full DB backend round-trip + all three enum modes. Takes ~10 minutes total.

**After changes to database configuration or `compose.yaml`:**
```bash
./tests/run_tests.sh --integration all
```
Run all backends to verify nothing broke across postgres, neo4j, and SQLite.

---

## Test Descriptions

### Unit Tests — `tests/unit/config_init.bats` (23 tests)

Tests `config/config-init.sh` in isolation by injecting a fake secrets file (`SECRETS_FILE` env var) and a temp config output path (`CONFIG_FILE` env var). No Docker or network access required.

| Group | Tests | What is verified |
|---|---|---|
| Guard checks | 3 | `AMASS_PASSWORD=ChangeMe!` → exit 1; `POSTGRES_PASSWORD=ChangeMe!` → exit 1; missing secrets file → non-zero exit |
| SQLite (default) | 4 | Both database lines commented; no active `${AMASS_*}` placeholders; config file is mode 644; `/graphql` suffix stripped from engine URL |
| Postgres | 6 | `postgres://` line uncommented; `bolt://` line commented; `AMASS_USER`, `AMASS_PASSWORD`, `AMASS_DB` substituted; no placeholders remain |
| Neo4j | 4 | `bolt://` line uncommented; `postgres://` line commented; `AMASS_PASSWORD` substituted; no placeholders remain |
| Profile exactness | 2 | `mypostgres` does not activate postgres (partial name match is rejected); `postgres,tor` activates postgres (unrelated profiles ignored) |
| Special characters | 2 | Pipe `\|` in password substituted correctly; ampersand `&` and backslash `\` substituted correctly |
| GraphQL stripping | 2 | Engine URL ending in `/graphql` has suffix stripped; URL without suffix is unchanged |

### Integration: DB Backend Smoke Tests

Each smoke test:
1. Writes a known-good `.env` with the target `COMPOSE_PROFILES`
2. Wipes any stale database state
3. Starts the stack with `docker compose up -d --wait`
4. Runs `enum -d example.com -timeout 2`
5. Queries the database to verify at least one FQDN was stored
6. Tears down the stack and restores `.env` on exit

| Script | Backend | Pass condition |
|---|---|---|
| `tests/integration/smoke_sqlite.sh` | SQLite | `asset.db` created; `SELECT COUNT(*) FROM fqdn` ≥ 1 |
| `tests/integration/smoke_postgres.sh` | PostgreSQL | `SELECT COUNT(*) FROM fqdn` via `docker exec assetdb psql` ≥ 1 |
| `tests/integration/smoke_neo4j.sh` | Neo4j | `MATCH (n:FQDN) RETURN count(n)` via `cypher-shell` ≥ 1 |

### Integration: Enum Flag Tests

Each flag test runs against SQLite (no external DB container needed). They verify the flag activates correctly and the engine stores results.

| Script | Flag | What is verified |
|---|---|---|
| `tests/integration/enum_brute.sh` | `-brute` | Brute-force using `wordlists/short-wordlist.txt`; `asset.db` created; `fqdn` count ≥ 1 |
| `tests/integration/enum_alts.sh` | `-alts` | Name alterations using `wordlists/alterations.txt`; `asset.db` created; `fqdn` count ≥ 1 |
| `tests/integration/enum_active.sh` | `-active` | Active recon (zone transfers, TLS cert pulls) against example.com; `asset.db` created; `fqdn` count ≥ 1 |

**Note on `-active` and example.com:** Zone transfers will be refused by example.com's authoritative nameservers — this is expected and not a failure. The test passes as long as enum exits 0 and at least one FQDN is stored.

---

## How Tests Affect the Running Stack

Integration tests are designed to be safe to run against a live `amass-test` stack:

- `.env` is saved to `.env.bak.$$` and restored on `EXIT` (even on error)
- `docker compose down --remove-orphans` runs on exit to clean up containers
- Each test wipes only the specific DB data it needs (e.g., `data/engine/asset.db` for SQLite, `assetdb/postgres/` for postgres)
- **Side effect**: any running stack is stopped during the test and not restarted afterward

If a test is interrupted mid-run (e.g., `Ctrl-C`), the `trap cleanup EXIT` still fires and restores `.env`. However, the stack may be left in a partially stopped state. Run `docker compose up -d` to restore it.

---

## Files

```
tests/
├── unit/
│   ├── config_init.bats         23 unit tests for config-init.sh
│   └── fixtures/
│       └── config.yaml          Config template used as test input
├── integration/
│   ├── smoke_sqlite.sh          SQLite backend smoke test
│   ├── smoke_postgres.sh        PostgreSQL backend smoke test
│   ├── smoke_neo4j.sh           Neo4j backend smoke test
│   ├── enum_brute.sh            -brute flag test (SQLite)
│   ├── enum_alts.sh             -alts flag test (SQLite)
│   └── enum_active.sh           -active flag test (SQLite)
├── helpers/
│   └── common.bash              Shared setup/teardown for bats tests
└── run_tests.sh                 Top-level runner

config/
└── config-init.sh               Production script under test
                                 (SECRETS_FILE and CONFIG_FILE env vars
                                  allow unit testing without Docker)
```
