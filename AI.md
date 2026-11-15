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
bash scripts/ai-connect.sh   # optional: connect your AI assistant (see below)
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
This matches the regular Amass `enum`, `assoc`, and `viz`
client-service convention. The classifier, provider checker, and
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

# The services stored for what a domain controls: ports, software,
# certificates, and unusual ports or expired certificates first
docker compose run --rm lens services -d jhu.edu

# The address space of what a domain controls: its netblocks and autonomous
# systems, where its names are hosted, and registered space no name uses
docker compose run --rm lens network -d jhu.edu

# DNS records that may point at something it no longer holds: possible
# subdomain takeovers, lapsed domains and stale addresses (leads to verify)
docker compose run --rm lens dangling -d jhu.edu

# What appeared since a date, and what later enumerations stopped seeing
docker compose run --rm lens changes -d jhu.edu -since 2026-11-01

# Posture: certificates, domain registrations, mail security, what is
# exposed, reliance on single providers, data gaps and geography
docker compose run --rm lens certificates -d jhu.edu
docker compose run --rm lens domains -d jhu.edu
docker compose run --rm lens email -d jhu.edu
docker compose run --rm lens exposure -d jhu.edu
docker compose run --rm lens concentration -d jhu.edu
docker compose run --rm lens coverage -d jhu.edu
docker compose run --rm lens geography -d jhu.edu

# What two organizations share: assets and outside parties
docker compose run --rm lens compare -d jhu.edu -with jhmi.edu

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

## Vulnerable software and lookalike domains

The `vulnerable` lens checks identified software versions against NVD's CVE
data and CISA's Known Exploited Vulnerabilities catalog, kept in
`data/vulnerabilities.json`. The `vuln-refresh` service, which
`scripts/ai-up.sh` starts, fetches it and refreshes it once a day; to fetch it
by hand:

```bash
docker compose run --rm vuln-update
docker compose run --rm lens vulnerable -d example.com
```

The first fetch takes a few minutes at NVD's rate limit for requests without
a key; a free NVD API key in `.env` (`NVD_API_KEY=...`) makes it faster.

The `lookalikes` lens reports registered domains one typing mistake from the
subject's. They are collected during any enumeration, since they need only
DNS queries (`docker compose run --rm enum -d example.com`):

```bash
docker compose run --rm lens lookalikes -d example.com
```

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

## Connect an AI assistant

After `bash scripts/ai-up.sh`, connect the assistant or agent you already
use:

```bash
bash scripts/ai-connect.sh --operator # connect detected assistants; they may also act (see below)
bash scripts/ai-connect.sh            # list detected assistants and offer to connect them read-only
bash scripts/ai-connect.sh cursor     # connect one (or several) by name
bash scripts/ai-connect.sh --list     # which are detected and connected
bash scripts/ai-connect.sh --check    # test the MCP endpoint and the stdio bridge
bash scripts/ai-connect.sh --remove claude-desktop
```

On Windows without a Bash shell, run `python scripts\ai-connect.py` with the
same arguments. Then restart or reload the assistant and ask, for example, "Using Amass,
what does example.com expose?". The server tells the assistant how to use
its tools, and assistants that show MCP prompts as commands list one per
lens (`amass_exposure`, `amass_email`, `amass_attack_surface_overview`,
...), each taking a domain or an organization's name.

| Client | `ai-connect.sh` name | How it connects |
| --- | --- | --- |
| Claude Code | `claude-code` | HTTP, through `claude mcp add` (user scope) |
| Claude Desktop | `claude-desktop` | stdio bridge (`docker exec` into `ai-mcp`) |
| Cursor | `cursor` | HTTP, `~/.cursor/mcp.json` |
| VS Code, GitHub Copilot agent mode (also Insiders, VSCodium) | `vscode` | HTTP, user `mcp.json` |
| Windsurf | `windsurf` | HTTP, `mcp_config.json` |
| Gemini CLI | `gemini-cli` | HTTP, `~/.gemini/settings.json` |
| OpenAI Codex CLI and IDE extension | `codex` | HTTP, `~/.codex/config.toml` |
| GitHub Copilot CLI | `copilot-cli` | HTTP, `~/.copilot/mcp-config.json` |
| Cline (CLI and VS Code) | `cline` | HTTP, `cline_mcp_settings.json` |
| Zed | `zed` | HTTP, `context_servers` in settings |
| LM Studio | `lm-studio` | HTTP, `~/.lmstudio/mcp.json` |
| opencode | `opencode` | HTTP, `opencode.json` |
| Kiro (IDE and CLI) | `kiro` | HTTP, `~/.kiro/settings/mcp.json` |
| goose, Continue, JetBrains AI Assistant | `goose`, `continue`, `jetbrains` | printed instructions to paste |
| Open WebUI | `open-webui` | bundled: `AMASS_AI_CHAT=true bash scripts/ai-up.sh`; or instructions for your own |
| Anything else that speaks MCP | `generic` | prints the URL, header and stdio command |

How it works:

- Clients that speak Streamable HTTP use the endpoint published on
  localhost, `http://127.0.0.1:18090/mcp`, with
  `Authorization: Bearer <contents of data/ai/.mcp-token>`.
- Clients that only start local commands get a stdio bridge,
  `docker exec -i amass-ai-test-ai-mcp-1 /bin/amass-ai-mcp ...`, which runs
  inside the already running `ai-mcp` container. Nothing is installed on
  the host, and Docker is named by its absolute path because desktop apps
  start commands with a short `PATH`.
- Each file is backed up (`<file>.amass-backup-<time>`) before it changes;
  other servers and settings are kept, and running the script again
  updates the entry instead of adding a second one. A JSON file with
  comments (Zed and VS Code settings often have them) keeps its comments
  when the entry is new; changing an existing entry in such a file needs
  `--force`.
- The token is written into each client's configuration, because desktop
  applications do not see shell variables. A new file is created readable
  only by you. After rotating the token, run the script again.
- Web assistants (Claude.ai, ChatGPT) connect only to remote MCP servers
  on a public HTTPS address with OAuth, so they cannot reach this local
  endpoint; run `bash scripts/ai-connect.sh web` for the details.

### Work entirely through the assistant (operator mode)

Connected with `--operator`, an assistant can run the whole workflow:

- **Collect.** Ask "enumerate example.com" or "what's new on example.com?";
  it plans the enumeration (`plan_enumeration`), shows you the exact scope
  and what it will do, and starts it (`start_enumeration`) only after you
  approve. Passive is the default; active collection (brute forcing, zone
  transfers, probing hosts) is a separate, clearly marked approval. One run
  can cover more targets ("enumerate example.com with AS64496 and
  192.0.2.0/24 in scope") and allow scope expansion when you ask for it;
  the approval names every target and whether the scope may expand. It can
  follow progress, stop a run, and tell you what a finished run found.
- **Ask.** Every lens and investigation, as above.
- **See.** "Draw what example.com controls" returns a diagram in the chat
  and a link to an interactive graph (and a Gephi file).
- **Report.** "Write an attack surface report for example.com" returns one
  Markdown report: key findings by priority, then each lens's results
  (`amass lens report -d example.com` on the command line).
- **Watch.** "Check example.com every week" re-runs the enumeration on that
  schedule after you approve it once, and tells you what each run found;
  it can list and stop watches.
- **Review.** It lists ownership, merge and identity proposals and approves,
  rejects or retracts them; anything that writes asks you first.
- **Configure.** It tells you which data sources lack API keys and gives
  you a one-time local link where you paste a key. Keys go from your
  browser to `config/datasources.yaml`, never through the assistant.

How you approve: assistants that support MCP approval dialogs (elicitation)
ask in their own window. Others give you a one-time link to
`http://127.0.0.1:18090/approve/...` showing the action, which happens
only when you press Approve. Nothing is collected or written before that.
Set `AMASS_AI_MCP_REQUIRE_CONFIRMATION=true` in `.env` to refuse actions
from clients that offer neither (stdio clients otherwise rely on their own
tool-approval prompt).

The operator token is `data/ai/.mcp-operator-token`; `bash scripts/ai-up.sh`
creates it. Runs are recorded in `data/ai/enumerations.jsonl`, at most two
run at once, and each stops after its work settles, 30 minutes without
progress, or 24 hours.

### Chat in the browser (Open WebUI)

No assistant installed? Start the optional chat profile:

```bash
AMASS_AI_CHAT=true bash scripts/ai-up.sh
```

Then open `http://127.0.0.1:18080`. Open WebUI runs on the stack's Ollama
model (or the Ollama on your computer when configured) with Amass
connected in operator mode; turn on the Amass tools for a chat from the
chat's tools menu. It is a single-user local install without a login;
set `AMASS_AI_CHAT_AUTH=true` before the first start to require accounts.
Data lives in `data/open-webui`. Open WebUI reads the Amass connection
from the environment on its first start; if you rotate the operator token,
update it in Admin Settings > Integrations. Small local models call tools
less reliably than large hosted ones; `qwen3:8b` or larger is recommended.

Read-only connections (without `--operator`) can read the Asset Database
but cannot change it or start an enumeration. Investigation
answers that need a model (`paths`) use the model configured for this
stack; every other answer is computed without one, so the assistant's own
model does the reasoning. The original stdio service also remains
available as `ai-mcp-stdio` behind the `ai-stdio` profile.

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

To see where time goes in the database:

- A lens run: add `-read-stats`, for example
  `docker compose run --rm lens services -d example.com -read-stats`.
- An enumeration: set `AMASS_DB_STATS=1` in `.env` and rerun
  `bash scripts/ai-up.sh`. When each session ends, the engine log lists its
  database calls by plugin and kind of call, the costliest first
  (`docker compose logs engine | grep "database calls"`).
- Sharing between enumerations: every session's DNS queries and waits on
  data source rate limits are logged by the engine every 10 minutes and
  when the session ends, so sessions running at the same time can be
  compared (`docker compose logs engine | grep "shared network use"`). The
  DNS resolvers and each source's rate limit are shared by all sessions, so
  each runs slower while others run; adding your own resolvers raises the
  capacity they share.

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
