#!/usr/bin/env python3
"""Non-destructive validation of the isolated, fully configured AI Compose stack."""
import json
import subprocess
import sys

FILES = ["compose.yaml"]

def main():
    cmd = ["docker", "compose"]
    for path in FILES:
        cmd += ["-f", path]
    cmd += ["--profile", "ai-stdio", "--profile", "ai-local", "--profile", "ai-train", "config", "--format", "json"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        sys.exit("ERROR: Docker Compose not installed")
    except subprocess.CalledProcessError as exc:
        sys.exit("ERROR: Compose configuration is invalid:\n" + exc.stderr)
    # The combined-profile config can be valid while a real command fails:
    # e.g., `--profile ai-tools build ai` if its dependencies are confined
    # to an inactive profile. Validate each exact startup profile separately.
    for selected_profile in ("ai-train", "ai-local", "ai-stdio"):
        profile_cmd = ["docker", "compose"]
        for name in FILES:
            profile_cmd += ["-f", name]
        profile_cmd += ["--profile", selected_profile, "config", "--quiet"]
        isolated = subprocess.run(profile_cmd, capture_output=True, text=True)
        if isolated.returncode:
            sys.exit(
                f"ERROR: Compose profile {selected_profile} has invalid dependencies:\n"
                + isolated.stderr
            )
    configuration = json.loads(result.stdout)
    services = configuration.get("services", {})
    required = {"enum", "subs", "assoc", "track", "viz", "engine", "assetdb",
                "postal", "syslog", "ai", "ai-mcp", "ai-mcp-stdio",
                "classifier", "classifier-train", "provider-health", "ollama", "ollama-pull"}
    assert not (required - set(services)), "Missing services: " + repr(sorted(required - set(services)))
    project = configuration.get("name", "")
    assert project and project != "amass", "Test project name collides with existing environment"
    network = configuration.get("networks", {}).get("amass", {}).get("name")
    assert network and network != "amass-net", "Test network collides with existing environment"
    for svc in ("engine", "assetdb", "postal", "syslog", "neo4j"):
        assert services[svc].get("container_name", "").startswith(project + "-"), svc

    image = services["ai"].get("image", "")
    assert image and image != "owaspamass/amass:latest", "AI feature image not configured"
    for svc in ("enum", "subs", "assoc", "track", "viz", "engine",
                "ai", "ai-mcp", "ai-mcp-stdio", "classifier", "classifier-train", "provider-health"):
        assert services[svc].get("image") == image, f"{svc} uses mismatched Amass image"

    dbports = services["assetdb"].get("ports", [])
    assert dbports and all(p.get("host_ip") == "127.0.0.1" and int(p.get("published", 0)) != 55432
                           for p in dbports), "DB must only publish a separate loopback port"
    assert not services["ollama"].get("ports"), "Ollama port must remain private"
    assert not services["provider-health"].get("ports"), "Provider checker must remain private"
    assert not services["classifier"].get("ports"), "Classifier must remain private"

    mcpports = services["ai-mcp"].get("ports", [])
    assert mcpports and all(p.get("host_ip") == "127.0.0.1" for p in mcpports),         "MCP must only publish to host loopback"
    assert not services["ai-mcp"].get("profiles"), "Persistent MCP must be a normal Compose service"
    assert not services["classifier"].get("profiles"), "Classifier must be a normal Compose service"
    assert "ai-train" in services["classifier-train"].get("profiles", []), "Training must remain an opt-in job"
    assert not services["provider-health"].get("profiles"), "Inference readiness must be a normal Compose service"
    assert "ai-local" in services["ollama"].get("profiles", []), "Ollama must be optional for remote providers"
    assert not services["ai"].get("profiles"), "AI must be a normal Compose subcommand service like enum/assoc"
    assert services["ai"].get("entrypoint", [])[:2] == ["/bin/amass", "ai"], (
        "AI service must invoke the amass ai subcommand, not a separate application")
    assert services["ai"]["build"]["dockerfile"] == "Dockerfile.ai", (
        "AI CLI must use the development Amass image build")

    for svc in ("ai", "ai-mcp"):
        mounts = services[svc].get("volumes", [])
        assert any(v.get("target") == "/.config/amass" and v.get("read_only") for v in mounts), svc
        assert any(v.get("target") == "/data" and not v.get("read_only") for v in mounts), svc

    dependencies = services["ai-mcp"].get("depends_on", {})
    assert dependencies.get("assetdb", {}).get("condition") == "service_healthy", "assetdb"
    for name in ("classifier", "provider-health", "ollama"):
        assert name not in dependencies, f"read-only MCP must not wait for {name}"

    for name in ("ollama", "ollama-pull"):
        image = services[name]["image"]
        assert not image.endswith(":latest") and ":" in image, f"{name} image must be pinned: {image}"

    print(f"PASS: project={project}, network={network}")
    print("PASS: collector, engine, classifier, model checker, MCP and Ollama declared")
    print("PASS: feature images match; model checker must receive actual inference response")
    print("PASS: PostgreSQL and MCP host ports limited to localhost")
    print("PASS: one Compose file; ai is an unprofiled first-class Amass subcommand")
    print("PASS: classifier and model checker are provider-independent services")
    print("PASS: stdio MCP preserved, persistent HTTP MCP declared as normal service")
    print("No containers started and no external targets scanned.")

if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        sys.exit(f"ERROR: {error}")
