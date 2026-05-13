#!/usr/bin/env bash
# Demo: delegation chain (depth=2).
#
# Flow:
#   user → claude-code (depth=1, scope: read_file+search) → codex (depth=2, scope: read_file only)
#
# Demonstrates:
#   • parent_delegation_token usage
#   • scope narrowing on each hop (codex inherits a strict subset)
#   • chain visibility via GetDelegationChain
#   • cascade revocation: revoking the parent kills the child

set -euo pipefail
. /demo/flow-lib.sh

CLAUDE_ID="11111111-1111-1111-1111-111111111111"
CODEX_ID="22222222-2222-2222-2222-222222222222"

section "Delegation chain demo — claude-code → codex (depth 2)"

# ─── 1. User authenticates ───────────────────────────────────────────────────
step "Step 1: User '${DEMO_USER}' authenticates with Keycloak"
USER_TOKEN=$(get_user_token)
ok "Got OIDC access token"

# ─── 2. Root delegation: user → claude-code-agent ────────────────────────────
step "Step 2: User delegates to claude-code-agent (root, depth=0)"
note "scope: read_file + search, tier ≤ READ_ONLY"
ROOT=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/CreateDelegation \
    '{
      "agent_id": "'"$CLAUDE_ID"'",
      "approved_tools": ["read_file", "search"],
      "approved_actions": [0, 1],
      "max_action_tier": 1,
      "classification_caps": {"nato": "CONFIDENTIAL"},
      "purpose": "Multi-agent research pipeline (root)",
      "ttl_seconds": 900,
      "conversation_id": "demo-chain-001"
    }')
if echo "$ROOT" | jq -e '.grpc_error' >/dev/null 2>&1; then
    fail "root CreateDelegation failed: $(echo "$ROOT" | jq -r .grpc_error)"; exit 1
fi
ROOT_TOKEN=$(echo "$ROOT" | jq -r '.delegationToken')
ROOT_ID=$(echo "$ROOT" | jq -r '.delegationId')
ok "Root delegation: ${ROOT_ID}"
note "depth: $(jwt_payload "$ROOT_TOKEN" | jq -r '.depth // 0')"

# ─── 3. Child delegation: claude-code → codex ────────────────────────────────
step "Step 3: claude-code-agent delegates to codex-agent (child, depth=1)"
note "child scope must NARROW parent: codex gets read_file only (no search)"
CHILD=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/CreateDelegation \
    '{
      "agent_id": "'"$CODEX_ID"'",
      "approved_tools": ["read_file"],
      "approved_actions": [0, 1],
      "max_action_tier": 1,
      "classification_caps": {"nato": "CONFIDENTIAL"},
      "purpose": "Codex sub-agent: file reads only",
      "ttl_seconds": 600,
      "conversation_id": "demo-chain-001",
      "parent_delegation_token": "'"$ROOT_TOKEN"'"
    }')
if echo "$CHILD" | jq -e '.grpc_error' >/dev/null 2>&1; then
    fail "child CreateDelegation failed: $(echo "$CHILD" | jq -r .grpc_error)"; exit 1
fi
CHILD_TOKEN=$(echo "$CHILD" | jq -r '.delegationToken')
CHILD_ID=$(echo "$CHILD" | jq -r '.delegationId')
ok "Child delegation: ${CHILD_ID}"
note "claims: $(jwt_payload "$CHILD_TOKEN" | jq -c '{delegation_id, agent_id, depth, root_delegation_id, approved_tools}')"

# ─── 4. Child can execute within its narrowed scope ──────────────────────────
step "Step 4: codex executes read_file (in narrowed scope) — expect ALLOW"
OK_RESP=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$CHILD_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "read",
      "action_tier": 1,
      "tool_name": "read_file",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_authorized "codex read_file (in scope)" "$OK_RESP"

# ─── 5. Child CANNOT use parent's wider scope ────────────────────────────────
step "Step 5: codex tries 'search' (in parent scope, NOT in child scope) — expect DENY"
DENY_RESP=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$CHILD_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "read",
      "action_tier": 1,
      "tool_name": "search",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_denied "codex search (narrowed-out by child scope)" "$DENY_RESP"

# ─── 6. Inspect the full chain ───────────────────────────────────────────────
step "Step 6: GetDelegationChain — confirm depth=2"
CHAIN=$(grpc_call \
    agent_gateway.AgentGatewayService/GetDelegationChain \
    '{"delegation_id": "'"$CHILD_ID"'"}')
DEPTH=$(echo "$CHAIN" | jq -r '.totalDepth')
ok "chain total_depth = ${DEPTH}"
show "$(echo "$CHAIN" | jq '{rootDelegationId, totalDepth, chain: [.chain[]? | {agentName, trustTier, delegationId}]}')"

# ─── 7. Cascade revocation: revoking the parent kills the child ──────────────
step "Step 7: Revoke the ROOT delegation, then test the CHILD"
REVOKE=$(grpc_call \
    agent_gateway.AgentGatewayService/RevokeDelegation \
    '{"delegation_id": "'"$ROOT_ID"'", "reason": "demo: cascade test"}')
ok "Revoked root ${ROOT_ID}"
show "$(echo "$REVOKE" | jq -c .)"

step "Step 8: Re-attempt the same read_file with the child token — expect DENY now (cascade)"
CASCADE=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$CHILD_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "read",
      "action_tier": 1,
      "tool_name": "read_file",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_denied "child after parent revoke (cascade)" "$CASCADE"

section "Chain demo complete"
echo -e "${BOLD}${GREEN}✓ Depth-2 chain minted, scope narrowing enforced, cascade revocation verified${NC}"
