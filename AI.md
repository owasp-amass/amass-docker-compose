# Amass AI — single-file Docker Compose environment

The `feature/ai-investigation-inference` branch uses **one Docker Compose
file: `compose.yaml`**. It contains the original Amass subcommand services,
the `ai` subcommand, the independent classifier, the MCP HTTP server,
provider readiness checks, and optional Ollama.

**Important:** This is a disposable **feature-branch test deployment**.
The standard/release deployment on `main` is unchanged. The feature Compose
file retains the test project name `amass-ai-test`, the network
`amass-ai-test-net`, the existing test bind-mount paths, and loopback
PostgreSQL and MCP ports. It reuses your existing test database and models.

## Start everything

From your existing `amass-compose-ai-test` checkout:

```bash
git fetch origin feature/ai-investigation-inference
git merge --ff-only origin/feature/ai-investigation-inference

bash scripts/ai-up.sh
python3 scripts/ai-doctor.py
```

That's the entire setup. The startup script:

- Resolves current commit SHAs of both matching feature branches and
  builds the current Amass image without stale Docker source layers.
- Keeps the existing PostgreSQL test data and Ollama model volumes.
- Starts Ollama and fetches the requested model only when configured
  for internal Ollama. A configured HTTPS provider does not start Ollama.
- Runs the independently deployed classifier, using trained weights
  if present or safe OAM evidence-based triage otherwise.
- Starts the engine, PostgreSQL, libpostal, syslog, the provider checker
  and authenticated MCP Streamable HTTP endpoint.
- Waits for successful inference-provider and service health checks.
- Generates/reuses an MCP bearer token in `data/ai/.mcp-token`.
- Records the explicitly selected internal Ollama HTTP opt-in in
  the **local** `.env`, so ordinary one-file `docker compose run ai`
  commands work after the startup script exits.

No Internet enumeration or AI-derived database writes are performed by
startup. Keep your local `.env` and `data/` private. Never commit
credentials, model weights, or the MCP token.

## Amass subcommand services

The `ai` service is **not** an independent AI application: its entry point
is `/bin/amass ai -config /.config/amass/config.yaml`.
This matches the regular Amass `enum`, `subs`, `assoc`, `track`, and
`viz` client-service convention. The classifier, provider checker, and
MCP server are separate persistent supporting processes.

```bash
# Natural-language question, human-readable response
docker compose run --rm ai \
  -question "Which organizations are associated with owasp.org?" \
  -format text ask

# Full JSON investigation: OAM goal, witnessed graph paths, evidence,
# alternatives, and execution trace
docker compose run --rm ai \
  -question "What is the highest documented parent organization associated with owasp.org?" \
  -format json ask

# Mermaid graph source from the selected OAM paths
docker compose run --rm ai \
  -question "Which organizations are connected to owasp.org?" \
  -format mermaid ask

# Read-only indexed graph search; no LLM needed
docker compose run --rm ai \
  -subject-type FQDN -subject-field name -subject-value owasp.org \
  -target-types Organization -format json search

# Existing original subcommands
docker compose run --rm enum -h
docker compose run --rm subs -h
docker compose run --rm assoc -h
```

Answers reflect **only assets and observations already in the OAM database**.
Questions do not automatically authorize enumeration or assert true legal
ownership. The AI command may use deterministic schema grounding and graph
operations, or the configured LLM when real semantic interpretation is
needed. The default classifier evaluates existing OAM provenance for
`scan` and `infer` candidate triage; it does not silently replace
`ask`'s witnessed-path evidence analysis.

## Configuration

Settings live in the local `.env`, optional `ai:` settings inside
`config/config.yaml`, or explicit `amass ai` flags. CLI flags override
environment settings, which override the YAML section.

For local inference:

```dotenv
AMASS_AI_PROVIDER=compatible
AMASS_AI_ENDPOINT=http://ollama:11434/v1/chat/completions
AMASS_AI_MODEL=qwen3:8b
AMASS_AI_MODEL_TIMEOUT=4m
AMASS_AI_INVESTIGATION_TIMEOUT=12m
```

The startup script enables `AMASS_AI_ALLOW_HTTP=true` for the trusted
internal Ollama service only. Use HTTPS for any remote provider; never
expose the provider, classifier or database to the public Internet.
The MCP port is bound to `127.0.0.1:18090` by default.

## Classifier training

The classifier starts **by default**, regardless of the generative model.
It uses observed OAM provenance for deterministic human review/escalation
when supervised weights have not been trained. Its rule-based state
reports `trained: false`; it does not manufacture ownership
probabilities, infer ground-truth labels from source tags, or insert edges.

To train a supervised classifier, put independently analyst-labeled
JSONL examples at:

```text
data/classifier-training/labeled.jsonl
```

The feature extractor uses four normalized, versioned OAM provenance
fields: `distinct_sources`, `evidence_count`,
`source_property_fraction`, and `unattributed_fraction`.
Example **schema only** (not training ground truth):

```json
{"group_id":"case-001","label":"potential_relation","features":{"distinct_sources":1.0,"evidence_count":0.75,"source_property_fraction":1.0,"unattributed_fraction":0.0}}
```

A separately sourced `unrelated` class is also needed. The trainer
requires at least 40 examples, at least 20 independent groups and a
held-out split containing both classes. When labeled data is newer than
the model, `bash scripts/ai-up.sh` retrains and loads the model
automatically. Trained scores are **uncalibrated triage signals**, not
ownership verification.

## MCP

The persistent authenticated MCP HTTP endpoint is:

```text
http://127.0.0.1:18090/mcp
```

Use a Streamable HTTP MCP client with:

```text
Authorization: Bearer <contents of data/ai/.mcp-token>
```

The MCP implementation exposes bounded **read-only** OAM tools.
The original stdio MCP mode remains available as `ai-mcp-stdio`
behind the `ai-stdio` profile.

Check provider, classifier and MCP together without collecting data:

```bash
python3 scripts/ai-doctor.py
```

## Diagnostics

```bash
python3 scripts/check-ai-compose.py
bash scripts/check-ai-stack-ready.sh
docker compose ps
docker compose logs --tail=100 ai-mcp classifier provider-health engine assetdb
```

All commands now reference the **same `compose.yaml`**. The obsolete
`compose.ai.yaml`, `compose.ai-stack.yaml`, and
`compose.ai-isolation.yaml` overlays have been removed.

To stop the disposable stack without deleting data:

```bash
docker compose down
```

**Never use `docker compose down -v` to troubleshoot this test
environment unless you deliberately intend to discard its volumes.**

A successful Docker build, health check and local read-only query should
be validated on your host before making claims about actual Internet
collection or classifier accuracy.
