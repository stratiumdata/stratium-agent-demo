#!/usr/bin/env bash
# Demo: agent admin lifecycle.
#
# Flow:
#   1. User authenticates with Keycloak
#   2. RegisterAgent — create a new ephemeral agent via gRPC (not SQL)
#   3. ListAgents — confirm it appears alongside the seeded agents
#   4. CreateDelegation — mint a delegation for the new agent
#   5. ExecuteAction — confirm it works (sanity check)
#   6. SuspendAgent — suspend the agent
#   7. Show RevokedDelegations count returned by SuspendAgent
#   8. ExecuteAction with the same token — confirm it now DENIES (cascade)
#
# The ephemeral agent's UUID is captured into TMP_AGENT_ID for the flow.
# The agent is NOT cleaned up afterwards so the audit trail remains inspectable.

set -euo pipefail
. /demo/flow-lib.sh

section "Agent admin lifecycle — Register, Delegate, Suspend, Verify"
note "gateway: ${GATEWAY_ADDR}  keycloak: ${KEYCLOAK_URL}"

# ─── 1. User authenticates ───────────────────────────────────────────────────
step "Step 1: User '${DEMO_USER}' authenticates with Keycloak"
USER_TOKEN=$(get_user_token)
ok "Got OIDC access token"

# ─── 2. RegisterAgent ────────────────────────────────────────────────────────
step "Step 2: RegisterAgent — create a new 'test-runner-agent' via gRPC"
REG=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/RegisterAgent \
    '{
      "name": "test-runner-agent",
      "description": "Ephemeral test agent registered via the admin demo flow",
      "provider": "demo",
      "model_identifier": "demo-model-v1",
      "trust_tier": 2,
      "allowed_tools": ["read_file", "list_documents"],
      "allowed_actions": [0, 1],
      "tenant_id": "demo-tenant",
      "metadata": {"created_by_demo": "true"}
    }')
if echo "$REG" | jq -e '.grpc_error' >/dev/null 2>&1; then
    fail "RegisterAgent failed: $(echo "$REG" | jq -r .grpc_error)"; exit 1
fi
TMP_AGENT_ID=$(echo "$REG" | jq -r '.agentId')
TMP_CLIENT_ID=$(echo "$REG" | jq -r '.clientId')
ok "Registered agent ${TMP_AGENT_ID}"
note "client_id: ${TMP_CLIENT_ID}"

# ─── 3. ListAgents ───────────────────────────────────────────────────────────
step "Step 3: ListAgents — confirm it's in the registry alongside seeded agents"
LIST=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/ListAgents \
    '{"tenant_id": "demo-tenant", "enabled_only": true, "page_size": 20}')
COUNT=$(echo "$LIST" | jq -r '.totalCount')
ok "ListAgents returned ${COUNT} agents in tenant demo-tenant"
show "$(echo "$LIST" | jq '[.agents[] | {name, provider, trustTier, certStatus}]')"

# ─── 4. CreateDelegation for the new agent ───────────────────────────────────
step "Step 4: Mint a delegation for test-runner-agent"
DEL=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/CreateDelegation \
    '{
      "agent_id": "'"$TMP_AGENT_ID"'",
      "approved_tools": ["read_file", "list_documents"],
      "approved_actions": [0, 1],
      "max_action_tier": 1,
      "classification_caps": {"nato": "CONFIDENTIAL"},
      "purpose": "Admin demo: short-lived runtime token for the test agent",
      "ttl_seconds": 600,
      "conversation_id": "demo-admin-001"
    }')
if echo "$DEL" | jq -e '.grpc_error' >/dev/null 2>&1; then
    fail "CreateDelegation failed: $(echo "$DEL" | jq -r .grpc_error)"; exit 1
fi
DEL_TOKEN=$(echo "$DEL" | jq -r '.delegationToken')
DEL_ID=$(echo "$DEL" | jq -r '.delegationId')
ok "Delegation minted: ${DEL_ID}"

# ─── 5. ExecuteAction (sanity check, expect ALLOW) ──────────────────────────
step "Step 5: ExecuteAction with the new agent — sanity-check authorization works"
OK_RESP=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$DEL_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "read",
      "action_tier": 1,
      "tool_name": "read_file",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_authorized "test-runner-agent read_file" "$OK_RESP"

# ─── 6. SuspendAgent ─────────────────────────────────────────────────────────
step "Step 6: SuspendAgent — revoke this agent and all its active delegations"
SUS=$(grpc_call -H "authorization: Bearer ${USER_TOKEN}" \
    agent_gateway.AgentGatewayService/SuspendAgent \
    '{"agent_id": "'"$TMP_AGENT_ID"'", "reason": "demo: suspending after lifecycle test"}')
if echo "$SUS" | jq -e '.grpc_error' >/dev/null 2>&1; then
    fail "SuspendAgent failed: $(echo "$SUS" | jq -r .grpc_error)"; exit 1
fi
REVOKED=$(echo "$SUS" | jq -r '.revokedDelegations // 0')
ok "Suspended agent ${TMP_AGENT_ID}; revoked ${REVOKED} active delegation(s) for it"

# ─── 7. ExecuteAction post-suspend (expect DENY) ─────────────────────────────
step "Step 7: ExecuteAction with the (now-revoked) delegation — expect DENY"
DENY_RESP=$(grpc_call \
    agent_gateway.AgentGatewayService/ExecuteAction \
    '{
      "delegation_token": "'"$DEL_TOKEN"'",
      "target_service": "platform",
      "method": "GetDecision",
      "action": "read",
      "action_tier": 1,
      "tool_name": "read_file",
      "resource_attributes": {"classification": "CONFIDENTIAL", "hierarchy": "nato"}
    }')
assert_denied "delegation revoked by SuspendAgent" "$DENY_RESP"

section "Admin demo complete"
echo -e "${BOLD}${GREEN}✓ Register → List → Delegate → Authorize → Suspend → Revoke verified${NC}"
note "The suspended agent remains in the registry (run \`make demo-inspect\` to see it). Re-running this flow registers another."
