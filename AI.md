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

## Use Ollama on the host for GPU speed (recommended on macOS)

Docker Desktop containers cannot use the Mac's GPU, so the in-Docker
Ollama runs models on the CPU, and an 8B model can take minutes per
request. Ollama installed directly on macOS uses Metal and is typically
an order of magnitude faster. To use it:

1. Install and start Ollama on the Mac (the Ollama app, or `ollama serve`).
2. Add to `.env` (with a leading newline, as below):

   ```bash
   printf '\nAMASS_AI_PROVIDER=ollama\nAMASS_AI_ENDPOINT=http://host.docker.internal:11434\n' >> .env
   ```

3. Run `bash scripts/ai-up.sh`. It checks that the host Ollama answers on
   `127.0.0.1:11434`, pulls the configured model there if it is missing,
   stops the in-Docker Ollama and starts the rest of the stack. Containers
   reach the host through `host.docker.internal`.

Remove the two lines to go back to the in-Docker Ollama.

## Test a local Amass checkout before pushing

Set `AMASS_AI_LOCAL_AMASS` to a local Amass checkout and the startup script
builds the image from it, including uncommitted edits, instead of cloning the
GitHub branch. Asset Database is still cloned at the resolved
`feature/ai-investigation-inference` commit.

```bash
# Once, from this checkout (paths are relative to it):
# The leading \n keeps it off the end of a last line that has no newline.
printf '\nAMASS_AI_LOCAL_AMASS=../amass\n' >> .env

bash scripts/ai-up.sh          # prints "Building LOCAL amass ... (<commit>, branch ...)"
```

Rerun `bash scripts/ai-up.sh` after changing the Amass checkout; Docker
rebuilds only when copied files change. Plain `docker compose build` or
`up --build` does not apply the overlay and would rebuild from GitHub, so
rebuild through the script, or pass both files:

```bash
docker compose -f compose.yaml -f compose.local-src.yaml build ai
```

Remove the `.env` line (or unset the variable) to return to GitHub builds.

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

# Vendors and controlled assets, answered from the relationship semantics
docker compose run --rm ai \
  -question "Which third-party vendors are used by owasp.org?" -format text ask
docker compose run --rm ai \
  -question "Which netblocks does the OWASP Foundation organization have?" -format text ask

# Run the question evaluation set (every reported question) against your
# model and Asset Database; prints pass/fail per case
docker compose run --rm ai eval

# Read-only indexed graph search; no LLM needed
docker compose run --rm ai \
  -subject-type FQDN -subject-field name -subject-value owasp.org \
  -target-types Organization -format json search

# Existing original subcommands
docker compose run --rm enum -h
docker compose run --rm subs -h
docker compose run --rm assoc -h
```

For an exact, schema-grounded cross-type relationship inventory, you can also
name the OAM labels explicitly:

```bash
docker compose run --rm ai \
  -question "Which URLs are connected to tech.acme.example via domain relationships?" \
  -format json ask
```

This compiles the query into stored-direction OAM hops when the schema
contains a unique valid route. Different asset types and multiple
relationship labels are supported; ambiguous routes fall back to the
normal LLM planner. The schema-grounded typed engine returns only
witnessed edges and explicitly reports truncated inventories. The
supported grammar and caveats are described in
[Amass intent routing documentation](https://github.com/owasp-amass/amass/blob/feature/ai-investigation-inference/docs/ai/INTENT_ROUTING.md).

Answers reflect **only assets and observations already in the OAM database**.
Questions do not automatically authorize enumeration or assert true legal
ownership. The AI command may use deterministic schema grounding and graph
operations, or the configured LLM when real semantic interpretation is
needed. The default classifier evaluates existing OAM provenance for
`scan` and `infer` candidate triage; it does not silently replace
`ask`'s witnessed-path evidence analysis.

## Ownership attribution during enumeration

Every `enum` run now records the ownership the evidence supports without a
question or a model. The engine's AI-Attribution plugin watches the
session's in-scope organizations and, as registration contacts, names,
addresses and certificates arrive, finds assets whose owner is not
documented. When the evidence is strong (shared registrant details, or
registrant details plus hosting or a shared certificate), it writes the
missing relationship, using only relationships OAM defines, tagged with
the `amass-ai` source and a confidence. The assets that brings in join the
enumeration's scope, the same way Horizontals widens it. Weaker proposals
wait in the review journal, `data/ai/ai-review.jsonl`.

```bash
# Proposals and what was written automatically, with their evidence
docker compose run --rm review proposals

# Review a proposal, or undo one written automatically
docker compose run --rm review approve -proposal own-1a2b3c4d5e6f7a8b -reviewer you
docker compose run --rm review reject -proposal own-1a2b3c4d5e6f7a8b -reviewer you
docker compose run --rm review retract -proposal own-1a2b3c4d5e6f7a8b -reviewer you

# Ask the model for a cited recommendation on each waiting proposal;
# advice is shown by "proposals" and never decides anything itself
docker compose run --rm ai review

# After reviewing 40 or more proposals, learn the weights from your decisions;
# the engine uses data/ai/attribution-model.json from the next enumeration
docker compose run --rm ai train-attribution
```

A rejected or retracted proposal is never written again. Set
`AMASS_AI_ATTRIBUTION=journal` in `.env` to have the engine write nothing
and journal every proposal for review, or `off` to disable attribution,
then recreate the engine with `docker compose up -d engine`. Details are in
[Ownership gaps](https://github.com/owasp-amass/amass/blob/feature/ai-investigation-inference/docs/ai/OWNERSHIP_GAPS.md).

## Lenses: families, vendors, corporate groups, duplicates and identities

The `lens` and `review` services run `amass lens` and `amass review` with the
same image and journal. Lenses answer from the stored evidence without a
language model and write nothing to the Asset Database; what they find that
should change it becomes a proposal for `review`.

```bash
# The organizations behind a domain: the same institution under other names,
# departments and affiliates, with the networks and other domains serving it
docker compose run --rm lens family -d jhu.edu

# The outside parties a domain and its organization depend on: registrars,
# DNS and hosting providers, certificate authorities, SaaS verified in DNS
# TXT records and mail senders authorized by SPF
docker compose run --rm lens vendors -d jhu.edu

# An organization's corporate group (parent, subsidiaries and units), and
# the vendors used across the whole group
docker compose run --rm lens org-group -d spotify.com
docker compose run --rm lens group-vendors -org "Spotify AB"

# Large institutions can reach the per-run limits; raise them for one run
docker compose run --rm lens vendors -d nasa.gov -max-assets 10000 -max-reads 100000 -investigation-timeout 20m

# Organizations stored more than once, and legal identities that contradict
# their organization's evidence; both are recorded as proposals
docker compose run --rm lens duplicates
docker compose run --rm lens identity

# Approve a merge or a correction; retract undoes either
docker compose run --rm review approve -proposal dup-1a2b3c4d5e6f7a8b -reviewer you
docker compose run --rm review retract -proposal dup-1a2b3c4d5e6f7a8b -reviewer you

# Why each signal counts
docker compose run --rm review signals
docker compose run --rm review duplicate-signals
```

When enumerations finish, the engine records duplicate organizations and
contradicted identities in the journal, and with `AMASS_AI_ATTRIBUTION=auto`
merges the proposed duplicates once no enumeration is still running.
Identity corrections always wait for a person. Details are in
[Lenses and review](https://github.com/owasp-amass/amass/blob/feature/ai-investigation-inference/docs/LENSES.md).
The older `docker compose run --rm ai proposals` style still works and
prints the new command.

## Configuration

Settings live in the local `.env`, optional `ai:` settings inside
`config/config.yaml`, or explicit `amass ai` flags. CLI flags override
environment settings, which override the YAML section.

For local inference:

```dotenv
AMASS_AI_PROVIDER=ollama
AMASS_AI_ENDPOINT=http://ollama:11434
AMASS_AI_MODEL=qwen3:8b
AMASS_AI_THINK=false
AMASS_AI_CONTEXT_TOKENS=8192
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

To stop **all** AI test containers, including the separately profiled
local Ollama service, without deleting data:

```bash
bash scripts/ai-down.sh
```

The startup script now records `COMPOSE_PROFILES=ai-local` in your **local**
`.env` when using the internal Ollama provider. This makes
`docker compose down` from a fresh shell profile-aware as well.
If you were using an older `.env`, one-time cleanup is:

```bash
docker compose --profile ai-local down
```

If Docker still reports `Resource is still in use`, inspect which
container holds the project's network rather than force-disconnecting
it or deleting storage:

```bash
docker ps -a --filter network=amass-ai-test-net \
  --format 'table {{.Names}}\\t{{.Status}}'
```

One-off `docker compose run` containers interrupted before `--rm`
completed, external tooling attached to the bridge, and profiled
containers can all retain the network. The normal `down` command
does **not** delete your bind-mounted PostgreSQL or Ollama data.

**Never use `docker compose down -v` to troubleshoot this test
environment unless you deliberately intend to discard its volumes.**

A successful Docker build, health check and local read-only query should
be validated on your host before making claims about actual Internet
collection or classifier accuracy.

## Docker Desktop storage exhaustion during the Go build

If the image build fails with `/usr/local/go/pkg/tool/linux_arm64/link:
mapping output file failed: no space left on device`, the **Docker build
filesystem** has exhausted its available space while linking Amass or
the engine. The exact error is not a Go type-checking problem and does
not implicate PostgreSQL or Ollama.

The feature Dockerfile now uses `go install -p 1 -trimpath
-ldflags="-s -w" ./...` with constrained parallelism, lowering
concurrent linker peak disk usage and resulting binary sizes. It cannot
guarantee success if the Docker Desktop disk image has insufficient
free space.

Inspect consumption without deleting anything:

```bash
docker system df -v
docker buildx du
df -h
```

On Docker Desktop for macOS, inspect **Settings → Resources → Advanced**
for the Docker disk image size and available capacity. The macOS host
may have sufficient free space even though Docker's Linux VM or
BuildKit storage is full. Increase Docker's disk allocation if
necessary and available.

If you need to reclaim disk space, first inspect which BuildKit
caches and images are in use. `docker builder prune` deletes *unused
build cache*, not the PostgreSQL/Ollama bind mounts, but requires
explicit review when sharing Docker with other development projects:
it may cause other projects to rebuild. Avoid automatic `docker
system prune -a`, `docker volume prune`, or `docker compose down -v`
in this environment.

After allocating sufficient Docker space, simply rerun
`bash scripts/ai-up.sh`. The resolved source revisions make the
feature-image rebuild reproducible. No model download or database
reset is required.
