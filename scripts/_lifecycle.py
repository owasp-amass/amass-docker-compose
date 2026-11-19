# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0

"""Shared logic for the turnkey, cross-platform ``up`` / ``down`` scripts.

A single Python implementation (like ``ai-connect.py``) so Windows, macOS and
Linux all start and stop the isolated feature-branch stack the same way. This
module ports ``ai-up.sh``, ``ai-down.sh`` and ``resolve-ai-revisions.sh``;
``up.py`` and ``down.py`` are thin front ends over ``up_main`` / ``down_main``.

The toggle is the *LLM* layer, not "AI". The classifier is a model but not an
LLM: it is cheap and always useful, so it is part of the always-on core. Only
the LLM services (provider-health, mcp, ollama, open-webui) are gated by the
toggle, which is stored in ``.env`` as ``AMASS_LLM=true|false`` (name kept for
compatibility; it means "LLM-powered features").
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

# The repo root is the parent of this scripts/ directory. Every path and every
# docker/compose invocation is anchored here, so the wrappers can be launched
# from anywhere.
ROOT = Path(__file__).resolve().parent.parent

# The always-on core: collection and the classifier model, no LLM.
CORE_SERVICES = ["assetdb", "syslog", "postal", "engine", "classifier"]
# The LLM layer, started only when LLM-powered features are enabled.
LLM_SERVICES = ["provider-health", "mcp"]

DEFAULT_FEATURE_BRANCH = "feature/ai-investigation-inference"
INTERNAL_OLLAMA = "http://ollama:11434"
HOST_OLLAMA = "http://host.docker.internal:11434"


# --------------------------------------------------------------------------- #
# Small cross-platform helpers
# --------------------------------------------------------------------------- #
def fail(message: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def have(command: str) -> bool:
    return shutil.which(command) is not None


def run(cmd, **kwargs):
    """Run a command anchored at the repo root, inheriting the environment."""
    kwargs.setdefault("cwd", ROOT)
    return subprocess.run(cmd, **kwargs)


def check_prerequisites() -> None:
    for command in ("docker",):
        if not have(command):
            fail(f"{command} is required")
    if run(["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        fail("Docker daemon is not available")


# --------------------------------------------------------------------------- #
# .env read / write (never executes .env; only literal KEY=value lines)
# --------------------------------------------------------------------------- #
def dotenv_path() -> Path:
    return ROOT / ".env"


def read_dotenv_value(key: str) -> str:
    """Return the literal value of ``key`` in .env, or "" (quotes stripped)."""
    path = dotenv_path()
    if not path.exists():
        return ""
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith(key + "="):
            value = line.split("=", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("\"", "'"):
                value = value[1:-1]
            return value
    return ""


def resolve_setting(key: str, default: str = "") -> str:
    """Exported environment wins over .env, matching Compose precedence."""
    value = os.environ.get(key, "")
    if value:
        return value
    value = read_dotenv_value(key)
    return value if value else default


def set_dotenv_values(values: dict) -> None:
    """Create/replace each KEY in .env in place; leave every other line as-is.

    Keys whose value is "" are removed (except those listed in KEEP_EMPTY, which
    Compose still needs declared). Rewrites only on an actual change.
    """
    keep_empty = {"AMASS_LLM_ALLOW_HTTP", "COMPOSE_PROFILES"}
    path = dotenv_path()
    lines = path.read_text().splitlines() if path.exists() else []
    written = set()
    updated = []
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in values:
            if key not in written and (values[key] != "" or key in keep_empty):
                updated.append(f"{key}={values[key]}")
            written.add(key)
        else:
            updated.append(line)
    for key, value in values.items():
        if key not in written and (value != "" or key in keep_empty):
            updated.append(f"{key}={value}")
    after = "\n".join(updated).rstrip() + "\n"
    if not path.exists() or path.read_text() != after:
        path.write_text(after)


def is_truthy(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on")


# --------------------------------------------------------------------------- #
# LLM toggle: flag > .env AMASS_LLM > interactive first-run prompt (default No)
# --------------------------------------------------------------------------- #
def resolve_llm_enabled(args) -> bool:
    if args.llm is True:
        enabled = True
    elif args.llm is False:
        enabled = False
    else:
        stored = read_dotenv_value("AMASS_LLM")
        if stored != "":
            enabled = is_truthy(stored)
        elif sys.stdin.isatty():
            print("Amass runs collection and the always-on classifier with no LLM by default.")
            print("LLM-powered features add local/hosted model inference, the MCP server for")
            print("AI assistants, and the optional chat UI. You can change this later with")
            print("  ./scripts/up --llm    (enable)   or   ./scripts/up --no-llm   (disable)")
            try:
                answer = input("Enable LLM-powered features? [y/N] ").strip().lower()
            except EOFError:
                answer = ""
            enabled = answer in ("y", "yes")
        else:
            print("No AMASS_LLM setting and no terminal to prompt; starting WITHOUT LLM features.")
            print("Re-run with --llm to enable them.")
            enabled = False
    # Persist the resolved choice so later runs are non-interactive.
    set_dotenv_values({"AMASS_LLM": "true" if enabled else "false"})
    return enabled


# --------------------------------------------------------------------------- #
# Branch / revision resolution (port of resolve-ai-revisions.sh)
# --------------------------------------------------------------------------- #
def valid_branch(branch: str) -> bool:
    if not have("git"):
        fail("git is required to resolve feature-branch revisions")
    return run(
        ["git", "check-ref-format", "--branch", branch],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def resolve_remote_sha(repository: str, branch: str, name: str) -> str:
    if not valid_branch(branch):
        fail(f"invalid {name} branch name: {branch}")
    url = f"https://github.com/owasp-amass/{repository}.git"
    proc = run(
        ["git", "ls-remote", "--exit-code", url, f"refs/heads/{branch}"],
        capture_output=True, text=True,
    )
    if proc.returncode or not proc.stdout.strip():
        fail(f"cannot resolve {repository} branch {branch}. "
             "Check network access and branch spelling.")
    parts = proc.stdout.split()
    sha = parts[0]
    ref = parts[1] if len(parts) > 1 else ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or ref != f"refs/heads/{branch}":
        fail(f"unexpected Git reference returned for {repository}:{branch}")
    return sha


def guard_glued_env_key() -> None:
    """Refuse a .env whose AMASS_AI_* key was appended without a leading newline."""
    path = dotenv_path()
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        if raw.startswith("#"):
            continue
        if re.search(r"\S\s*AMASS_AI_[A-Z_]+=", raw) and not raw.lstrip().startswith("AMASS_AI_"):
            fail(".env has an AMASS_AI_* setting joined to the end of another line; "
                 "put each KEY=value on its own line")


def validate_local_amass(path_str: str) -> str:
    checkout = Path(path_str)
    gomod = checkout / "go.mod"
    if not gomod.is_file() or not any(
        line.startswith("module github.com/owasp-amass/amass/")
        for line in gomod.read_text().splitlines()
    ):
        fail(f"AMASS_LOCAL_SRC={path_str} is not an Amass checkout")
    return str(checkout.resolve())


def resolve_revisions(args) -> bool:
    """Set the AMASS_AI_* build vars in os.environ. Returns True if local-src."""
    guard_glued_env_key()

    # Branch refs: --branch sets both; else env/.env; else the feature branch.
    amass_ref = args.branch or resolve_setting("AMASS_SRC_REF", DEFAULT_FEATURE_BRANCH)
    assetdb_ref = args.branch or resolve_setting("ASSETDB_SRC_REF", DEFAULT_FEATURE_BRANCH)
    os.environ["AMASS_SRC_REF"] = amass_ref
    os.environ["ASSETDB_SRC_REF"] = assetdb_ref

    # Local amass source is FLAG-DRIVEN ONLY: a local build happens only when
    # --local is passed. AMASS_LOCAL_SRC in the environment/.env is not an
    # auto-trigger; it merely supplies the default path for a bare --local.
    # Without --local, the build always comes from GitHub (pinned or --branch).
    local_amass = ""
    if args.local is not None:
        local_amass = args.local or resolve_setting("AMASS_LOCAL_SRC") or "../amass"

    if local_amass:
        local_amass = validate_local_amass(local_amass)
        os.environ["AMASS_LOCAL_SRC"] = local_amass
        os.environ["AMASS_SRC_SHA"] = "local"
        desc = run(["git", "-C", local_amass, "describe", "--always", "--dirty"],
                   capture_output=True, text=True)
        branch = run(["git", "-C", local_amass, "branch", "--show-current"],
                     capture_output=True, text=True)
        local_desc = (desc.stdout.strip() or "unknown")
        local_branch = (branch.stdout.strip() or "detached")
    else:
        os.environ.pop("AMASS_LOCAL_SRC", None)
        os.environ["AMASS_SRC_SHA"] = resolve_remote_sha("amass", amass_ref, "amass")

    os.environ["ASSETDB_SRC_SHA"] = resolve_remote_sha("asset-db", assetdb_ref, "asset-db")

    if local_amass:
        print(f"Building LOCAL amass {local_amass} ({local_desc}, branch {local_branch}) "
              f"with asset-db@{os.environ['ASSETDB_SRC_SHA'][:12]}")
        return True
    print(f"Building amass@{os.environ['AMASS_SRC_SHA'][:12]} and "
          f"asset-db@{os.environ['ASSETDB_SRC_SHA'][:12]} (resolved from feature branches)")
    return False


# --------------------------------------------------------------------------- #
# Compose invocation
# --------------------------------------------------------------------------- #
def compose_base(local_src: bool):
    cmd = ["docker", "compose"]
    if local_src:
        cmd += ["-f", "compose.yaml", "-f", "compose.local-src.yaml"]
    return cmd


def compose_config_json(base, *profiles):
    cmd = list(base)
    for profile in profiles:
        cmd += ["--profile", profile]
    cmd += ["config", "--format", "json"]
    proc = run(cmd, capture_output=True, text=True)
    if proc.returncode:
        fail("Compose configuration is invalid:\n" + proc.stderr)
    return json.loads(proc.stdout)


# --------------------------------------------------------------------------- #
# Secret token files (mode 0600 under data/state)
# --------------------------------------------------------------------------- #
def ensure_token(env_var: str, filename: str, min_len: int = 32, differ_from: str = "") -> str:
    value = os.environ.get(env_var, "")
    if not value:
        token_file = ROOT / "data" / "state" / filename
        if not token_file.exists() or token_file.stat().st_size == 0:
            token = secrets.token_urlsafe(48)
            fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write(token + "\n")
        value = token_file.read_text().strip()
        os.environ[env_var] = value
    if len(value) < min_len:
        fail(f"{env_var} must be at least {min_len} characters")
    if differ_from and value == os.environ.get(differ_from, ""):
        fail(f"{env_var} must differ from {differ_from}")
    return value


# --------------------------------------------------------------------------- #
# Host Ollama readiness (replaces curl; used only for the host-model path)
# --------------------------------------------------------------------------- #
def host_ollama_has_model(model_name: str) -> "tuple[bool, bool]":
    """Return (ollama_reachable, model_present) for http://127.0.0.1:11434."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=5) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError, ValueError):
        return (False, False)
    names = {m.get("name", "") for m in data.get("models", [])}
    present = model_name in names or (model_name + ":latest") in names
    return (True, present)


# --------------------------------------------------------------------------- #
# COMPOSE_PROFILES maintenance (keep lifecycle commands consistent)
# --------------------------------------------------------------------------- #
def set_compose_profiles(include_ai_local: bool, allow_http: bool) -> str:
    """Update only the two managed keys in .env, preserving other profiles."""
    raw = read_dotenv_value("COMPOSE_PROFILES")
    profiles = [p.strip() for p in raw.split(",") if p.strip()]
    profiles = [p for p in profiles if p != "ai-local"]
    if include_ai_local:
        profiles.append("ai-local")
    joined = ",".join(profiles)
    set_dotenv_values({
        "AMASS_LLM_ALLOW_HTTP": "true" if allow_http else "false",
        "COMPOSE_PROFILES": joined,
    })
    print("Compose lifecycle profile:", joined or "default only")
    return joined


def classifier_train_if_stale(base) -> None:
    labeled = ROOT / "data" / "classifier-training" / "labeled.jsonl"
    model = ROOT / "data" / "models" / "classifier.json"
    labeled_ready = labeled.exists() and labeled.stat().st_size > 0
    model_ready = model.exists() and model.stat().st_size > 0
    if labeled_ready and (not model_ready or labeled.stat().st_mtime > model.stat().st_mtime):
        print("Training the local classifier from curated labeled examples...")
        run(base + ["--profile", "ai-train", "run", "--rm", "classifier-train"], check=True)
    elif not model_ready:
        print("No trained classifier artifact found; default OAM evidence triage "
              "(review/escalation) will be used.")


# --------------------------------------------------------------------------- #
# LLM layer: Ollama topology + model warm-up
# --------------------------------------------------------------------------- #
def prepare_llm_layer(base, provider: str, endpoint: str):
    """Resolve the Ollama topology, update .env, and warm the model.

    Returns (local_model, host_model). Only called when LLM is enabled.
    """
    internal = endpoint == INTERNAL_OLLAMA or endpoint.startswith(INTERNAL_OLLAMA + "/")
    host = endpoint == HOST_OLLAMA or endpoint.startswith(HOST_OLLAMA + "/")
    ollama_like = provider in ("ollama", "compatible")

    local_model = internal and ollama_like
    host_model = host and ollama_like

    if local_model:
        set_compose_profiles(include_ai_local=True, allow_http=True)
    elif host_model:
        set_compose_profiles(include_ai_local=False, allow_http=True)
    else:
        if endpoint.startswith("http://"):
            fail("external HTTP model endpoints are not enabled by this script. Configure HTTPS.")
        set_compose_profiles(include_ai_local=False, allow_http=False)

    if host_model:
        config = compose_config_json(base)
        model_name = config["services"]["ai"]["environment"]["AMASS_LLM_MODEL"]
        print(f"Using Ollama on this computer for model {model_name}...")
        # Free a previously started in-Docker Ollama.
        run(base + ["--profile", "ai-local", "stop", "ollama"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        reachable, present = host_ollama_has_model(model_name)
        if not reachable:
            fail("Ollama is not answering on http://127.0.0.1:11434. "
                 "Start the Ollama app (or 'ollama serve') and rerun.")
        if not present:
            if have("ollama"):
                print(f"Pulling {model_name} into the host Ollama...")
                run(["ollama", "pull", model_name], check=True)
            else:
                fail(f"model {model_name} is not in the host Ollama. Run: ollama pull {model_name}")
    elif local_model:
        print("Starting Ollama and ensuring the configured model is loaded...")
        run(base + ["--profile", "ai-local", "up", "-d", "--wait",
                    "--wait-timeout", "180", "ollama"], check=True)
        config = compose_config_json(base, "ai-local")
        model_name = config["services"]["ollama-pull"]["command"][0]
        already = run(base + ["--profile", "ai-local", "exec", "-T", "ollama",
                              "ollama", "show", model_name],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if already.returncode == 0:
            print(f"Ollama model {model_name} already installed; skipping download.")
        else:
            run(base + ["--profile", "ai-local", "run", "--rm", "ollama-pull"], check=True)
    else:
        print(f"Using configured external inference provider ({provider}); "
              "local Ollama not required.")
    return local_model, host_model


def start_chat_ui(base, local_model: bool, host_model: bool, provider: str) -> None:
    ensure_token("AMASS_CHAT_SECRET", ".chat-secret")
    if not os.environ.get("AMASS_CHAT_OLLAMA_URL"):
        if host_model:
            os.environ["AMASS_CHAT_OLLAMA_URL"] = HOST_OLLAMA
        elif local_model:
            os.environ["AMASS_CHAT_OLLAMA_URL"] = INTERNAL_OLLAMA
        else:
            print(f"WARNING: the chat UI talks to Ollama, but this stack uses an external "
                  f"provider ({provider}).", file=sys.stderr)
            print("         Set AMASS_CHAT_OLLAMA_URL, or add a provider connection in "
                  "Open WebUI's settings.", file=sys.stderr)
    (ROOT / "data" / "open-webui").mkdir(parents=True, exist_ok=True)
    print("Starting the Open WebUI chat profile connected to Amass...")
    run(base + ["--profile", "ai-chat", "up", "-d", "--wait",
                "--wait-timeout", "600", "open-webui"], check=True)


# --------------------------------------------------------------------------- #
# up / down entry points
# --------------------------------------------------------------------------- #
def build_up_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="up",
        description="Start the isolated Amass feature-branch stack. Collection and "
                    "the always-on classifier run with no LLM; add --llm for "
                    "model inference, the MCP server and the optional chat UI.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--llm", dest="llm", action="store_true", default=None,
                       help="enable LLM-powered features (persisted to .env)")
    group.add_argument("--no-llm", dest="llm", action="store_false",
                       help="disable LLM-powered features (persisted to .env)")
    src = parser.add_mutually_exclusive_group()
    src.add_argument("--local", nargs="?", const="", metavar="PATH",
                     help="build amass from a local checkout (default: "
                          "AMASS_LOCAL_SRC or ../amass); required to build "
                          "local — no flag means a GitHub build")
    src.add_argument("--branch", metavar="NAME",
                     help="build amass and asset-db from this GitHub branch")
    parser.add_argument("--chat", action="store_true",
                        help="also start the Open WebUI chat UI (requires --llm)")
    return parser


def build_down_parser() -> argparse.ArgumentParser:
    return argparse.ArgumentParser(
        prog="down",
        description="Stop the stack (all optional profiles). Persistent database "
                    "and Ollama models are preserved.")


def up_main(argv=None) -> None:
    args = build_up_parser().parse_args(argv)
    check_prerequisites()
    for directory in ("data/state", "data/models", "data/ollama", "data/classifier-training"):
        (ROOT / directory).mkdir(parents=True, exist_ok=True)

    llm = resolve_llm_enabled(args)
    if args.chat and not llm:
        fail("--chat requires LLM features; re-run with --llm --chat")

    local_src = resolve_revisions(args)
    base = compose_base(local_src)

    provider = resolve_setting("AMASS_LLM_PROVIDER", "ollama")
    endpoint = resolve_setting("AMASS_LLM_ENDPOINT", INTERNAL_OLLAMA)
    chat = args.chat or is_truthy(resolve_setting("AMASS_CHAT"))

    if not llm:
        # No LLM: no internal Ollama profile, no host HTTP opt-in.
        set_compose_profiles(include_ai_local=False, allow_http=False)

    # Validate the fully-configured compose before building anything.
    run([sys.executable, "scripts/check-ai-compose.py"], check=True)

    print("Building the matching Amass and Asset Database feature image...")
    run(base + ["build", "ai"], check=True)

    classifier_train_if_stale(base)

    local_model = host_model = False
    if llm:
        local_model, host_model = prepare_llm_layer(base, provider, endpoint)

    # The always-on core (collection + classifier). Recreate the classifier so
    # an updated trained model is never silently stale.
    print("Starting Amass collection and the classifier...")
    run(base + ["up", "-d", "--force-recreate", "--no-deps", "classifier"], check=True)
    run(base + ["up", "-d", "--build", "--wait", "--wait-timeout", "900"] + CORE_SERVICES,
        check=True)
    # Keeps the vulnerable lens's data current; it has no health check to wait on.
    run(base + ["up", "-d", "vuln-refresh"], check=True)

    if llm:
        ensure_token("AMASS_MCP_TOKEN", ".mcp-token")
        ensure_token("AMASS_MCP_OPERATOR_TOKEN", ".mcp-operator-token",
                     differ_from="AMASS_MCP_TOKEN")
        print("Starting the provider health checker and MCP server...")
        run(base + ["up", "-d", "--wait", "--wait-timeout", "900"] + LLM_SERVICES, check=True)
        if chat:
            start_chat_ui(base, local_model, host_model, provider)

    run(base + ["ps"], check=False)
    print()
    if llm:
        mcp_port = resolve_setting("AMASS_MCP_PORT", "18090")
        print("LLM features are enabled; model inference connectivity was verified.")
        print(f"MCP URL: http://127.0.0.1:{mcp_port}/mcp")
        print("MCP bearer token: data/state/.mcp-token (unless provided by environment)")
        print("MCP operator token: data/state/.mcp-operator-token "
              "(starts enumerations after your approval)")
        print("Connect an AI assistant (Claude, Cursor, VS Code, Codex, Gemini CLI, ...): "
              "python3 scripts/ai-connect.py --operator")
        if chat:
            chat_port = resolve_setting("AMASS_CHAT_PORT", "18080")
            print(f"Chat with Amass in your browser: http://127.0.0.1:{chat_port}")
    else:
        print("Started WITHOUT LLM features: collection, deterministic attribution and")
        print("the classifier are running; no inference provider was contacted.")
        print("Enable LLM features (model inference, MCP server, chat UI) with: ./scripts/up --llm")
    print("No Internet enumeration or inference-derived graph write was started.")


def down_main(argv=None) -> None:
    build_down_parser().parse_args(argv)
    if not have("docker"):
        fail("docker is required")
    run(["docker", "compose", "--profile", "ai-local", "--profile", "ai-train",
         "--profile", "ai-stdio", "--profile", "ai-chat", "down"], check=True)
    # Resolve the network name using Compose interpolation (including .env).
    config = compose_config_json(["docker", "compose"])
    network = config.get("networks", {}).get("amass", {}).get("name")
    if network:
        inspect = run(["docker", "network", "inspect", network],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if inspect.returncode == 0:
            print(f"Network {network} remains attached to at least one container.")
            print("Attached containers (inspect before taking action):")
            run(["docker", "ps", "-a", "--filter", f"network={network}",
                 "--format", "  {{.ID}}  {{.Names}}  {{.Status}}"], check=False)
            sys.exit(1)
    print("Stack stopped. Persistent database and Ollama models preserved.")
