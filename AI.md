# Optional AI investigation services (development preview)

The AI implementation is being developed on the `feature/ai-investigation-inference` branches. The published `owaspamass/amass:latest` image does not yet include these binaries. This Compose overlay is **not ready for production use** and must be paired with an AI-enabled Amass build.

The overlay is opt-in and preserves the existing `assetdb` database, `amass` network, and configuration directory. It defines two services:

- `ai`: One-shot natural-language investigations and inference commands (Compose profile `ai`).
- `ai-mcp`: Read-only MCP stdio transport for a trusted local client (profile `ai-mcp`).

It intentionally does **not** start an inference worker or local LLM daemon. A persistent worker will be added after durable queueing, idempotent proposals, and health monitoring are implemented.

## Build a development image

After the Amass feature branch contains the AI sources and the Dockerfile copies the dedicated `amass-ai-mcp` binary to `/bin/amass-ai-mcp`, build that checkout:

```sh
docker build -t amass-ai:dev /path/to/amass-checkout
```

You may set `AMASS_AI_IMAGE` if you use another local image tag. Do not use `owaspamass/amass:latest` until the AI subcommand and MCP binary are part of that image.

## One-shot investigation

```sh
mkdir -p data/ai
export AMASS_AI_API_KEY='provider-key'
docker compose -f compose.yaml -f compose.ai.yaml --profile ai run --rm \
  ai -provider compatible \
  -endpoint https://api.openai.com/v1/chat/completions \
  -model MODEL -question 'What services are associated with this asset?' ask
```

The AI CLI reads `/.config/amass/config.yaml` and uses the configured primary Asset Database. The configuration volume is read-only; `./data/ai` is writable for proposal journals, and must be made writable by the non-root image user. Treat proposals and output as sensitive.

For inference, supply `-journal /data/inferences.jsonl` and use `infer` or `scan`. No OAM relationships are changed automatically by the prototype.

## MCP stdio

No network ports are exposed for MCP. Avoid dependency startup messages on JSON-RPC stdout by starting the database separately before launching a stdio session:

```sh
docker compose up -d assetdb
docker compose -f compose.yaml -f compose.ai.yaml --profile ai-mcp run \
  --rm --no-deps -T ai-mcp
```

Configure your MCP client to spawn the latter command with its working directory set to this Compose repository. Grant access only to trusted users: the prototype does not provide user-specific database authorization.

## Model endpoint and data-handling considerations

The current model adapter requires HTTPS for remote endpoints and allows plain HTTP only to localhost. Inside a container, localhost is the container itself. A separate Ollama container requires a carefully scoped internal HTTP allowance or a TLS endpoint. Do not globally disable HTTPS validation.

Hosted model providers may receive sensitive graph evidence. Use approved providers and appropriate data-handling controls. Never commit API keys to the repository. Environment variables are convenient for local development but are not a complete production secret-management solution.

This overlay is a deployment scaffold for the initiative, not a claim that full Amass AI integration is already compiled, released, or operational.
