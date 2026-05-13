# Stratium Agent Authorization Demo

A Docker Compose bundle that adds the **agent-gateway** (agent authorization service) on top of the standard Stratium demo stack. The agent-gateway issues scoped delegation JWTs for AI agents acting on behalf of users, then proxies their gRPC calls through to the platform, key-manager, and key-access services with the delegated identity attached.

## What's running

| Service                 | Port     | Purpose                                                              |
|-------------------------|----------|----------------------------------------------------------------------|
| `agent-gateway`         | 50054    | Mints + validates delegation tokens, proxies to downstream services  |
| `platform`              | 50051    | Policy / entitlement service (PAP)                                   |
| `key-manager`           | 50052    | Key management                                                       |
| `key-access`            | 50053    | Key access (KAS)                                                     |
| `keycloak`              | 8080     | OIDC provider, `stratium` realm                                      |
| `postgres`              | 5432     | Backing store (`stratium_pap`, `stratium_keymanager`, `keycloak`)    |
| `envoy`                 | 8081     | gRPC-Web proxy for browser clients                                   |
| `agent-claude-code`     | —        | Anthropic Claude Code CLI + scripted delegation flow                 |
| `agent-codex`           | —        | OpenAI Codex CLI + scripted delegation flow                          |

## Quickstart

```bash
# (Optional) Set up environment variables — only needed for MCP flows
cp .env.example .env
# Edit .env to add ANTHROPIC_API_KEY / OPENAI_API_KEY if you plan to run
# the MCP-based flows (demo-flow-mcp-claude / demo-flow-mcp-codex). The
# grpcurl-based flows work without any keys.

make quickstart
```

`make quickstart` runs `docker-compose down` then `up -d`. Postgres init scripts in `postgres/` create the `agents` + `delegations` tables, extend `audit_logs` with agent-authorization columns, and seed two demo agents — all in `stratium_pap` on the first run against a fresh volume.

> **Note:** docker-compose only reads `.env` at container *creation* time. If you edit `.env` after the stack is already up, recreate the agent containers so the new values land:
> ```bash
> docker-compose up -d --force-recreate agent-claude-code agent-codex
> ```

## Agent Gateway notes

- **Image pin:** `stratiumdata/agent-gateway:eval-1.0.8` — multi-arch (amd64+arm64) image published to Docker Hub. Override with `AGENT_GATEWAY_IMAGE=...` in your env to test a different build.
- **Delegation signing key:** Set `AGENT_GATEWAY_SIGNING_KEY` to a fixed string if you want delegation tokens to survive a container restart. The demo defaults to a placeholder; if unset entirely the server generates an ephemeral 32-byte key each boot.
- **OIDC client:** `stratium-agent-gateway` is registered in `keycloak/realm-export.json` with secret `stratium-agent-gateway-secret` (override via `OIDC_AGENT_GATEWAY_CLIENT_SECRET`).
- **Delegation knobs** (in `config/agent-gateway-server.yaml` under `agent_gateway:`):
  - `delegation_token_ttl: 15m` — default lifetime of a minted delegation
  - `delegation_max_ttl: 1h` — hard ceiling
  - `delegation_max_depth: 5` — subagent-of-subagent-of-... chain limit
  - `cascade_revoke: true` — revoking a parent revokes the entire subtree

## Delegation flow (the demo story)

1. **User authenticates** with Keycloak via the `stratium-cli-client` (or any standard-flow client) and gets an OIDC access token.
2. **Client calls `CreateDelegation`** on agent-gateway (port 50054), supplying the user's token plus the `agent_id`, requested tool/action scope, classification caps, and TTL.
3. **Agent-gateway** decodes the JWT `sub` claim to get the user id (signature verification is expected at the OIDC ingress — this build does not re-verify), looks up the agent in the `agents` table, checks the agent is enabled and certified, inserts a row in `delegations`, and returns a signed delegation JWT.
4. **Agent uses the delegation JWT** to call `ExecuteAction` on agent-gateway with the requested tool/tier/resource attributes. The gateway evaluates the whole delegation chain in-process against three checks: tool ∈ approved_tools, action_tier ≤ max_action_tier, resource classification ≤ delegation classification cap. (The OPA `agent-compound-authorization` policy is seeded into the `policies` table for future use; the runtime path in this build does the checks directly in Go.) If allowed, the gateway proxies to the downstream service (`platform.GetDecision`, etc.); if denied, it short-circuits and returns the deny reason.
5. **Subagent chains:** a delegation token can be presented as `parent_delegation_token` when minting a child delegation, building a chain up to `delegation_max_depth`. Scope can only narrow on each hop.
6. **Cascade revocation:** revoking a parent delegation cascades to every child. Suspending an agent revokes every active delegation for that agent.
7. **Audit trail:** every `CreateDelegation`, `ExecuteAction`, `RevokeDelegation`, and `SuspendAgent` writes a row into `audit_logs` with the agent id, delegation id, tool, action tier, decision, and (on deny) the depth and principal that rejected the action.

## Running the agent demos

Two AI agent containers are bundled — `agent-claude-code` (Anthropic) and `agent-codex` (OpenAI). Each has its CLI pre-installed (`@anthropic-ai/claude-code`, `@openai/codex`) plus scripted delegation flows in `/demo/`.

```bash
# Once the stack is up:
make demo-flow-claude      # Claude Code: mint + scope-test (1 allow + 2 denies) + chain inspect
make demo-flow-codex       # Codex: same flow with codex-specific scope (classification cap test)
make demo-flow-chain       # Multi-agent: user → claude → codex (depth=2), cascade revoke
make demo-flow-admin       # Register a new agent via gRPC, mint, suspend, see cascade revoke

make demo-flow-mcp-claude  # Real Claude Code CLI invoking the gateway via MCP (needs ANTHROPIC_API_KEY)
make demo-flow-mcp-codex   # Real Codex CLI invoking the gateway via MCP (needs OPENAI_API_KEY)

make demo-inspect          # Audit-style snapshot: agents + delegations + audit_logs + gateway log

# Manual: drop into a container
docker exec -it stratium-agent-claude-code bash
# Then either run /demo/flow.sh or use the CLI directly:
claude --help
```

Each per-agent `flow.sh` does six steps:
1. User `user` does a password-grant against Keycloak to get an OIDC access token.
2. Calls `CreateDelegation` on the gateway with that token + the agent's scope (tools, max action tier, classification caps).
3. Decodes and prints the delegation JWT claims.
4. Calls `ExecuteAction` with an action **inside** the scope → expects ALLOW.
5. Calls `ExecuteAction` with an action **outside** the scope → expects DENY.
6. Calls `GetDelegationChain` and prints the chain depth/structure.

`make demo-flow-chain` extends this: claude-code mints a child delegation for codex with **narrowed** scope, demonstrates that codex can only act inside that narrower set, then revokes the root and confirms cascade revocation kills the child.

`make demo-flow-admin` exercises the registry: registers a new ephemeral agent via the `RegisterAgent` RPC (not SQL seed), lists agents, mints a delegation, calls `SuspendAgent`, and confirms the just-minted delegation now denies (cascade from agent suspension).

`make demo-inspect` is a host-side script that shows the live state from postgres (agents + delegations + audit_logs) and parses the agent-gateway log for created delegations / authorized actions / denied actions. Run it after any flow to see the audit picture.

### Verbose output

Every demo target accepts `V=1` to surface what's happening under the hood — raw gRPC request/response payloads, Keycloak token exchange, decoded JWT claims, MCP server logs (for the MCP flows), and full audit-row JSONB columns. Useful when:

- You're walking a colleague through what the demo proves and want to point at the actual wire traffic
- You're debugging an unexpected ALLOW or DENY decision
- You want to see what data the gateway is persisting to `audit_logs`

```bash
make demo-flow-claude V=1       # shows gRPC payloads + JWT claims
make demo-flow-codex V=1        # codex flow with the classification-cap deny exposed in detail
make demo-flow-chain V=1        # adds per-call timing + parent/child JWT comparison
make demo-flow-admin V=1        # shows the RegisterAgent / SuspendAgent payloads in full
make demo-flow-mcp-claude V=1   # adds MCP server log (every gateway call the LLM dispatched)
make demo-inspect V=1           # full audit row (entire changes / result JSONB)
```

Bearer tokens and passwords are length-redacted in verbose output (e.g. `Bearer <1246 bytes>`) so terminal recordings stay safe to share.

### API keys

The grpcurl-based flows (`demo-flow-claude`, `demo-flow-codex`, `demo-flow-chain`, `demo-flow-admin`) call only the gateway — **no LLM API call is made**, so they run without `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`.

The MCP-based flows (`demo-flow-mcp-claude`, `demo-flow-mcp-codex`) run the actual CLI in headless mode, which DOES call the LLM. Set the corresponding API key in `.env` before running them. See `.env.example`.

Model selection is also configurable from `.env` — set `ANTHROPIC_MODEL` and/or `OPENAI_MODEL` to override each CLI's default model (useful if your default is quota-limited or you want to test a specific model's tool-use behavior). Leave blank to let each CLI pick its own default.

### MCP integration (eval-1.0.8+)

Each agent container also bundles a small Stratium MCP server at `/opt/stratium-mcp/server.js`. Both `claude` and `codex` are pre-configured to discover it on startup (`/root/.claude.json`, `/root/.codex/config.toml`). The MCP server exposes three tools:

| Tool                | Backed by                                | Purpose                                       |
|---------------------|------------------------------------------|-----------------------------------------------|
| `create_delegation` | `AgentGatewayService/CreateDelegation`   | Mint a scoped delegation JWT                  |
| `execute_action`    | `AgentGatewayService/ExecuteAction`      | Ask the gateway to authorize an action        |
| `revoke_delegation` | `AgentGatewayService/RevokeDelegation`   | Revoke a delegation (cascades to children)    |

`make demo-flow-mcp-claude` (or `-codex`) runs the CLI in headless mode with a prompt that instructs it to use these tools. The CLI's reasoning loop picks them up, calls the gateway through MCP, and reports what happened. Every call lands in the `audit_logs` table — verify with `make demo-inspect` afterward.

**Caveats and CLI quirks the scripts work around:**

- **Codex auth.** Codex CLI v0.130+ doesn't read `OPENAI_API_KEY` directly for runtime auth — it requires `codex login --with-api-key` to persist the key to `~/.codex/auth.json`. `mcp-flow.sh` runs the login step automatically on the first invocation in a fresh container.
- **Codex sandbox.** Codex defaults to `approval: never` + `sandbox: read-only`, which auto-cancels every MCP tool call. The script invokes codex with `--dangerously-bypass-approvals-and-sandbox` because the Docker container is the external sandbox — codex's internal one is redundant here.
- **Claude prompt input.** `claude --allowedTools <list...>` is variadic and would consume the prompt as a tool name if passed positionally. The script pipes the prompt via stdin instead.
- **Failure detection.** `mcp-flow.sh` scans the CLI output for known failure markers (`Quota exceeded`, `401 Unauthorized`, `Invalid API key`, `user cancelled MCP tool call`, etc.) and exits non-zero with a clear remediation hint. This way `make` reports the error rather than a misleading green check when the LLM never actually reached the gateway.

### Pre-registered agent identities

The demo seeds two agents at fresh-volume boot (`postgres/05-init-demo-agents.sql`) so the flow scripts can use fixed UUIDs:

| Agent              | UUID                                   | Provider   | Trust tier  | Approved tools                                        |
|--------------------|----------------------------------------|------------|-------------|-------------------------------------------------------|
| claude-code-agent  | `11111111-1111-1111-1111-111111111111` | anthropic  | CERTIFIED   | `read_file, search, list_documents, web_fetch`        |
| codex-agent        | `22222222-2222-2222-2222-222222222222` | openai     | CERTIFIED   | `read_file, write_file, execute_code, search`         |

### What enforcement is exercised in the demo

Each flow asserts on three checks the gateway enforces in `evaluateDelegationScope`:

| Check                       | Where it lives                       | How the demo exercises it                     |
|-----------------------------|--------------------------------------|-----------------------------------------------|
| Tool ∈ `approved_tools`     | server.go (per-delegation)           | claude step 4 denies `write_file`             |
| `action_tier` ≤ max         | server.go (per-delegation)           | claude step 5 / codex step 5 deny tier=4      |
| Classification cap          | server.go `checkClassificationCap`   | codex step 4 denies SECRET vs CONFIDENTIAL    |

Classification cap enforcement is fail-closed: a resource with `classification` set but no `hierarchy` attribute is denied (ambiguity = deny), so a caller can't bypass caps by omitting the hierarchy.

### History

- **eval-1.0.8** (current) — `CreateDelegation` / `ExecuteAction` / `RevokeDelegation` / `SuspendAgent` now write rows to `audit_logs` using the agent-specific columns added by `04-init-agent-auth.sql`. `make demo-inspect` shows a real audit trail.
- **eval-1.0.7** — `extractUserID` now decodes the JWT `sub` claim; `evaluateDelegationScope` enforces `classification_caps` against `resource_attributes`. The demo flow scripts no longer pass `x-user-id` workarounds.
- **eval-1.0.6** — initial agent-gateway image. Required `x-user-id` workaround (raw bearer header overflowed `VARCHAR(255)`); classification caps were stored but not enforced.

### Upstream gaps the demo intentionally works around

These don't block the demo but are real things to track separately:

1. **Prometheus `stratium_agent_*` counters are feature-flagged off.** `metrics.go` defines them, but `BUILD_FEATURES=agent-auth` (used to build `eval-1.0.8`) doesn't include observability. Rebuild with `BUILD_FEATURES=agent-auth,metrics` to surface them at `agent-gateway:9094/metrics`.
2. **`ExecuteAction` only forwards when `payload` is non-empty.** server.go guards the proxy call on `len(req.Payload) > 0`. The grpcurl-based demos send empty payloads, so the gateway decides allow/deny but never actually invokes downstream `platform.GetDecision`. A real client (Go SDK, MCP shim) would marshal the downstream request as proto bytes and pass them in `payload` — the gateway's authorize-then-forward path is wired and works.
3. **Agent-gateway expects every `CreateDelegation` to carry user identity, even for child delegations.** The proto comment says "For child delegations: parent delegation token + child agent credentials." In practice `extractUserID` runs unconditionally. The chain demo sends the user's bearer token on every hop as a result. The cleaner fix is to skip `extractUserID` when `parent_delegation_token` is present and derive the user from the parent JWT's `user_id` claim.

## Repo layout

```
stratium-agent-demo/
├── docker-compose.yml          # 7 services + 2 agent containers on stratium-network
├── Makefile                    # quickstart / demo-flow-* / demo-inspect targets
├── .env.example                # API keys, demo user creds, model overrides
├── config/                     # per-service YAML configs (mounted into containers)
│   ├── agent-gateway-server.yaml
│   ├── key-access-server.yaml
│   ├── key-manager.yaml
│   └── platform-server.yaml
├── postgres/                   # init scripts run in order on fresh volume
│   ├── 01-init-multiple-dbs.sql
│   ├── 02-init-pap.sql
│   ├── 03-init-keymanager.sql
│   ├── 04-init-agent-auth.sql  # agents + delegations tables + audit_logs extension
│   └── 05-init-demo-agents.sql # seeds the two demo agents
├── keycloak/
│   ├── realm-export.json       # stratium realm, demo users, OIDC clients
│   └── stratium-login/         # custom login theme
├── envoy.yaml                  # gRPC-Web proxy for browser clients
├── agents/                     # AI agent containers (Dockerfile + flow scripts)
│   ├── Dockerfile              # parameterized: AGENT_PACKAGE, AGENT_NAME
│   ├── claude-code/flow.sh     # claude-code agent's delegation lifecycle demo
│   ├── codex/flow.sh           # codex agent's lifecycle demo (incl. classification cap)
│   └── common/
│       ├── flow-lib.sh         # shared helpers (vlog/grpc_call/jwt_payload)
│       ├── chain-flow.sh       # depth-2 chain demo + cascade revoke
│       ├── admin-flow.sh       # RegisterAgent + ListAgents + SuspendAgent demo
│       └── mcp-flow.sh         # real CLI invokes gateway through MCP
├── mcp/                        # Stratium MCP server (stdio transport)
│   ├── package.json            # @modelcontextprotocol/sdk + zod
│   └── server.js               # 3 tools: create/execute/revoke
└── bin/
    └── inspect.sh              # demo-inspect: agents + delegations + audit_logs
```

> The demo doesn't ship `.proto` files. The agent-gateway has gRPC reflection enabled, so `grpcurl` (used by all flow scripts and the MCP server) discovers the service surface at runtime. If you want the canonical proto definition, see `stratium/proto/services/agent-gateway/agent-gateway.proto` in the upstream repo.

## Client tutorial

Golang CLI Client → [Stratium Documentation](https://www.stratium.dev/docs)

## Cleanup

```bash
make docker-clean   # stop + remove volumes (wipes postgres data)
```
