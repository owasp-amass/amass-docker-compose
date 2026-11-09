# AI-enabled Amass: isolated Docker Compose test environment

This is the **feature-branch integration test runbook**, not a production
upgrade. The existing `compose.yaml` remains unchanged. Always include the
isolation overlay when testing in parallel with another Amass installation.

The development branch assembles these components:

| File | Function |
| --- | --- |
| `compose.yaml` | Existing engine, clients, PostgreSQL, syslog, libpostal |
| `compose.ai.yaml` | Opt-in `ai`, stdio `ai-mcp`, and `ollama` |
| `compose.ai-stack.yaml` | Switch existing engine/clients and Asset DB to matching feature branches |
| `compose.ai-isolation.yaml` | Unique Docker project/container/network names and non-conflicting published ports |
| `Dockerfile.ai` | Compile both feature branches into the same non-root Amass client/engine image |
| `.env.ai.example` | Model, image, UID/GID, and isolated-stack settings |
| `scripts/check-ai-compose.py` | Read-only Compose validation and isolation checks |
| `scripts/smoke-ai-image.sh` | Build image and inspect all legacy/AI executables without database startup |
| `scripts/check-ai-stack-ready.sh` | PostgreSQL/engine readiness and **model-free**, read-only asset lookup |

## Stage 0: prerequisites and isolation

Use Docker Compose **v2.24.4 or later** (required for `!override` in the
isolation overlay), Python 3, adequate disk/RAM for Go and Ollama, and
a fresh **disposable** checkout with a fresh database directory.

```bash
git clone --branch feature/ai-investigation-inference \
  https://github.com/owasp-amass/amass-docker-compose.git \
  amass-compose-ai-test
cd amass-compose-ai-test

docker compose version
mkdir -p data/ai data/ollama

# IMPORTANT: the checked-in .env and config/config.yaml contain
# illustrative credentials. Change BOTH before first DB initialization:
# .env -> POSTGRES_PASSWORD, AMASS_PASSWORD
# config/config.yaml -> options.database password (and username/database
# if changed). Use matching URL-encoded credentials in the Postgres URI.
#
# Review .env.ai.example. Append desired AMASS_AI_* and AMASS_TEST_*
# values to the LOCAL .env, or export them. Do NOT overwrite existing
# AMASS_DB, AMASS_USER, AMASS_PASSWORD, POSTGRES_PASSWORD values.
#
# On Linux, set AMASS_AI_UID=$(id -u) and AMASS_AI_GID=$(id -g)
# if your host bind-mounted data is not writable by UID 1000.
```

Do not point this environment at an existing PostgreSQL data directory.
Never run `docker compose down -v` against an important environment.
The isolation overlay changes the default `amass-net` network,
named containers, host DB port `55432` (now `55433` by default), and
Neo4j host ports. The DB test port binds only to `127.0.0.1`.
Adjust the `AMASS_TEST_*` values if these names/ports are already used.

## Stage 1: static preflight (no containers started)

```bash
python3 scripts/check-ai-compose.py

docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  --profile ai --profile ai-model config --quiet
```

This verifies merged Compose syntax, required services, image references,
unique container/network names, model isolation and read-only config.
`scripts/check-ai-compose.py` deliberately fails closed if Docker/Compose
or a required service is unavailable.

The feature branch also has a GitHub Actions static preflight. A manual
workflow-dispatch option can run the image smoke check; CI execution
status must be checked rather than assumed.

## Stage 2: image build and legacy CLI smoke (no DB started)

```bash
bash scripts/smoke-ai-image.sh
```

This builds `amass-ai:dev` from the matching Amass and Asset DB feature
branches, checks the executable bits of the existing `enum`, `subs`,
`assoc`, `viz`, `track`, `engine` and `ae_isready` binaries and the
new `amass` and `amass-ai-mcp`, then invokes `amass -version`.

It neither starts the engine nor performs collection or model inference.
Builds download Go modules and Git repositories; a network connection is
needed for compilation.

## Stage 3: isolated PostgreSQL and engine readiness

Start *only* the testing stack, always supplying all four files.

```bash
docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  up -d assetdb syslog postal engine

bash scripts/check-ai-stack-ready.sh
```

The readiness script verifies PostgreSQL and engine readiness and runs
the new **model-free** `amass ai search` against a deliberately absent
`.invalid` hostname. It must return an indexed `not_found` result.
No Internet enumeration or model inference occurs. If the fixture
hostname unexpectedly exists in the database, the script fails.

Check service logs before proceeding:

```bash
docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  logs --tail=100 assetdb engine
```

To check existing legacy command help in the same development image
without executing enumeration, run:

```bash
docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  run --rm --no-deps enum -h
```

The same command style applies to `subs`, `assoc`, `viz` and `track`.
Only initiate actual enumeration for targets you are authorized to assess.

## Stage 4: optional local inference via Ollama

Append the following to the **local** `.env` or export these variables:

```dotenv
AMASS_AI_PROVIDER=compatible
AMASS_AI_ENDPOINT=http://ollama:11434/v1/chat/completions
AMASS_AI_MODEL=qwen3:8b
AMASS_AI_ALLOW_HTTP=true
AMASS_AI_MODEL_TIMEOUT=4m
AMASS_AI_INVESTIGATION_TIMEOUT=12m
```

The model endpoint uses HTTP **only within the trusted, isolated Docker
network**. Remote providers must use HTTPS; do not expose the Ollama
container port on the host by default.

```bash
docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  --profile ai-model up -d ollama

docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  exec ollama ollama pull qwen3:8b
```

Once the database contains approved test data, invoke an investigation:

```bash
docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  --profile ai run --rm ai \
    -question 'Which organizations are connected to example.org?' \
    -format json ask
```

The `ai` service has `/bin/amass ai -config
/.config/amass/config.yaml` as its entrypoint and accepts ordinary
`amass ai` flags after it. The service uses the existing PostgreSQL
database and does not insert newly inferred relationships.

Configuration precedence is **explicit CLI flag > `AMASS_AI_*`
environment variable > top-level `ai:` YAML > built-in default**.

The optional `config/config.yaml` section is:

```yaml
ai:
  provider: compatible
  endpoint: http://ollama:11434/v1/chat/completions
  model: qwen3:8b
  allow_http: true
  model_timeout: 4m
  investigation_timeout: 12m
  depth: 8
  max_matches: 20
  max_paths_per_asset: 3
  max_expansions: 120
  guidance_rounds: 0
  classifier_review: false
```

For a local trained classifier, also mount its JSON file into the AI
service (for example under `./data/ai`) and set
`AMASS_AI_CLASSIFIER_MODEL=/data/classifier.json`. This is a local,
task-specific classifier for triage; it is not the generative Qwen model.
Untrained or task-incompatible classifiers must not be treated as
relationship evidence.

## Stage 5: legacy behavior, then authorized real-world data

After stages 1–4 pass, exercise the legacy `enum`, `subs`, `assoc`,
`track` and `viz` workflows against an explicitly authorized test
domain. Inspect the engine and Asset DB logs, compare graph outputs, and
only then run `amass ai ask` against the collected OAM graph.
Never rely on a synthetic test to assert that Internet collection,
attribution, or third-party source coverage has been validated.

## MCP note

`ai-mcp` is separately opt-in through profile `ai-mcp`, exposes
stdio only (no published listener), and requires a trusted client.
Avoid mixing Compose startup output into its JSON-RPC stdout.

## Cleanup

From this disposable checkout only:

```bash
docker compose \
  -f compose.yaml \
  -f compose.ai.yaml \
  -f compose.ai-stack.yaml \
  -f compose.ai-isolation.yaml \
  down
```

Bind-mounted test data remains on disk. Review data and backups before
removing any files. Never run cleanup commands from the original
non-test Compose checkout.

**Limitations:** The changes are committed, but a Docker daemon is
unavailable in the authoring environment. The scripts and Compose
integration require execution on a Docker host before being considered
operationally validated. No real-world target has yet been assessed.
