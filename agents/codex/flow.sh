#!/usr/bin/env bash
# Demo: Codex agent runs through the full delegation lifecycle.
#
# Identity: codex-agent (uuid 2222...)
# Provider: openai, trust_tier: CERTIFIED (2)
# Scope:    [read_file, write_file, execute_code, search] / actions [REASONING, READ_ONLY, INTERNAL_MODIFY]

set -euo pipefail
. /demo/flow-lib.sh

AGENT_ID="22222222-2222-2222-2222-222222222222"
AGENT_LABEL="codex-agent"

section "${AGENT_LABEL}: end-to-end delegation demo"
note "gateway: ${GATEWAY_ADDR}  keycloak: ${KEYCLOAK_URL}"

# ─── 1. User authenticates with Keycloak ─────────────────────────────────────
step "Step 1: User '${DEMO_USER}' authenticates with Keycloak (password grant)"
USER_TOKEN=$(get_user_token)
ok "Got OIDC access token ($(echo -n "$USER_TOKEN" | wc -c) bytes)"
note "claims: $(jwt_payload "$USER_TOKEN" | jq -c '{sub, preferred_username, classification, role}')"

# ─── 2. Mint a delegation ─────────────────────────────────────────────────────
step "Step 2: Mint a delegation for ${AGENT_LABEL}"
note "scope: read_file + write_file + execute_code + search, tier ≤ INTERNAL_MODIFY, classification cap CONFIDENTIAL"
DELEGATION=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/CreateDelegation \
    '{
      "agent_id": "'"$AGENT_ID"'",
      "approved_tools": ["read_file", "write_file", "execute_code", "search"],
      "approved_actions": [0, 1, 2],
      "max_action_tier": 2,
      "classification_caps": {"nato": "CONFIDENTIAL"},
      "purpose": "Code-generation and execution session via Codex CLI",
      "ttl_seconds": 900,
      "conversation_id": "demo-codex-001"
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

# ─── 3. Execute an authorized write ──────────────────────────────────────────
step "Step 3: ExecuteAction — tool=write_file, tier=INTERNAL_MODIFY (in scope)"
ALLOWED=$(grpc_call \
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
assert_authorized "write_file @ tier=2 (INTERNAL_MODIFY)" "$ALLOWED"

# ─── 4. Execute an action that exceeds the classification cap ────────────────
step "Step 4: ExecuteAction — read SECRET file (exceeds CONFIDENTIAL cap)"
DENIED_CLASS=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$DELEGATION_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "read",
      "action_tier": 1,
      "tool_name": "read_file",
      "resource_attributes": {"classification": "SECRET", "hierarchy": "nato"}
    }')
assert_denied "read_file @ SECRET (above CONFIDENTIAL cap)" "$DENIED_CLASS"

# ─── 5. Execute a destructive action that exceeds the tier ───────────────────
step "Step 5: ExecuteAction — execute_code @ tier=4 (DESTRUCTIVE, exceeds max=2)"
DENIED_TIER=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$DELEGATION_TOKEN"'",
      "target_service": "platform",
      "method": "Execute",
      "action": "execute",
      "action_tier": 4,
      "tool_name": "execute_code",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_denied "execute_code @ tier=4 (DESTRUCTIVE)" "$DENIED_TIER"

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
