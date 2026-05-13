#!/usr/bin/env bash
# Demo: Claude Code agent runs through the full delegation lifecycle.
#
# Identity: claude-code-agent (uuid 1111...)
# Provider: anthropic, trust_tier: CERTIFIED (2)
# Scope:    [read_file, search, list_documents, web_fetch] / actions [REASONING, READ_ONLY]

set -euo pipefail
. /demo/flow-lib.sh

AGENT_ID="11111111-1111-1111-1111-111111111111"
AGENT_LABEL="claude-code-agent"

section "${AGENT_LABEL}: end-to-end delegation demo"
note "gateway: ${GATEWAY_ADDR}  keycloak: ${KEYCLOAK_URL}"

# ─── 1. User authenticates with Keycloak ─────────────────────────────────────
step "Step 1: User '${DEMO_USER}' authenticates with Keycloak (password grant)"
USER_TOKEN=$(get_user_token)
ok "Got OIDC access token ($(echo -n "$USER_TOKEN" | wc -c) bytes)"
note "claims: $(jwt_payload "$USER_TOKEN" | jq -c '{sub, preferred_username, classification, role}')"

# ─── 2. Mint a delegation ─────────────────────────────────────────────────────
step "Step 2: Mint a delegation for ${AGENT_LABEL}"
note "scope: read_file + search + list_documents, tier ≤ READ_ONLY, classification cap CONFIDENTIAL"
DELEGATION=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/CreateDelegation \
    '{
      "agent_id": "'"$AGENT_ID"'",
      "approved_tools": ["read_file", "search", "list_documents"],
      "approved_actions": [0, 1],
      "max_action_tier": 1,
      "classification_caps": {"nato": "CONFIDENTIAL"},
      "purpose": "Research session via Claude Code CLI",
      "ttl_seconds": 900,
      "conversation_id": "demo-claude-code-001"
    }')

if echo "$DELEGATION" | jq -e '.grpc_error' >/dev/null 2>&1; then
    fail "CreateDelegation failed: $(echo "$DELEGATION" | jq -r .grpc_error)"
    exit 1
fi

DELEGATION_TOKEN=$(echo "$DELEGATION" | jq -r '.delegationToken')
DELEGATION_ID=$(echo "$DELEGATION" | jq -r '.delegationId')
ok "Delegation minted: ${DELEGATION_ID}"
note "JWT claims:"
show "$(jwt_payload "$DELEGATION_TOKEN" | jq '{delegation_id, agent_id, user_id, approved_tools, max_action_tier, classification_caps, depth, exp}')"

# ─── 3. Execute an authorized action ──────────────────────────────────────────
step "Step 3: ExecuteAction — tool=read_file, tier=READ_ONLY (in scope)"
ALLOWED=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$DELEGATION_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "read",
      "action_tier": 1,
      "tool_name": "read_file",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_authorized "read_file @ CONFIDENTIAL" "$ALLOWED"

# ─── 4. Execute an out-of-scope action ────────────────────────────────────────
step "Step 4: ExecuteAction — tool=write_file (NOT in approved_tools)"
DENIED_TOOL=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$DELEGATION_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "write",
      "action_tier": 2,
      "tool_name": "write_file",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_denied "write_file (tool not delegated)" "$DENIED_TOOL"

# ─── 5. Execute an action that exceeds the max tier ──────────────────────────
step "Step 5: ExecuteAction — tool=read_file but action_tier=4 (exceeds max_action_tier=1)"
DENIED_TIER=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$DELEGATION_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "delete",
      "action_tier": 4,
      "tool_name": "read_file",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_denied "read_file @ tier=4 (DESTRUCTIVE, exceeds cap of READ_ONLY)" "$DENIED_TIER"

# ─── 6. Inspect the delegation chain ──────────────────────────────────────────
step "Step 6: GetDelegationChain — confirm depth=1 (root only)"
CHAIN=$(grpc_call \
    agent_gateway.AgentGatewayService/GetDelegationChain \
    '{"delegation_id": "'"$DELEGATION_ID"'"}')
DEPTH=$(echo "$CHAIN" | jq -r '.totalDepth')
ok "chain total_depth = ${DEPTH}"
show "$(echo "$CHAIN" | jq '{rootDelegationId, userId, totalDepth, chain: [.chain[]? | {agentName, trustTier}]}')"

section "${AGENT_LABEL}: demo complete"
echo -e "${BOLD}${GREEN}✓ Delegation minted, scope enforced (allow + 2 denies), chain inspected${NC}"
