#!/usr/bin/env python3
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0

"""Connect AI assistants and agents to the Amass MCP server of this Compose stack.

Each supported client is described in CLIENTS below: where its MCP
configuration lives and the entry it expects. Clients that speak Streamable
HTTP get the authenticated endpoint published on localhost; clients that
only run local commands get a stdio bridge into the running ai-mcp
container (docker exec), so no Node or Python package is installed on the
host. Files are backed up before they are changed, entries are replaced in
place so running this again updates them, and --remove takes them out.

The bearer token is written into each client's configuration, because GUI
applications do not see shell variables. Re-run this script after rotating
data/ai/.mcp-token.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

REPO = Path(__file__).resolve().parent.parent
DEFAULT_PORT = "18090"
DEFAULT_NAMESPACE = "amass-ai-test"
STDIO_BINARY = ["/bin/amass-ai-mcp", "-config", "/.config/amass/config.yaml"]
CONTAINER_PORT = "8090"


# ---------------------------------------------------------------------------
# Endpoint: what every client entry is built from.
# ---------------------------------------------------------------------------

@dataclass
class Endpoint:
    name: str
    url: str
    token: str
    docker: str
    container: str
    network: str
    operator: bool = False

    def headers(self) -> dict:
        return {"Authorization": "Bearer " + self.token}

    def stdio(self) -> tuple[str, list]:
        if not self.operator:
            return self.docker, ["exec", "-i", self.container, *STDIO_BINARY]
        # A stdio operator keeps its own run journal, apart from the HTTP server's.
        return self.docker, ["exec", "-i", "-e", "AMASS_AI_MCP_RUN_JOURNAL=/data/enumerations-stdio.jsonl",
                             self.container, *STDIO_BINARY, "-operator"]


def env_value(key: str, default: str = "") -> str:
    """Reads a setting from the environment, then from the stack's .env."""
    if os.environ.get(key):
        return os.environ[key]
    path = REPO / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return default


def read_token(operator: bool = False) -> str:
    env, name = ("AMASS_AI_MCP_OPERATOR_TOKEN", ".mcp-operator-token") if operator else (
        "AMASS_AI_MCP_TOKEN", ".mcp-token")
    token = os.environ.get(env, "")
    path = REPO / "data" / "ai" / name
    if not token and path.exists():
        token = path.read_text().strip()
    return token


def find_container(docker: str, namespace: str) -> str:
    """Returns the name of the running ai-mcp container, or the name Compose gives it."""
    if docker:
        try:
            r = subprocess.run([docker, "compose", "--project-directory", str(REPO), "ps", "-q", "ai-mcp"],
                               capture_output=True, text=True, timeout=30)
            cid = r.stdout.strip().splitlines()[0] if r.returncode == 0 and r.stdout.strip() else ""
            if cid:
                r = subprocess.run([docker, "inspect", "--format", "{{.Name}}", cid],
                                   capture_output=True, text=True, timeout=30)
                if r.returncode == 0 and r.stdout.strip():
                    return r.stdout.strip().lstrip("/")
        except (OSError, subprocess.SubprocessError):
            pass
    return f"{namespace}-ai-mcp-1"


def build_endpoint(name: str, operator: bool = False) -> Endpoint:
    namespace = env_value("AMASS_TEST_NAMESPACE", DEFAULT_NAMESPACE)
    port = env_value("AMASS_AI_MCP_PORT", DEFAULT_PORT)
    # GUI clients start commands with a short PATH, so the bridge names
    # Docker by its absolute path.
    docker = shutil.which("docker") or ""
    return Endpoint(name=name, url=f"http://127.0.0.1:{port}/mcp", token=read_token(operator),
                    docker=docker or "docker", container=find_container(docker, namespace),
                    network=f"{namespace}-net", operator=operator)


# ---------------------------------------------------------------------------
# Config file handling.
# ---------------------------------------------------------------------------

class ConfigError(Exception):
    pass


def strip_jsonc(text: str) -> tuple[str, bool]:
    """Removes // and /* */ comments and trailing commas outside strings.

    Returns the JSON text and whether anything other than whitespace was removed,
    so callers know that writing the file back would lose comments.
    """
    out = []
    i, n = 0, len(text)
    in_str = False
    lost = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            lost = True
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            lost = True
        else:
            out.append(c)
            i += 1
    cleaned = "".join(out)
    without_commas = re.sub(r",(\s*[}\]])", r"\1", cleaned)
    return without_commas, lost or without_commas != cleaned


def load_json(path: Path) -> tuple[dict, bool]:
    """Loads a JSON or JSONC file; returns the data and whether it had comments."""
    if not path.exists() or not path.read_text().strip():
        return {}, False
    text = path.read_text()
    try:
        data = json.loads(text)
        lossy = False
    except json.JSONDecodeError:
        cleaned, lossy = strip_jsonc(text)
        try:
            data = json.loads(cleaned)
        except json.JSONDecodeError as exc:
            raise ConfigError(f"{path} is not valid JSON ({exc}); fix it or add the entry by hand") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"{path} does not hold a JSON object")
    return data, lossy


def backup(path: Path) -> Optional[Path]:
    if not path.exists():
        return None
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    dest = path.with_name(f"{path.name}.amass-backup-{stamp}")
    shutil.copy2(path, dest)
    return dest


def write_text(path: Path, text: str) -> None:
    new = not path.exists()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".amass-tmp")
    tmp.write_text(text)
    if new:
        # The file carries the bearer token.
        os.chmod(tmp, 0o600)
    else:
        shutil.copymode(path, tmp)
    os.replace(tmp, path)


def nested(data: dict, keys: list) -> dict:
    cur = data
    for k in keys:
        nxt = cur.get(k)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[k] = nxt
        cur = nxt
    return cur


# ---------------------------------------------------------------------------
# Clients.
# ---------------------------------------------------------------------------

def home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def appdata() -> Optional[Path]:
    v = os.environ.get("APPDATA")
    return Path(v) if v else None


def xdg_config() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or home() / ".config")


def app_support(*parts: str) -> list[Path]:
    """Per-OS application data directories for a desktop app."""
    out = []
    if sys.platform == "darwin":
        out.append(home() / "Library" / "Application Support" / Path(*parts))
    elif sys.platform.startswith("win"):
        if appdata():
            out.append(appdata() / Path(*parts))
    else:
        out.append(xdg_config() / Path(*parts))
    return out


@dataclass
class Client:
    id: str
    name: str
    # json: an MCP entry inside a JSON file; toml: a table in a TOML file;
    # cli: the client's own command; manual: printed instructions.
    kind: str
    paths: Callable[[], list[Path]] = lambda: []
    keys: list = field(default_factory=lambda: ["mcpServers"])
    entry: Optional[Callable[[Endpoint], dict]] = None
    transport: str = "http"
    detect_dirs: Callable[[], list[Path]] = lambda: []
    commands: list = field(default_factory=list)
    instructions: Optional[Callable[[Endpoint], str]] = None
    note: str = ""

    def detected(self) -> bool:
        if any(shutil.which(c) for c in self.commands):
            return True
        if any(p.exists() for p in self.detect_dirs()):
            return True
        # A client's own configuration directory (not the home directory itself).
        return any(p.exists() or (p.parent.exists() and p.parent != home()) for p in self.paths())

    def targets(self) -> list[Path]:
        """Config files to write: those that exist, else the first whose app is installed."""
        paths = self.paths()
        existing = [p for p in paths if p.exists()]
        if existing:
            return existing
        for p in paths:
            if p.parent.exists() or any(d.exists() for d in self.detect_dirs()):
                return [p]
        return paths[:1]


def http_url_headers(ep: Endpoint) -> dict:
    return {"url": ep.url, "headers": ep.headers()}


def stdio_entry(ep: Endpoint) -> dict:
    command, args = ep.stdio()
    return {"command": command, "args": args}


def vscode_dirs() -> list[Path]:
    out = []
    for variant in ("Code", "Code - Insiders", "VSCodium"):
        out += app_support(variant, "User")
    return out


def cline_paths() -> list[Path]:
    out = [Path(os.environ["CLINE_MCP_SETTINGS_PATH"])] if os.environ.get("CLINE_MCP_SETTINGS_PATH") else []
    out.append(home() / ".cline" / "data" / "settings" / "cline_mcp_settings.json")
    for d in vscode_dirs():
        out.append(d / "globalStorage" / "saoudrizwan.claude-dev" / "settings" / "cline_mcp_settings.json")
    return out


def codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME") or home() / ".codex")


def windsurf_paths() -> list[Path]:
    out = [home() / ".codeium" / "windsurf" / "mcp_config.json", xdg_config() / "devin" / "mcp_config.json"]
    if appdata():
        out.append(appdata() / "devin" / "mcp_config.json")
    return out


def zed_paths() -> list[Path]:
    if sys.platform.startswith("win") and appdata():
        return [appdata() / "Zed" / "settings.json"]
    return [xdg_config() / "zed" / "settings.json"]


def opencode_paths() -> list[Path]:
    d = xdg_config() / "opencode"
    return [d / "opencode.json", d / "opencode.jsonc"]


def goose_text(ep: Endpoint) -> str:
    return (f"Add to ~/.config/goose/config.yaml (Windows: %APPDATA%\\Block\\goose\\config\\config.yaml) under "
            f"extensions:, then restart goose:\n\n"
            f"  {ep.name}:\n    type: streamable_http\n    name: {ep.name}\n    enabled: true\n"
            f"    bundled: false\n    uri: {ep.url}\n    headers:\n      Authorization: \"Bearer {ep.token}\"\n"
            f"    timeout: 300\n")


def continue_text(ep: Endpoint) -> str:
    return (f"Add to ~/.continue/config.yaml under mcpServers: (Continue's agent mode uses MCP tools):\n\n"
            f"  - name: {ep.name}\n    type: streamable-http\n    url: {ep.url}\n    requestOptions:\n"
            f"      headers:\n        Authorization: \"Bearer {ep.token}\"\n")


def jetbrains_text(ep: Endpoint) -> str:
    entry = {"mcpServers": {ep.name: stdio_entry(ep)}}
    return ("In the IDE: Settings > Tools > AI Assistant > Model Context Protocol (MCP) > Add, choose "
            "'As JSON' and paste:\n\n" + json.dumps(entry, indent=2) + "\n")


def open_webui_text(ep: Endpoint) -> str:
    return ("The stack can run Open WebUI for you, already connected in operator mode:\n"
            "  AMASS_AI_CHAT=true bash scripts/ai-up.sh   (then open http://127.0.0.1:18080)\n"
            "To connect an Open WebUI you run yourself (v0.6.31 or later): Admin Settings > Integrations > "
            "External Tool Servers > Add Connection.\n"
            "  Type: MCP (Streamable HTTP)\n"
            f"  URL:  {ep.url}  (Open WebUI running on this computer outside Docker)\n"
            f"        http://ai-mcp:{CONTAINER_PORT}/mcp  (Open WebUI in Docker: first run\n"
            f"        docker network connect {ep.network} <open-webui container>)\n"
            f"  Auth: Bearer, Key: {ep.token}\n")


def web_text(ep: Endpoint) -> str:
    return ("Claude.ai, ChatGPT and other web assistants connect only to remote MCP servers on a public "
            "HTTPS address with OAuth. This stack publishes MCP on localhost with a bearer token on purpose, "
            "so they cannot reach it. Use a desktop or command-line client listed here, or put the endpoint "
            "behind your own HTTPS reverse proxy with OAuth before exposing collected data.\n")


def generic_text(ep: Endpoint) -> str:
    command, args = ep.stdio()
    return ("Any MCP client:\n"
            f"  Streamable HTTP: {ep.url}\n"
            f"  Header:          Authorization: Bearer {ep.token}\n"
            f"  stdio command:   {command} {' '.join(args)}\n")


CLIENTS: list[Client] = [
    Client("claude-code", "Claude Code", "cli", commands=["claude"],
           paths=lambda: [home() / ".claude.json"], entry=lambda ep: {"type": "http", **http_url_headers(ep)},
           detect_dirs=lambda: [home() / ".claude"]),
    Client("claude-desktop", "Claude Desktop", "json", transport="stdio",
           paths=lambda: [p / "claude_desktop_config.json" for p in app_support("Claude")],
           entry=stdio_entry, note="restart Claude Desktop"),
    Client("cursor", "Cursor", "json", paths=lambda: [home() / ".cursor" / "mcp.json"], entry=http_url_headers,
           commands=["cursor"]),
    Client("vscode", "VS Code (GitHub Copilot agent mode)", "json", keys=["servers"],
           paths=lambda: [d / "mcp.json" for d in vscode_dirs()],
           entry=lambda ep: {"type": "http", **http_url_headers(ep)}, commands=["code", "code-insiders"],
           detect_dirs=vscode_dirs),
    Client("windsurf", "Windsurf", "json", paths=windsurf_paths,
           entry=lambda ep: {"serverUrl": ep.url, "headers": ep.headers()},
           detect_dirs=lambda: [home() / ".codeium" / "windsurf", xdg_config() / "devin"],
           note="press refresh in Cascade's MCP menu"),
    Client("gemini-cli", "Gemini CLI", "json", paths=lambda: [home() / ".gemini" / "settings.json"],
           entry=lambda ep: {"httpUrl": ep.url, "headers": ep.headers(), "timeout": 600000},
           commands=["gemini"], detect_dirs=lambda: [home() / ".gemini"]),
    Client("codex", "OpenAI Codex (CLI and IDE extension)", "toml", paths=lambda: [codex_home() / "config.toml"],
           commands=["codex"], detect_dirs=lambda: [codex_home()]),
    Client("copilot-cli", "GitHub Copilot CLI", "json", paths=lambda: [home() / ".copilot" / "mcp-config.json"],
           entry=lambda ep: {"type": "http", **http_url_headers(ep), "tools": ["*"]}, commands=["copilot"],
           detect_dirs=lambda: [home() / ".copilot"]),
    Client("cline", "Cline", "json", paths=cline_paths,
           entry=lambda ep: {"type": "streamableHttp", **http_url_headers(ep), "disabled": False},
           commands=["cline"], detect_dirs=lambda: [home() / ".cline"]),
    Client("zed", "Zed", "json", keys=["context_servers"], paths=zed_paths, entry=http_url_headers,
           commands=["zed"]),
    Client("lm-studio", "LM Studio", "json", paths=lambda: [home() / ".lmstudio" / "mcp.json"],
           entry=http_url_headers, commands=["lms"], detect_dirs=lambda: [home() / ".lmstudio"]),
    Client("opencode", "opencode", "json", keys=["mcp"], paths=opencode_paths,
           entry=lambda ep: {"type": "remote", **http_url_headers(ep), "enabled": True}, commands=["opencode"],
           detect_dirs=lambda: [xdg_config() / "opencode"]),
    Client("kiro", "Kiro (IDE and CLI)", "json", paths=lambda: [home() / ".kiro" / "settings" / "mcp.json"],
           entry=http_url_headers, commands=["kiro", "kiro-cli"], detect_dirs=lambda: [home() / ".kiro"]),
    Client("goose", "goose", "manual", instructions=goose_text, commands=["goose"],
           detect_dirs=lambda: [xdg_config() / "goose"]),
    Client("continue", "Continue", "manual", instructions=continue_text,
           detect_dirs=lambda: [home() / ".continue"]),
    Client("jetbrains", "JetBrains AI Assistant", "manual", transport="stdio", instructions=jetbrains_text),
    Client("open-webui", "Open WebUI", "manual", instructions=open_webui_text),
    Client("web", "Claude.ai, ChatGPT and other web assistants", "manual", instructions=web_text),
    Client("generic", "Any other MCP client", "manual", instructions=generic_text),
]

BY_ID = {c.id: c for c in CLIENTS}


# ---------------------------------------------------------------------------
# Writers.
# ---------------------------------------------------------------------------

@dataclass
class Result:
    client: Client
    path: Optional[Path] = None
    action: str = ""
    backup: Optional[Path] = None
    message: str = ""


def first_brace(text: str) -> int:
    """Returns the index of the first '{' outside comments and strings, or -1."""
    i, n, in_str = 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            in_str = c != '"'
        elif c == '"':
            in_str = True
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif c == "{":
            return i
        i += 1
    return -1


def insert_entry(text: str, keys: list, name: str, entry: dict) -> Optional[str]:
    """Adds an entry to a commented JSON file without rewriting it, when the
    top-level key is absent; returns None when that is not possible."""
    at = first_brace(text)
    if at < 0:
        return None
    value: dict = {name: entry}
    for k in reversed(keys[1:]):
        value = {k: value}
    body = json.dumps(value, indent=2).replace("\n", "\n  ")
    rest = text[at + 1:]
    empty = strip_jsonc(rest)[0].strip() == "}"
    insert = f'\n  {json.dumps(keys[0])}: {body}' + ("" if empty else ",")
    return text[:at + 1] + insert + rest


def json_apply(client: Client, ep: Endpoint, path: Path, remove: bool, force: bool, dry: bool) -> Result:
    data, lossy = load_json(path)
    servers = nested(json.loads(json.dumps(data)), client.keys)
    if remove:
        if ep.name not in servers:
            return Result(client, path, "not configured")
        action = "removed"
    else:
        entry = client.entry(ep)
        if servers.get(ep.name) == entry:
            return Result(client, path, "unchanged")
        action = "updated" if ep.name in servers else "added"

    if lossy and not force:
        # Keep the user's comments: add the key in place when it is new.
        text = None if remove or client.keys[0] in data else insert_entry(
            path.read_text(), client.keys, ep.name, client.entry(ep))
        if text is None:
            raise ConfigError(f"{path} has comments that rewriting it would drop; edit it by hand or run "
                              f"again with --force (a backup is kept). The entry under "
                              f"{'.'.join(client.keys)}:\n"
                              + json.dumps({ep.name: client.entry(ep)}, indent=2))
        if dry:
            return Result(client, path, action + " (dry run)")
        saved = backup(path)
        write_text(path, text)
        return Result(client, path, action, saved)

    servers = nested(data, client.keys)
    if remove:
        del servers[ep.name]
    else:
        servers[ep.name] = client.entry(ep)
    if dry:
        return Result(client, path, action + " (dry run)")
    saved = backup(path)
    write_text(path, json.dumps(data, indent=2) + "\n")
    return Result(client, path, action, saved)


TOML_TABLE = re.compile(r"^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$")


def toml_quote(s: str) -> str:
    return json.dumps(s)


def toml_block(ep: Endpoint) -> str:
    return (f"[mcp_servers.{ep.name}]\n"
            f"url = {toml_quote(ep.url)}\n"
            f"enabled = true\n"
            f"\n[mcp_servers.{ep.name}.http_headers]\n"
            f"Authorization = {toml_quote('Bearer ' + ep.token)}\n")


def toml_without(text: str, name: str) -> tuple[str, bool]:
    """Removes the [mcp_servers.<name>] table and its sub-tables."""
    prefix = f"mcp_servers.{name}"
    out, skipping, found = [], False, False
    for line in text.splitlines(keepends=True):
        m = TOML_TABLE.match(line)
        if m:
            table = m.group(1).replace('"', "").replace("'", "")
            skipping = table == prefix or table.startswith(prefix + ".")
            found = found or skipping
        if not skipping:
            out.append(line)
    return re.sub(r"\n{3,}", "\n\n", "".join(out)), found


def toml_apply(client: Client, ep: Endpoint, path: Path, remove: bool, force: bool, dry: bool) -> Result:
    text = path.read_text() if path.exists() else ""
    rest, found = toml_without(text, ep.name)
    if remove:
        if not found:
            return Result(client, path, "not configured")
        new, action = rest, "removed"
    else:
        body = rest.rstrip("\n")
        new = (body + "\n\n" if body else "") + toml_block(ep)
        action = "updated" if found else "added"
        if new == text:
            action = "unchanged"
    if action == "unchanged" or dry:
        return Result(client, path, action + (" (dry run)" if dry and action != "unchanged" else ""))
    saved = backup(path)
    write_text(path, new)
    return Result(client, path, action, saved)


def cli_apply(client: Client, ep: Endpoint, remove: bool, force: bool, dry: bool) -> list[Result]:
    exe = shutil.which("claude")
    if not exe:
        # Without the CLI, edit its settings file directly.
        return [json_apply(client, ep, p, remove, force, dry) for p in client.targets()]
    remove_cmd = [exe, "mcp", "remove", "--scope", "user", ep.name]
    add_cmd = [exe, "mcp", "add", "--transport", "http", "--scope", "user", ep.name, ep.url,
               "--header", "Authorization: Bearer " + ep.token]
    if dry:
        return [Result(client, None, "would run: claude mcp add --transport http --scope user "
                                      f"{ep.name} {ep.url} --header 'Authorization: Bearer ***'")]
    subprocess.run(remove_cmd, capture_output=True, text=True, timeout=60)
    if remove:
        return [Result(client, None, "removed (claude mcp remove)")]
    r = subprocess.run(add_cmd, capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise ConfigError("claude mcp add failed: " + (r.stderr or r.stdout).strip())
    return [Result(client, None, "added (claude mcp add, user scope)")]


def apply(client: Client, ep: Endpoint, remove: bool, force: bool, dry: bool) -> list[Result]:
    if client.kind == "manual":
        return [Result(client, None, "manual", message=client.instructions(ep))]
    if client.kind == "cli":
        return cli_apply(client, ep, remove, force, dry)
    writer = toml_apply if client.kind == "toml" else json_apply
    return [writer(client, ep, p, remove, force, dry) for p in client.targets()]


def configured(client: Client, ep: Endpoint) -> Optional[bool]:
    """Whether a client's files already hold the entry; None when it cannot tell."""
    if client.kind == "manual":
        return None
    for p in client.paths():
        if not p.exists():
            continue
        try:
            if client.kind == "toml":
                if toml_without(p.read_text(), ep.name)[1]:
                    return True
                continue
            data, _ = load_json(p)
        except (ConfigError, OSError):
            continue
        cur = data
        for k in client.keys:
            cur = cur.get(k, {}) if isinstance(cur, dict) else {}
        if isinstance(cur, dict) and ep.name in cur:
            return True
    return False


# ---------------------------------------------------------------------------
# Checks.
# ---------------------------------------------------------------------------

def check_http(ep: Endpoint) -> str:
    """Initializes an MCP session over HTTP and counts tools and prompts."""
    def call(payload, session=""):
        headers = {"Authorization": "Bearer " + ep.token, "Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream"}
        if session:
            headers["Mcp-Session-Id"] = session
        req = urllib.request.Request(ep.url, data=json.dumps(payload).encode(), method="POST", headers=headers)
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read().decode()
            session_id = resp.headers.get("Mcp-Session-Id", "")
            if not body.strip():
                return session_id, {}
            if "text/event-stream" in resp.headers.get("Content-Type", ""):
                # Operator sessions answer with event streams: take the reply.
                for line in body.splitlines():
                    if line.startswith("data:"):
                        msg = json.loads(line[5:].strip())
                        if "result" in msg or "error" in msg:
                            return session_id, msg
                return session_id, {}
            return session_id, json.loads(body)

    session, init = call({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "ai-connect", "version": "1"}}})
    if "result" not in init:
        raise ConfigError(f"initialize failed: {init}")
    call({"jsonrpc": "2.0", "method": "notifications/initialized"}, session)
    _, tools = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, session)
    _, prompts = call({"jsonrpc": "2.0", "id": 3, "method": "prompts/list"}, session)
    req = urllib.request.Request(ep.url, method="DELETE",
                                 headers={"Authorization": "Bearer " + ep.token, "Mcp-Session-Id": session})
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except urllib.error.URLError:
        pass
    names = {t.get("name") for t in tools.get("result", {}).get("tools", [])}
    n_tools = len(names)
    n_prompts = len(prompts.get("result", {}).get("prompts", []))
    version = init["result"].get("protocolVersion", "?")
    mode = "operator" if "start_enumeration" in names else "read-only"
    if ep.operator and mode != "operator":
        raise ConfigError("the server did not offer the operator tools; is AMASS_AI_MCP_OPERATOR_TOKEN set "
                          "for ai-mcp (bash scripts/ai-up.sh sets it)?")
    return f"HTTP OK ({mode}): protocol {version}, {n_tools} tools, {n_prompts} prompts"


def check_stdio(ep: Endpoint) -> str:
    """Runs the stdio bridge as a client would: keeps stdin open until the
    initialize reply arrives, then closes it."""
    import queue
    import threading

    command, args = ep.stdio()
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "ai-connect", "version": "1"}}}
    proc = subprocess.Popen([command, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    lines: queue.Queue = queue.Queue()
    threading.Thread(target=lambda: [lines.put(l) for l in proc.stdout], daemon=True).start()
    try:
        proc.stdin.write(json.dumps(init) + "\n")
        proc.stdin.flush()
        deadline = datetime.datetime.now() + datetime.timedelta(seconds=60)
        while datetime.datetime.now() < deadline:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                if proc.poll() is not None:
                    break
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == 1 and "result" in msg:
                return f"stdio OK: {command} {' '.join(args[:3])}"
    finally:
        try:
            proc.stdin.close()
            proc.wait(timeout=10)
        except (OSError, subprocess.SubprocessError):
            proc.kill()
    err = proc.stderr.read() if proc.stderr else ""
    raise ConfigError(f"stdio bridge did not answer: {err.strip()[:300]}")


# ---------------------------------------------------------------------------
# Command line.
# ---------------------------------------------------------------------------

def list_clients(ep: Endpoint) -> None:
    print(f"{'client':16} {'detected':9} {'connected':10} {'transport':9} name")
    for c in CLIENTS:
        det = "yes" if c.detected() else "-"
        conf = configured(c, ep)
        conf_s = "manual" if conf is None else ("yes" if conf else "-")
        print(f"{c.id:16} {det:9} {conf_s:10} {c.transport:9} {c.name}")


def report(results: list[Result]) -> None:
    for r in results:
        where = f" {r.path}" if r.path else ""
        print(f"[{r.client.id}] {r.action}{where}")
        if r.backup:
            print(f"    backup: {r.backup}")
        if r.client.note and r.action in ("added", "updated", "removed"):
            print(f"    then {r.client.note}")
        if r.message:
            print("    " + r.message.replace("\n", "\n    ").rstrip())


def main(argv: Optional[list] = None) -> int:
    ids = ", ".join(c.id for c in CLIENTS)
    p = argparse.ArgumentParser(
        description="Connect AI assistants to the Amass MCP server of this Compose stack.",
        epilog=f"Clients: {ids}. Without a client, the detected clients are listed and, on a terminal, "
               "offered for connection.")
    p.add_argument("clients", nargs="*", help="clients to connect (see the list)")
    p.add_argument("--detected", action="store_true", help="connect every detected client without asking")
    p.add_argument("--list", action="store_true", help="show clients, whether each is detected and connected")
    p.add_argument("--remove", action="store_true", help="remove the Amass entry instead of adding it")
    p.add_argument("--check", action="store_true", help="check the MCP endpoint and stdio bridge, then exit")
    p.add_argument("--dry-run", action="store_true", help="show what would change without writing")
    p.add_argument("--force", action="store_true", help="rewrite JSON files that contain comments (backed up)")
    p.add_argument("--operator", action="store_true",
                   help="connect in operator mode: the assistant may also start enumerations (each approved by "
                        "you), review proposals and add data source keys")
    p.add_argument("--name", default="amass", help="server name to register (default: amass)")
    p.add_argument("--no-check", action="store_true", help="skip the endpoint check after connecting")
    args = p.parse_args(argv)

    ep = build_endpoint(args.name, args.operator)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.name):
        p.error("--name may contain only letters, digits, '-' and '_'")
    if not args.remove and len(ep.token) < 32 and not args.list:
        which = ("data/ai/.mcp-operator-token", "AMASS_AI_MCP_OPERATOR_TOKEN") if args.operator else (
            "data/ai/.mcp-token", "AMASS_AI_MCP_TOKEN")
        print(f"ERROR: no MCP token found. Start the stack with: bash scripts/ai-up.sh "
              f"(it creates {which[0]}), or export {which[1]}.", file=sys.stderr)
        return 1

    if args.check:
        ok = True
        for fn in (check_http, check_stdio):
            try:
                print(fn(ep))
            except (ConfigError, OSError, urllib.error.URLError, subprocess.SubprocessError) as exc:
                ok = False
                print(f"{fn.__name__.replace('check_', '')} FAILED: {exc}", file=sys.stderr)
        return 0 if ok else 1

    if args.list:
        list_clients(ep)
        return 0

    unknown = [c for c in args.clients if c not in BY_ID and c != "all"]
    if unknown:
        p.error(f"unknown client(s): {', '.join(unknown)}; choose from {ids}")
    if "all" in args.clients:
        chosen = [c for c in CLIENTS if c.kind != "manual" and c.detected()]
    elif args.clients:
        chosen = [BY_ID[c] for c in args.clients]
    else:
        chosen = [c for c in CLIENTS if c.kind != "manual" and c.detected()]
        if not args.detected:
            list_clients(ep)
            if not chosen:
                print("\nNo supported client was detected. Run with a client name to configure it anyway, "
                      "or with 'generic' for the endpoint details.")
                return 0
            names = ", ".join(c.name for c in chosen)
            verb = "Remove Amass from" if args.remove else "Connect Amass to"
            if not sys.stdin.isatty():
                print(f"\nDetected: {names}. Run again with --detected (or name the clients) to "
                      f"{verb.lower()} them.")
                return 0
            answer = input(f"\n{verb}: {names}? [Y/n] ").strip().lower()
            if answer not in ("", "y", "yes"):
                return 0

    failed = False
    for c in chosen:
        try:
            report(apply(c, ep, args.remove, args.force, args.dry_run))
        except (ConfigError, OSError, subprocess.SubprocessError) as exc:
            failed = True
            print(f"[{c.id}] not changed: {exc}", file=sys.stderr)

    if not args.remove and not args.dry_run and not args.no_check and any(c.kind != "manual" for c in chosen):
        print()
        try:
            print(check_http(ep))
        except (ConfigError, OSError, urllib.error.URLError) as exc:
            print(f"WARNING: the MCP endpoint did not answer ({exc}). Start the stack with "
                  "bash scripts/ai-up.sh; the entries are in place and work once it runs.", file=sys.stderr)
        if any(c.transport == "stdio" for c in chosen if c.kind != "manual"):
            try:
                print(check_stdio(ep))
            except (ConfigError, OSError, subprocess.SubprocessError) as exc:
                print(f"WARNING: the stdio bridge did not answer ({exc}).", file=sys.stderr)
        print("Restart or reload each assistant, then ask it, for example: "
              "\"Using Amass, what does example.com expose?\"")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
