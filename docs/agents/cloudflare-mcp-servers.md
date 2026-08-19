# Cloudflare MCP servers

The `cloudflare@cloudflare` plugin (from the `cloudflare/skills` marketplace) ships five remote MCP servers, 11 skills, and two slash commands. This note records the capability so agents know it exists, know its auth model, and know its hazards. Verified live on 2026-08-04: all five servers connected, and a read-only account call through `cloudflare-api` returned real data.

## MCP servers

| Server | Endpoint | Auth | Purpose |
|---|---|---|---|
| `cloudflare-docs` | `docs.mcp.cloudflare.com/mcp` | none | Live Cloudflare documentation search |
| `cloudflare-api` | `mcp.cloudflare.com/mcp` | OAuth | Generic Cloudflare API access (`search` the OpenAPI spec, `execute` arbitrary requests) |
| `cloudflare-bindings` | `bindings.mcp.cloudflare.com/mcp` | OAuth | KV, R2, D1, Hyperdrive, Workers |
| `cloudflare-builds` | `builds.mcp.cloudflare.com/mcp` | OAuth | Workers Builds history and build logs |
| `cloudflare-observability` | `observability.mcp.cloudflare.com/mcp` | OAuth | Workers logs, metrics, structured queries |

Server names are namespaced `plugin:cloudflare:<name>`; tools appear as `mcp__plugin_cloudflare_<server>__<tool>`.

## Auth model

`cloudflare-docs` is anonymous and works out of the box. The other four require a separate OAuth grant each, authorized in an interactive session:

```
claude mcp login plugin:cloudflare:cloudflare-api
```

The browser handles the redirect and the CLI captures the callback locally — no tokens or callback URLs ever transit the chat. Credentials are stored per-server in the OS keychain.

## Gotcha: tool registries are built at session start

Authorizing a server mid-session does not expose its tools to that session. `claude mcp list` shells out and health-checks live, so it will report a connected server while the running session still has zero tools registered for it — the two views legitimately disagree. Restart the session after authorizing. This is the same failure mode as installing the plugin in one session and expecting an already-running session to pick it up.

## Hazard: these servers are write-capable

`cloudflare-api.execute` runs arbitrary Cloudflare API requests, including `POST`/`PUT`/`PATCH`/`DELETE`. `cloudflare-bindings` additionally exposes explicitly destructive tools: `kv_namespace_delete`, `r2_bucket_delete`, `d1_database_delete`, `hyperdrive_config_delete`. Account-scoped write capability against production infrastructure (DNS zones, storage, Workers) has already been exercised on this account. Treat these servers as production-affecting and confirm before any non-read call — see the [MCP tool call confirmation rule](shared-operating-rules.md#mutating-mcp-tool-calls-need-explicit-confirmation).

## Skills and commands also provided

Skills (11): `cloudflare`, `workers-best-practices`, `wrangler`, `durable-objects`, `agents-sdk`, `sandbox-sdk`, `cloudflare-one`, `cloudflare-one-migrations`, `cloudflare-email-service`, `turnstile-spin`, `web-perf`.

Commands (2): `/build-mcp` (remote MCP server on Workers via `McpAgent`), `/build-agent` (AI agent via the Agents SDK).

See [nathanjohnpayne/mergepath#908](https://github.com/nathanjohnpayne/mergepath/issues/908) for the capability review that produced this note.
