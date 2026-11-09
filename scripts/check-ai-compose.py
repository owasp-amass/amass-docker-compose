#!/usr/bin/env python3
"""Validate the merged, opt-in Amass Compose test topology without starting it."""
import json
import subprocess
import sys

FILES = ["compose.yaml", "compose.ai.yaml", "compose.ai-stack.yaml", "compose.ai-isolation.yaml"]

def main():
    args = ["docker", "compose"]
    for path in FILES:
        args += ["-f", path]
    args += ["--profile", "ai", "--profile", "ai-mcp", "--profile", "ai-model", "config", "--format", "json"]
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        sys.exit("ERROR: Docker Compose not found; run this on the Docker test host.")
    except subprocess.CalledProcessError as exc:
        sys.exit("ERROR: Compose validation failed:\n" + exc.stderr)
    try:
        config = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        sys.exit(f"ERROR: invalid compose JSON: {exc}")
    services = config.get("services", {})
    expected = {"enum", "subs", "assoc", "track", "viz", "engine", "assetdb",
                "postal", "syslog", "ai", "ai-mcp", "ollama"}
    missing = expected - set(services)
    assert not missing, f"Missing services: {sorted(missing)}"

    project = config.get("name", "")
    assert project and project != "amass", "Use a separate test project name"
    network = config.get("networks", {}).get("amass", {})
    assert network.get("name") != "amass-net", "Test network collides with legacy Amass network"

    for service in ("engine", "assetdb", "postal", "syslog", "neo4j"):
        name = services[service].get("container_name", "")
        assert name.startswith(project + "-"), (service, name)

    for service in ("enum", "subs", "assoc", "track", "viz", "engine", "ai", "ai-mcp"):
        assert services[service].get("image", "").endswith("amass-ai:dev"), (
            service, "Legacy image accidentally enabled in feature-image overlay")

    # Database must not publish on the standard baseline 55432 port.
    db_ports = services["assetdb"].get("ports", [])
    assert db_ports, "Expected private loopback-only test DB port"
    for port in db_ports:
        assert port.get("host_ip") in ("127.0.0.1", "::1"), port
        assert int(port.get("published", 0)) != 55432, port

    assert not services["ollama"].get("ports"), "Ollama must not publish a host port"
    assert "ai" in services["ai"].get("profiles", []), "AI service must be opt-in"
    assert "ai-model" in services["ollama"].get("profiles", []), "Ollama must be opt-in"

    ai = services["ai"]
    assert ai.get("environment", {}).get("XDG_CONFIG_HOME") == "/data/.config"
    mounts = ai.get("volumes", [])
    assert any(m.get("target") == "/.config/amass" and m.get("read_only")
               for m in mounts), "AI should mount Amass configuration read-only"
    assert any(m.get("target") == "/data" and not m.get("read_only")
               for m in mounts), "AI needs a writable output directory"

    print(f"PASS: isolated Compose project={project}, network={network.get('name')}")
    print("PASS: legacy binaries, AI, PostgreSQL and Ollama services are declared")
    print("PASS: DB published only to loopback on a non-default host port")
    print("PASS: Ollama is internal-only; AI and Ollama services are opt-in")
    print("PASS: AI configuration is read-only with a separate writable data directory")
    print("No containers started and no real-world collection performed.")

if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        sys.exit(f"ERROR: isolation check failed: {exc}")
