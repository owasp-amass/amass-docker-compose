#!/usr/bin/env python3
# Copyright © by Jeff Foley 2017-2026. All rights reserved.
# Use of this source code is governed by Apache 2 LICENSE that can be found in the LICENSE file.
# SPDX-License-Identifier: Apache-2.0

"""Tests for ai-connect.py: python3 -m unittest scripts/test_ai_connect.py"""

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ai_connect", HERE / "ai-connect.py")
ac = importlib.util.module_from_spec(spec)
sys.modules["ai_connect"] = ac  # dataclasses look the module up while it loads
spec.loader.exec_module(ac)

TOKEN = "t" * 48


def endpoint():
    return ac.Endpoint(name="amass", url="http://127.0.0.1:18090/mcp", token=TOKEN, docker="/usr/bin/docker",
                       container="amass-ai-test-mcp-1", network="amass-ai-test-net")


class ConnectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        env = {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / ".config"), "PATH": "/nonexistent"}
        for key in ("APPDATA", "CODEX_HOME", "CLINE_MCP_SETTINGS_PATH"):
            env[key] = ""
        self.env = mock.patch.dict(os.environ, env)
        self.env.start()
        self.platform = mock.patch.object(sys, "platform", "linux")
        self.platform.start()

    def tearDown(self):
        self.platform.stop()
        self.env.stop()
        self.tmp.cleanup()

    def connect(self, client_id, remove=False, force=False):
        return ac.apply(ac.BY_ID[client_id], endpoint(), remove, force, False)

    def test_every_json_client_writes_its_own_shape(self):
        want = {
            "cursor": (".cursor/mcp.json", ["mcpServers"], {"url": "http://127.0.0.1:18090/mcp"}),
            "vscode": (".config/Code/User/mcp.json", ["servers"], {"type": "http"}),
            "windsurf": (".codeium/windsurf/mcp_config.json", ["mcpServers"],
                         {"serverUrl": "http://127.0.0.1:18090/mcp"}),
            "gemini-cli": (".gemini/settings.json", ["mcpServers"], {"httpUrl": "http://127.0.0.1:18090/mcp"}),
            "copilot-cli": (".copilot/mcp-config.json", ["mcpServers"], {"type": "http", "tools": ["*"]}),
            "cline": (".cline/data/settings/cline_mcp_settings.json", ["mcpServers"], {"type": "streamableHttp"}),
            "zed": (".config/zed/settings.json", ["context_servers"], {"url": "http://127.0.0.1:18090/mcp"}),
            "lm-studio": (".lmstudio/mcp.json", ["mcpServers"], {"url": "http://127.0.0.1:18090/mcp"}),
            "opencode": (".config/opencode/opencode.json", ["mcp"], {"type": "remote", "enabled": True}),
            "kiro": (".kiro/settings/mcp.json", ["mcpServers"], {"url": "http://127.0.0.1:18090/mcp"}),
            "claude-desktop": (".config/Claude/claude_desktop_config.json", ["mcpServers"],
                               {"command": "/usr/bin/docker"}),
        }
        for cid, (rel, keys, fields) in want.items():
            with self.subTest(cid):
                path = self.home / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                results = self.connect(cid)
                self.assertEqual(results[0].action, "added")
                data = json.loads(path.read_text())
                for k in keys:
                    data = data[k]
                entry = data["amass"]
                for k, v in fields.items():
                    self.assertEqual(entry[k], v)
                if "command" in entry:
                    self.assertEqual(entry["args"][:3], ["exec", "-i", "amass-ai-test-mcp-1"])
                else:
                    self.assertEqual(entry["headers"], {"Authorization": "Bearer " + TOKEN})
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600, "a new file holds the token")

    def test_update_keeps_other_servers_and_backs_up(self):
        path = self.home / ".cursor" / "mcp.json"
        path.parent.mkdir()
        path.write_text(json.dumps({"mcpServers": {"other": {"url": "x"}, "amass": {"url": "old"}}, "k": 1}))
        r = self.connect("cursor")[0]
        self.assertEqual(r.action, "updated")
        self.assertTrue(r.backup and r.backup.exists())
        data = json.loads(path.read_text())
        self.assertEqual(data["mcpServers"]["other"], {"url": "x"})
        self.assertEqual(data["k"], 1)
        self.assertEqual(self.connect("cursor")[0].action, "unchanged")
        self.assertEqual(self.connect("cursor", remove=True)[0].action, "removed")
        self.assertNotIn("amass", json.loads(path.read_text())["mcpServers"])
        self.assertEqual(self.connect("cursor", remove=True)[0].action, "not configured")

    def test_commented_file_keeps_comments_when_key_is_new(self):
        path = self.home / ".config" / "zed" / "settings.json"
        path.parent.mkdir(parents=True)
        path.write_text('// Zed settings\n{\n  // theme\n  "theme": "One Dark", // trailing\n}\n')
        r = self.connect("zed")[0]
        self.assertEqual(r.action, "added")
        text = path.read_text()
        self.assertIn("// theme", text)
        data, _ = ac.load_json(path)
        self.assertEqual(data["theme"], "One Dark")
        self.assertEqual(data["context_servers"]["amass"]["url"], "http://127.0.0.1:18090/mcp")

        # Changing an existing entry in a commented file needs --force.
        endpoint_changed = endpoint()
        endpoint_changed.token = "u" * 48
        with self.assertRaises(ac.ConfigError):
            ac.json_apply(ac.BY_ID["zed"], endpoint_changed, path, False, False, False)
        r = ac.json_apply(ac.BY_ID["zed"], endpoint_changed, path, False, True, False)
        self.assertEqual(r.action, "updated")
        self.assertIsNotNone(r.backup)

    def test_commented_empty_object(self):
        path = self.home / ".config" / "zed" / "settings.json"
        path.parent.mkdir(parents=True)
        path.write_text("// empty\n{\n}\n")
        self.connect("zed")
        data, _ = ac.load_json(path)
        self.assertIn("amass", data["context_servers"])

    def test_codex_toml(self):
        path = self.home / ".codex" / "config.toml"
        path.parent.mkdir()
        path.write_text('model = "gpt-5"\n\n[mcp_servers.other]\ncommand = "x"\n\n'
                        '[mcp_servers.amass]\nurl = "old"\n\n[mcp_servers.amass.http_headers]\nA = "b"\n\n'
                        '[profiles.fast]\nmodel = "y"\n')
        self.assertEqual(self.connect("codex")[0].action, "updated")
        text = path.read_text()
        self.assertEqual(text.count("[mcp_servers.amass]"), 1)
        self.assertIn('url = "http://127.0.0.1:18090/mcp"', text)
        self.assertIn(f'Authorization = "Bearer {TOKEN}"', text)
        self.assertNotIn('url = "old"', text)
        for kept in ('model = "gpt-5"', "[mcp_servers.other]", "[profiles.fast]"):
            self.assertIn(kept, text)
        if sys.version_info >= (3, 11):
            import tomllib
            parsed = tomllib.loads(text)
            self.assertEqual(parsed["mcp_servers"]["amass"]["http_headers"]["Authorization"], "Bearer " + TOKEN)
        self.assertEqual(self.connect("codex")[0].action, "unchanged")
        self.assertEqual(self.connect("codex", remove=True)[0].action, "removed")
        self.assertNotIn("mcp_servers.amass", path.read_text())

    def test_claude_code_without_cli_edits_settings(self):
        path = self.home / ".claude.json"
        path.write_text(json.dumps({"numStartups": 3}))
        self.connect("claude-code")
        entry = json.loads(path.read_text())["mcpServers"]["amass"]
        self.assertEqual(entry["type"], "http")
        self.assertEqual(json.loads(path.read_text())["numStartups"], 3)

    def test_invalid_json_is_not_overwritten(self):
        path = self.home / ".cursor" / "mcp.json"
        path.parent.mkdir()
        path.write_text("{ not json")
        with self.assertRaises(ac.ConfigError):
            self.connect("cursor")
        self.assertEqual(path.read_text(), "{ not json")

    def test_manual_clients_print_instructions(self):
        for cid in ("goose", "continue", "jetbrains", "open-webui", "web", "generic", "cherry-studio"):
            with self.subTest(cid):
                r = self.connect(cid)[0]
                self.assertTrue(r.message)
        self.assertIn("streamable_http", self.connect("goose")[0].message)
        self.assertIn("docker network connect amass-ai-test-net", self.connect("open-webui")[0].message)

    def test_detection_and_status(self):
        ep = endpoint()
        self.assertFalse(ac.BY_ID["cursor"].detected())
        (self.home / ".cursor").mkdir()
        self.assertTrue(ac.BY_ID["cursor"].detected())
        self.assertFalse(ac.configured(ac.BY_ID["cursor"], ep))
        self.connect("cursor")
        self.assertTrue(ac.configured(ac.BY_ID["cursor"], ep))

    def test_operator_mode(self):
        ai = Path(self.tmp.name) / "repo"
        (ai / "data" / "state").mkdir(parents=True)
        (ai / "data" / "state" / ".mcp-token").write_text("r" * 48 + "\n")
        (ai / "data" / "state" / ".mcp-operator-token").write_text("o" * 48 + "\n")
        with mock.patch.object(ac, "REPO", ai), mock.patch.object(ac, "find_container", lambda d, n: "c1"):
            reader, operator = ac.build_endpoint("amass"), ac.build_endpoint("amass", True)
        self.assertEqual(reader.token, "r" * 48)
        self.assertEqual(operator.token, "o" * 48)
        self.assertNotIn("-operator", reader.stdio()[1])
        args = operator.stdio()[1]
        self.assertEqual(args[-1], "-operator")
        self.assertIn("AMASS_MCP_RUN_JOURNAL=/data/enumerations-stdio.jsonl", args)

        path = self.home / ".cursor" / "mcp.json"
        path.parent.mkdir()
        ac.apply(ac.BY_ID["cursor"], operator, False, False, False)
        self.assertEqual(json.loads(path.read_text())["mcpServers"]["amass"]["headers"]["Authorization"],
                         "Bearer " + "o" * 48)

    def test_kit_yaml_replaces_the_entry_and_keeps_the_rest(self):
        path = self.home / ".kit.yml"
        original = ("# KIT Configuration File\n# mcpServers:\n#   websearch:\n#     type: \"remote\"\n\n"
                    "mcpServers:\n  other:\n    type: \"local\"\n    command: [\"npx\", \"x\"]\n"
                    "  amass:\n    type: \"local\"\n    command:\n      - /usr/bin/docker\n      - exec\n\n"
                    "model: anthropic/claude\nmax-tokens: 4096\n")
        path.write_text(original)
        self.assertTrue(ac.configured(ac.BY_ID["kit"], endpoint()))
        r = self.connect("kit")[0]
        self.assertEqual(r.action, "updated")
        self.assertTrue(r.backup and r.backup.read_text() == original)
        text = path.read_text()
        self.assertIn("# KIT Configuration File\n# mcpServers:\n#   websearch:", text)
        self.assertIn("  other:\n    type: \"local\"\n    command: [\"npx\", \"x\"]\n", text)
        self.assertIn("  amass:\n    type: \"remote\"\n    url: \"http://127.0.0.1:18090/mcp\"\n"
                      "    headers:\n      - \"Authorization: Bearer " + TOKEN + "\"\n\nmodel: anthropic/claude\n"
                      "max-tokens: 4096\n", text)
        self.assertNotIn("exec", text)
        self.assertEqual(self.connect("kit")[0].action, "unchanged")

        self.assertEqual(self.connect("kit", remove=True)[0].action, "removed")
        text = path.read_text()
        self.assertNotIn("amass:", text)
        self.assertIn("  other:", text)
        self.assertIn("model: anthropic/claude", text)

    def test_kit_yaml_without_servers_and_kit_json(self):
        path = self.home / ".kit.yml"
        path.write_text("model: anthropic/claude\n")
        self.assertEqual(self.connect("kit")[0].action, "added")
        self.assertTrue(path.read_text().startswith("model: anthropic/claude\n\nmcpServers:\n  amass:\n"))

        path.unlink()
        (self.home / ".kit.json").write_text('{"model": "x"}')
        self.assertEqual(self.connect("kit")[0].action, "added")
        entry = json.loads((self.home / ".kit.json").read_text())["mcpServers"]["amass"]
        self.assertEqual(entry, {"type": "remote", "url": "http://127.0.0.1:18090/mcp",
                                 "headers": ["Authorization: Bearer " + TOKEN]})

    def test_kit_yaml_inline_servers_is_refused(self):
        (self.home / ".kit.yml").write_text("mcpServers: {other: {type: local}}\n")
        with self.assertRaises(ac.ConfigError):
            self.connect("kit")

    def test_cherry_studio_prints_its_import_json(self):
        r = self.connect("cherry-studio")[0]
        self.assertEqual(r.action, "manual")
        self.assertIn("Import from JSON", r.message)
        entry = json.loads(r.message[r.message.index("{"):])["mcpServers"]["amass"]
        self.assertEqual(entry, {"type": "streamableHttp", "url": "http://127.0.0.1:18090/mcp",
                                 "headers": {"Authorization": "Bearer " + TOKEN}})

    def test_strip_jsonc_keeps_strings(self):
        text, lossy = ac.strip_jsonc('{"a": "http://x//y", /* c */ "b": [1,],}')
        self.assertTrue(lossy)
        self.assertEqual(json.loads(text), {"a": "http://x//y", "b": [1]})


if __name__ == "__main__":
    unittest.main()
