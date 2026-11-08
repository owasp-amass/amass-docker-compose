# AI-enabled Docker Compose testing (feature branch)

This repository already hosts the primary Amass Compose stack in
`compose.yaml`. Two opt-in overlays now allow AI testing without changing
the original service defaults.

**This is a development test environment, not a production deployment.**
Use a new Compose checkout and a fresh database for full-stack testing.
Do not point the feature Asset Database image at unbacked-up PostgreSQL
data. The existing PostgreSQL container and volumes contain useful data
that should be preserved independently.

## What's included

- `compose.yaml`: unchanged existing services, PostgreSQL, engine, enum,
  viz, subs, assoc, track, syslog and libpostal.
- `compose.ai.yaml`: profile `ai` provides one-shot read-only natural-
  language investigations, `ai-mcp` provides stdio MCP, and optional
  `ai-model` runs Ollama on the private Docker network.
- `Dockerfile.ai`: builds the matching
  `owasp-amass/amass` and `owasp-amass/asset-db`
  `feature/ai-investigation-inference` branches, with an ephemeral local
  Go module replacement (never committed to either repository).
- `compose.ai-stack.yaml`: explicit full-framework regression overlay
  using the same development Amass image for legacy tools and engine,
  and the feature Asset Database image. **Use on a disposable stack.**
- `.env.ai.example`: model and feature-image setting examples.
- `config/config.yaml`: optional commented-out `ai:` configuration.

**No model is contacted automatically**, and simply starting the
existing engine does not run inference or insert model-proposed edges.

## 1. Check out and configure

In a NEW disposable directory, separate from any currently running
production Compose instance:

```bash
git clone --branch feature/ai-investigation-inference \
  https://github.com/owasp-amass/amass-docker-compose.git \
  amass-compose-ai-test
cd amass-compose-ai-test

# Review .env.ai.example. Merge its AI settings into a LOCAL .env
# (or export the settings in your shell). Preserve/change database
# passwords and update config/config.yaml to match.
# Do not commit the resulting credentials.

mkdir -p data/ai data/ollama
docker compose -f compose.yaml -f compose.ai.yaml config --quiet
```

The baseline Compose file contains demo PostgreSQL credentials in
`config/config.yaml`; replace them with unique test credentials before
starting a new database. The same configured credentials must be
consistent with the local `.env`.

Set `AMASS_AI_ALLOW_HTTP=true` only if `AMASS_AI_ENDPOINT` points
to the trusted, private Compose network (e.g. `ollama`). For hosted
providers, use HTTPS and an approved key source.

## 2. Build AI-enabled image and start local model

```bash
docker compose -f compose.yaml -f compose.ai.yaml \
  --profile ai build --no-cache ai

docker compose -f compose.yaml -f compose.ai.yaml \
  --profile ai-model up -d ollama

# Download a local model once; the volume persists.
docker compose -f compose.yaml -f compose.ai.yaml \
  --profile ai-model exec ollama ollama pull qwen3:8b
```

The model port is *not published to the host*; `ai` reaches it at
`http://ollama:11434/v1/chat/completions` over the `amass` network.
Ollama model storage is under `data/ollama`. The Compose image
builder must have enough memory and disk space for Go compilation and
the local model.

## 3. Baseline legacy regression tests

Using a NEW test stack, test the existing published images first,
before switching all services to development builds:

```bash
docker compose up -d assetdb engine
docker compose run --rm enum -d example.org
docker compose run --rm subs -d example.org
```

Choose only authorized Internet domains for actual enumeration.
Use `docker compose logs --tail=100 engine assetdb` to check
collection/DB errors. Confirm normal `assoc`, `track` and `viz`
workflows with the commands appropriate to your dataset.

To run the same integration tests using feature-branch binaries,
select all three Compose files. **Only do this in the disposable
test checkout with backed-up or empty PostgreSQL data.** Do not
in-place upgrade a production Asset Database:

```bash
docker compose -f compose.yaml -f compose.ai.yaml \
  -f compose.ai-stack.yaml --profile ai build assetdb ai

docker compose -f compose.yaml -f compose.ai.yaml \
  -f compose.ai-stack.yaml --profile ai-model up -d \
  assetdb engine ollama

docker compose -f compose.yaml -f compose.ai.yaml \
  -f compose.ai-stack.yaml run --rm enum -d example.org

docker compose -f compose.yaml -f compose.ai.yaml \
  -f compose.ai-stack.yaml run --rm subs -d example.org
```

Additional existing clients (`assoc`, `track`, `viz`) use
the same feature image in this overlay. Check their CLI help
with `docker compose ... run --rm assoc -h` etc. The original
`compose.yaml` retains the published image and untouched
service definitions for easy comparison and rollback.

## 4. Run natural-language graph investigation

First make sure the database has been populated via authorized
enumeration. Then use the AI overlay. Configuration precedence for
`amass ai` is:

**explicit flags > AMASS_AI_* environment > top-level ai: YAML >
CLI defaults**.

For an internal Ollama service, set `AMASS_AI_ALLOW_HTTP=true` in
the local Compose `.env` (or pass `-allow-http` explicitly).
Model name, provider, endpoint and timeouts can be omitted from
the command when set in YAML or environment variables.

```bash
docker compose -f compose.yaml -f compose.ai.yaml \
  --profile ai run --rm ai \
  -question "Which organizations are connected to example.org?" \
  -format json ask
```

For the full development stack, add
`-f compose.ai-stack.yaml` to the command above.

Sample explicit overrides:

```bash
docker compose -f compose.yaml -f compose.ai.yaml \
  --profile ai run --rm ai \
  -provider compatible \
  -endpoint http://ollama:11434/v1/chat/completions \
  -allow-http \
  -model qwen3:8b \
  -model-timeout 4m \
  -investigation-timeout 12m \
  -question "What services are associated with example.org?" ask
```

The OAM database is read-only for `ask` and `search`. Internet data
collection remains an explicitly authorized workflow. Generated
hypotheses are not auto-inserted into the database.

## 5. Optional typed YAML configuration

The `ai:` section may appear at the root of
`config/config.yaml`. It is ignored by existing collection tools.

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
  classifier_model: /data/classifier.json
  classifier_review: false
```

The local `classifier_model` is an optional **trained** linear
classifier file for review-only triage; it is not another generative
model provider. Invalid/untrained classifier files must not be used to
assert relationships. To provide the model from the host, mount the
directory and set the file path inside the container.

Environment equivalents are described in `.env.ai.example`.
Do not put API tokens into the committed YAML or Compose files.

## 6. Test isolation, security, and limits

- Development images are rebuilt from moving feature branches.
  Rebuild with `--no-cache` after new commits. Pin commit SHAs for
  reproducible long-running evaluations.
- Do not run the full-stack feature overlay on a production PostgreSQL
  volume; schema changes may make rollback impossible.
- PostgreSQL and model traffic are on the shared test Compose network.
  The baseline stack exposes PostgreSQL on port 55432; isolate the
  test machine/network as necessary.
- Local inference may consume significant RAM/CPU; large real-world
  graphs require resource budgets, evidence limits, and an appropriate
  model serving capacity.
- There is no persistent AI worker in this milestone. Inference and
  proposals run only when the user invokes a command.
- `docker compose config --quiet` validates the merged Compose
  syntax. CI/build/runtime execution must still be verified on a host
  with Docker available.

## MCP mode

`ai-mcp` remains an opt-in stdio service. It exposes no network
port and is intended for a trusted local client.

```bash
docker compose -f compose.yaml -f compose.ai.yaml \
  up -d assetdb
docker compose -f compose.yaml -f compose.ai.yaml \
  --profile ai-mcp run --rm --no-deps -T ai-mcp
```

Avoid mixing MCP JSON-RPC stdout with Compose startup logs.
