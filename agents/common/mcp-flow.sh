#!/usr/bin/env bash
# Demo: a real agent CLI invokes the agent-gateway through the Stratium MCP server.
#
# Unlike flow.sh / chain-flow.sh / admin-flow.sh (which use grpcurl directly),
# this flow runs the actual claude / codex CLI in headless mode. The CLI's
# reasoning loop decides to call the MCP server's tools (create_delegation,
# execute_action, revoke_delegation), which in turn call the agent-gateway.
#
# Requires: ANTHROPIC_API_KEY (claude) or OPENAI_API_KEY (codex) in env.
#
# What the demo shows:
#   - The CLI discovers the Stratium MCP server at startup
#   - The CLI invokes create_delegation as one of its tools
#   - The CLI invokes execute_action and observes ALLOW/DENY
#   - The agent-gateway audit_logs table records each call (visible via demo-inspect)

set -euo pipefail
. /demo/flow-lib.sh

# Detect which agent we're in by binary presence.
if command -v claude >/dev/null 2>&1; then
    AGENT_BIN="claude"
    AGENT_LABEL="claude-code-agent"
    AGENT_UUID="11111111-1111-1111-1111-111111111111"
    KEY_ENV_VAR="ANTHROPIC_API_KEY"
elif command -v codex >/dev/null 2>&1; then
    AGENT_BIN="codex"
    AGENT_LABEL="codex-agent"
    AGENT_UUID="22222222-2222-2222-2222-222222222222"
    KEY_ENV_VAR="OPENAI_API_KEY"
else
    fail "No supported agent CLI found in PATH (looked for: claude, codex)"
    exit 1
fi

section "${AGENT_LABEL}: real CLI invocation through MCP"
note "binary: ${AGENT_BIN}  gateway: ${GATEWAY_ADDR}"

# ─── 1. API key presence check ───────────────────────────────────────────────
step "Step 1: verify the LLM API key is set"
if [ -z "${!KEY_ENV_VAR:-}" ]; then
    fail "${KEY_ENV_VAR} is not set. Add it to .env at the project root, then re-up the stack."
    exit 1
fi
ok "${KEY_ENV_VAR} present ($(echo "${!KEY_ENV_VAR}" | wc -c) bytes)"

# ─── 2. MCP server smoke check ───────────────────────────────────────────────
step "Step 2: smoke-test the Stratium MCP server (must respond to a tools/list request)"
LIST_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"smoke","version":"0"},"capabilities":{}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
TOOL_LIST=$(echo "$LIST_REQ" | node /opt/stratium-mcp/server.js 2>/dev/null \
    | grep -o '"name":"[a-z_]*"' | sort -u || true)
if echo "$TOOL_LIST" | grep -q "create_delegation" && echo "$TOOL_LIST" | grep -q "execute_action"; then
    ok "MCP server advertises: $(echo "$TOOL_LIST" | tr '\n' ' ')"
else
    fail "MCP server didn't list expected tools. Got: $TOOL_LIST"
    exit 1
fi

# ─── 3. Invoke the CLI in headless mode ──────────────────────────────────────
step "Step 3: run ${AGENT_BIN} in headless mode with a Stratium-aware prompt"
note "the CLI's tool-calling loop should decide to invoke create_delegation + execute_action"

# Clear the MCP server's tee'd log so verbose mode shows ONLY this run.
MCP_LOG_FILE="${MCP_LOG_FILE:-/tmp/mcp-stratium.log}"
: > "$MCP_LOG_FILE" 2>/dev/null || true

PROMPT="You have access to the stratium-agent-gateway MCP server. Use it to:
1. Call create_delegation with agent_id=${AGENT_UUID}, approved_tools=[\"read_file\",\"search\"], max_action_tier=1, classification_caps={\"nato\":\"CONFIDENTIAL\"}, purpose=\"MCP-driven demo\", ttl_seconds=300.
2. Take the delegation_token from that response and call execute_action with tool_name=\"read_file\", action_tier=1, resource_attributes={\"classification\":\"CONFIDENTIAL\",\"hierarchy\":\"nato\"}.
3. Then call execute_action again with tool_name=\"write_file\" (which is NOT in the delegation scope) — this should fail.
Report what happened in 4 sentences."

case "$AGENT_BIN" in
    claude)
        # Claude Code headless mode reads ANTHROPIC_API_KEY from env directly.
        # --allowedTools is variadic (<tools...>) so it eats following args.
        # Pipe the prompt via stdin to keep it cleanly separated from flags.
        CLAUDE_MODEL_ARGS=()
        if [ -n "${ANTHROPIC_MODEL:-}" ]; then
            CLAUDE_MODEL_ARGS+=(--model "$ANTHROPIC_MODEL")
            note "model: ${ANTHROPIC_MODEL} (overridden via ANTHROPIC_MODEL)"
        fi
        OUTPUT=$(printf '%s' "$PROMPT" | claude --print --output-format=text \
            "${CLAUDE_MODEL_ARGS[@]+"${CLAUDE_MODEL_ARGS[@]}"}" \
            --allowedTools "mcp__stratium-agent-gateway__create_delegation" \
                           "mcp__stratium-agent-gateway__execute_action" \
                           "mcp__stratium-agent-gateway__revoke_delegation" \
            2>&1 || true)
        ;;
    codex)
        # Codex v0.130+ doesn't read OPENAI_API_KEY directly; the env var must
        # be persisted to ~/.codex/auth.json via `codex login --with-api-key`
        # before `codex exec` will authenticate.
        if ! codex login status 2>/dev/null | grep -q "Logged in"; then
            note "first-time codex auth: persisting OPENAI_API_KEY via codex login"
            printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1 || {
                fail "codex login --with-api-key failed"
                exit 1
            }
        fi
        # Codex takes model override via the -c TOML key.
        CODEX_MODEL_ARGS=()
        if [ -n "${OPENAI_MODEL:-}" ]; then
            CODEX_MODEL_ARGS+=(-c "model=\"$OPENAI_MODEL\"")
            note "model: ${OPENAI_MODEL} (overridden via OPENAI_MODEL)"
        fi
        # --dangerously-bypass-approvals-and-sandbox: turn off codex's INTERNAL
        # sandbox+approval interlock. Without this, codex's default `approval:never`
        # + `sandbox:read-only` policy auto-cancels every MCP tool call (it treats
        # them as state-changing and so requiring user approval, which "never"
        # mode denies). The docker container is the actual external sandbox here.
        OUTPUT=$(codex exec --skip-git-repo-check \
            --dangerously-bypass-approvals-and-sandbox \
            "${CODEX_MODEL_ARGS[@]}" \
            "$PROMPT" 2>&1 || true)
        ;;
esac

echo "$OUTPUT" | sed 's/^/  /'

# ─── 4. Detect upstream LLM failures and fail loudly ─────────────────────────
# These are NOT demo bugs — they're API account / billing / auth issues that
# stop the CLI from ever reaching the model, so no MCP tools get called. If we
# print "demo complete" anyway the user gets a misleading green checkmark.
LLM_FAIL_PATTERNS='Quota exceeded|401 Unauthorized|403 Forbidden|Missing bearer|Invalid API key|API key not provided|invalid_api_key|insufficient_quota|model_not_found|ECONNREFUSED'
if echo "$OUTPUT" | grep -qE "$LLM_FAIL_PATTERNS"; then
    section "${AGENT_LABEL}: LLM call failed — MCP path NOT exercised"
    fail "Upstream LLM error detected. The CLI never reached the tool-calling loop."
    echo "$OUTPUT" | grep -E "$LLM_FAIL_PATTERNS" | head -3 | sed 's/^/  /'
    note ""
    note "Common causes:"
    note "  • OpenAI/Anthropic billing not enabled or out of credits"
    note "  • API key invalid, expired, or revoked"
    note "  • Model not available on your account/region"
    note ""
    note "This is independent of the demo and the gateway — fix the underlying"
    note "account issue, then re-run. The grpcurl-based flows (demo-flow-claude,"
    note "demo-flow-codex, demo-flow-chain, demo-flow-admin) don't need API keys"
    note "and prove the gateway works end-to-end."
    exit 1
fi

# Tool-execution rejection: the LLM tried to call a tool but the CLI's own
# sandbox/approval policy refused to dispatch the call. Distinct from an LLM
# error — the model and gateway are both willing, but the CLI in between said no.
TOOL_REJECT_PATTERNS='user cancelled MCP tool call|MCP tool call .* (denied|rejected|forbidden)|tool call .* not permitted'
if echo "$OUTPUT" | grep -qE "$TOOL_REJECT_PATTERNS"; then
    section "${AGENT_LABEL}: tool call rejected by the CLI — gateway was NEVER hit"
    fail "The CLI's approval/sandbox policy refused to dispatch the MCP call."
    echo "$OUTPUT" | grep -E "$TOOL_REJECT_PATTERNS" | head -3 | sed 's/^/  /'
    note ""
    note "For codex: ensure --dangerously-bypass-approvals-and-sandbox is in"
    note "the invocation (the container is the external sandbox; codex's internal"
    note "sandbox is redundant here)."
    note "For claude: ensure --allowedTools includes the mcp__ prefixed tool names."
    exit 1
fi

# ─── 5. Verbose: replay the MCP server's view of what happened ───────────────
if [ -n "${VERBOSE:-}" ] && [ -s "$MCP_LOG_FILE" ]; then
    section "MCP server log (every tool call the CLI dispatched)"
    note "(this is what the Stratium MCP shim saw — request payloads + gateway responses)"
    cat "$MCP_LOG_FILE" | sed 's/^/  /'
fi

# ─── 6. Hint at audit verification ───────────────────────────────────────────
step "Step 6: confirm audit_logs captured the MCP-driven calls"
note "running on host: docker exec stratium-postgres ..."
note "(skip if this script is run inside a container without host docker access)"

section "${AGENT_LABEL}: MCP demo complete"
echo -e "${BOLD}${GREEN}✓ CLI invoked the gateway through MCP; tool calls visible in CLI output${NC}"
note "Run 'make demo-inspect' on the host to see the audit_logs rows this flow created."
