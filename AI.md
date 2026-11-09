# Amass AI — one-command Docker Compose environment

This feature branch extends the **existing** `amass-docker-compose`
deployment. It preserves the original `compose.yaml` and adds
isolated development services for local or hosted inference, supervised
classification and a persistent MCP endpoint.

## Start the complete environment

In the existing **disposable feature-branch Compose checkout**:

```bash
git fetch origin feature/ai-investigation-inference
git merge --ff-only origin/feature/ai-investigation-inference
bash scripts/ai-up.sh
```

**The only startup command is `bash scripts/ai-up.sh`.** It:

1. Validates the isolated Compose configuration, creates necessary folders
   and generates a persistent secret under `data/ai/.mcp-token` when
   `AMASS_AI_MCP_TOKEN` is not already set.
2. Resolves the current Git commit SHA of **both** feature branches and
   supplies those revisions to Docker as build arguments. This prevents
   stale cached Go builds from hiding recently added binaries while
   retaining cache reuse for unchanged commits. Requires GitHub
   connectivity at startup.
3. If `data/classifier-training/labeled.jsonl` exists and is newer
   than `data/models/classifier.json`, trains the classifier and saves
   the versioned model. If no labeled data is available, starts deterministic **evidence triage**
   using the actual OAM provenance features supplied by the Amass graph adapter.
   Only genuinely trained models produce model-based scores.
4. Starts Ollama and pulls the configured model **only** when
   `AMASS_AI_ENDPOINT` targets the internal
   `http://ollama:11434/v1/chat/completions` endpoint.
   Otherwise it uses the configured HTTPS provider.
5. Starts PostgreSQL, the Amass engine, classifier, cached inference
   readiness checker and authenticated MCP HTTP service, then waits for
   the necessary health checks to pass.

Inference readiness means the configured provider and model returned a
**real response**, not just that the TCP socket was reachable. Health
polls consult a cached result and don't repeatedly run inference.
The external provider never determines which local classifier runs.

**Isolation:** Always test from a separate checkout with a separate
PostgreSQL data directory. The isolation overlay changes Docker
container names, network and host ports. The original environment is
not migrated. Published DB and MCP ports bind to `127.0.0.1` only.

## Check the complete stack

```bash
python3 scripts/ai-doctor.py
```

This checks the selected provider's cached successful inference,
reports whether the classifier has a trained model, and performs an
authenticated MCP `initialize` → `notifications/initialized` →
`tools/list` → session termination.

It does **not** scan the Internet or insert graph relationships.

For service status:

```bash
docker compose \
 -f compose.yaml -f compose.ai.yaml -f compose.ai-stack.yaml \
 -f compose.ai-isolation.yaml --profile ai ps
```

## Inference model configuration

Edit the **local** `.env` or export environment variables before
running `scripts/ai-up.sh`.

Local Ollama (default when no override is present):

```dotenv
AMASS_AI_PROVIDER=compatible
AMASS_AI_ENDPOINT=http://ollama:11434/v1/chat/completions
AMASS_AI_MODEL=qwen3:8b
AMASS_AI_MODEL_TIMEOUT=4m
AMASS_AI_INVESTIGATION_TIMEOUT=12m
```

The startup script opts into HTTP *only* for that trusted internal
Ollama hostname. Do not enable plaintext HTTP for external providers.

Example hosted OpenAI-compatible model:

```dotenv
AMASS_AI_PROVIDER=compatible
AMASS_AI_ENDPOINT=https://your-provider.example/v1/chat/completions
AMASS_AI_MODEL=your-authorized-model
AMASS_AI_API_KEY=your-secret
AMASS_AI_ALLOW_HTTP=false
```

Anthropic native Messages API:

```dotenv
AMASS_AI_PROVIDER=anthropic
AMASS_AI_ENDPOINT=https://api.anthropic.com/v1/messages
AMASS_AI_MODEL=your-authorized-anthropic-model
AMASS_AI_API_KEY=your-secret
AMASS_AI_ALLOW_HTTP=false
```

API keys should preferably be provided from a separate secured
environment/secrets mechanism rather than a Git-tracked file.
The provider-health service uses the **same** provider, endpoint,
model and credentials as the AI investigation client.

Standalone `amass ai` still supports `ai:` YAML settings, corresponding
environment variables, and command-line flags, with explicit flags
taking precedence. In this Compose stack, environment variables
select the deployment-wide provider.

## Classifier: trained or untrained, always running

The classifier is independent from Qwen3, Anthropic and other generative
providers. It runs as the `classifier` service on the private network
at `http://classifier:8092`. The CLI is configured to use it through
`AMASS_AI_CLASSIFIER_ENDPOINT` automatically; no local model file
needs to be opened by each CLI invocation.

- `GET /readyz` returns `trained: true` with the model ID when a
  valid JSON model artifact was loaded.
- Without an artifact, it returns `trained: false`,
  `mode: evidence_triage` and `routing: review_or_escalate`.
  This is deliberately **healthy**: it examines stored OAM evidence to
  route stronger-source-coverage candidates to human review, and otherwise
  escalates. It does not claim any learned probability or ownership result.
- `POST /v1/classify` takes an OAM feature vector and returns a triage
  prediction, never an accepted asset relationship.
- Invalid/incompatible model files fail startup rather than
  silently falling back.

### How to provide training data

Create `data/classifier-training/labeled.jsonl`. Each line represents
an **independently labeled** candidate investigation and a group
identifier that keeps the same case out of both train and validation
splits. Schema:

```json
{"group_id":"case-001","label":"potential_relation","features":{"distinct_sources":1.0,"evidence_count":0.75,"source_property_fraction":1.0,"unattributed_fraction":0.0}}
```

The other label is `unrelated`. All four features are required and
normalized between 0 and 1. The exact versioned feature extractor is
defined in `internal/ai/routing.go`. **Do not use the sample row as
ground truth.** The training data must come from analyst-reviewed
cases; repeated entries of the example would not create a useful
classifier.

Minimum dataset gate: 40 labeled examples, 20 distinct case groups,
at least eight held-out examples, and at least 10 training examples per
class. The trainer uses group-separated holdout data, reports
accuracy/precision/recall and emits a JSON linear model with the
`oam-provenance-v1` feature version.

```bash
bash scripts/ai-up.sh
```

That's all that's required for automatic training when the dataset
exists and is newer than the model. For a manual rebuild:

```bash
docker compose \
 -f compose.yaml -f compose.ai.yaml -f compose.ai-stack.yaml \
 -f compose.ai-isolation.yaml --profile ai-train \
 run --rm classifier-train
```

Then restart the classifier to load the new artifact, or simply
rerun `bash scripts/ai-up.sh`.

**Important:** The linear classifier currently produces
`uncalibrated_softmax` scores. It is a triage aid, *not* a verified
ownership model. The routing policy never automatically skips
relationships based on uncalibrated negative predictions, never
inserts an edge, and requires separate evidence for proposals.

## MCP server, automatically started

The persistent MCP endpoint is:

```text
http://127.0.0.1:18090/mcp
```

The default host port can be changed with `AMASS_AI_MCP_PORT`.
Use a Streamable HTTP-capable MCP client (protocol version
`2025-11-25`) with HTTP Authorization:

```text
Authorization: Bearer <token>
```

The randomly generated token is stored in
`data/ai/.mcp-token`; do not commit or print it in shared logs.
Alternatively, export `AMASS_AI_MCP_TOKEN` before startup. The
server requires a token, validates browser origins, maintains isolated
MCP sessions and exposes bounded **read-only OAM tools**.
The host binding is loopback-only by default; do not publish this
service directly to the public Internet.

The original stdio MCP is preserved as a separate opt-in service
`ai-mcp-stdio` (profile `ai-stdio`) for trusted local processes.

## AI investigations and existing tools

When the stack is healthy:

```bash
docker compose \
 -f compose.yaml -f compose.ai.yaml -f compose.ai-stack.yaml \
 -f compose.ai-isolation.yaml --profile ai-tools \
 run --rm ai \
 -question "Which organizations are connected to example.org?" \
 -format json ask
```

This uses the provider chosen at environment startup, plus the
independent classifier service for inference/scan triage.

Existing `enum`, `subs`, `assoc`, `track` and `viz` remain
available. Do not initiate Internet enumeration without explicit
authorization for the target. Test read-only lookups and legacy
command compatibility before collecting live data.

## Troubleshooting

If startup fails, inspect the relevant service:

```bash
docker compose \
 -f compose.yaml -f compose.ai.yaml -f compose.ai-stack.yaml \
 -f compose.ai-isolation.yaml logs --tail=100 \
 classifier provider-health ai-mcp ollama
```

An untrained classifier **should not block startup**; it uses default
OAM evidence-based review/escalation rules and reports that state explicitly. In contrast, an invalid model artifact, unreachable
configured inference provider, wrong model name, or missing MCP token
is a startup failure. The bearer token is generated by
`scripts/ai-up.sh`.

If the database is already initialized from the earlier runbook, the
script reuses the existing **test** database; it does not delete it.
Never run `down -v` or remove `assetdb/postgres` unless that test
data is genuinely disposable.

**Validation status:** The changes are committed on the feature
branches. Docker build and runtime readiness need execution on your
Docker host; no live endpoint or trained classifier quality has been
claimed validated without those checks.

## Default classifier and the data already in OAM

The default classifier is **enabled without a trained artifact**, without a
specific LLM, and without importing a separate dataset. During `amass ai scan`
and `amass ai infer`, Amass retrieves candidate evidence from the Asset
Database, verifies evidence identifiers, and extracts four bounded provenance
features: distinct source-tag count, evidence count, fraction of source
properties, and unattributed fraction. The independently deployed classifier
uses those features even when `data/models/classifier.json` is absent.

The default `oam-evidence-triage-v1` policy requires at least two distinct
source tags and sufficient attributed evidence to route a candidate to
**human review**. Other cases escalate for generative investigation when
warranted. It never uses raw source text as instructions, treats source-tag
counts as proof of independent evidence, makes ownership conclusions, or
writes trusted OAM relationships. Its `score_kind` is
`rules_no_probability` and its numerical score is zero.

This evidence triage does **not** train a machine-learning classifier from
raw Internet observations. Supervised training still requires separately
reviewed, appropriately labeled cases in
`data/classifier-training/labeled.jsonl`. When such data is supplied,
`scripts/ai-up.sh` trains and loads the local model automatically.

The classifier is used by candidate analysis (`scan` and `infer`).
Read-only `ask` uses deterministic OAM graph traversal and the source
provenance dossier; it does not produce ownership predictions merely
because a classifier service is running.

## Feature image build-cache troubleshooting

The development image previously cloned moving branch names within a cached
Docker layer. As a result, adding a new command to the Amass feature branch
could leave `/go/bin/amass-ai-mcp-http`,
`/go/bin/amass-ai-classifier`, `/go/bin/amass-ai-classifier-train`,
or `/go/bin/amass-ai-provider-health` missing from a cached builder.

**Fixed:** `scripts/resolve-ai-revisions.sh` queries the two remote
feature-branch HEADs with `git ls-remote`, validates their SHAs, and exports
`AMASS_AI_AMASS_SHA` and `AMASS_AI_ASSETDB_SHA`. Both are passed into
`Dockerfile.ai` and checked out explicitly. The builder now verifies every
required binary before the final-stage `COPY` operations. This should
invalidate precisely the source-dependent build layers when either branch
advances, without requiring `docker builder prune` or deleting volumes.

Always build using `bash scripts/ai-up.sh` or
`bash scripts/smoke-ai-image.sh`. Direct `docker compose build ai`
invocations intentionally fail if the immutable source revisions have not
been resolved. To inspect what revisions are selected without building:

```bash
source scripts/resolve-ai-revisions.sh
printf 'amass=%s\nasset-db=%s\n' "$AMASS_AI_AMASS_SHA" "$AMASS_AI_ASSETDB_SHA"
```

Do **not** run `docker compose down -v` or clear the PostgreSQL/Ollama
volumes to troubleshoot missing Go binaries; those resources are unrelated.
