#!/usr/bin/env bash
# Inspect the live state of the agent-gateway demo: agents, delegations,
# recent gateway decisions, and Prometheus counters.
#
# Authoritative sources used:
#   - postgres.stratium_pap.agents       (seed + registered agents)
#   - postgres.stratium_pap.delegations  (every CreateDelegation row)
#   - postgres.stratium_pap.audit_logs   (eval-1.0.8+: every gateway decision)
#   - stratium-agent-gateway docker logs (human-readable one-liners)
#
# Prometheus stratium_agent_* counters are emitted by the gateway code
# (metrics.go) but observability is feature-flagged off in the eval-1.0.x demo
# build. Rebuild with BUILD_FEATURES=agent-auth,metrics to surface them.

set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

section() { echo; echo -e "${BOLD}${CYAN}━━━ $* ━━━${NC}"; echo; }
step()    { echo -e "${YELLOW}▶${NC} $*"; }
note()    { echo -e "  ${DIM}$*${NC}"; }

# ─── Agents ──────────────────────────────────────────────────────────────────
section "Registered agents"
docker exec stratium-postgres psql -U stratium -d stratium_pap \
    -c "SELECT id, name, provider, trust_tier AS tier, cert_status, enabled FROM agents ORDER BY created_at;" \
    2>/dev/null

# ─── Recent delegations ──────────────────────────────────────────────────────
section "Recent delegations (last 10)"
docker exec stratium-postgres psql -U stratium -d stratium_pap \
    -c "SELECT d.id, a.name AS agent, d.depth, d.max_action_tier AS max_tier, d.revoked,
           to_char(d.created_at, 'HH24:MI:SS')         AS created,
           to_char(d.expires_at, 'HH24:MI:SS')         AS expires,
           jsonb_array_length(d.approved_tools)        AS n_tools,
           coalesce(d.purpose, '')                     AS purpose
        FROM delegations d JOIN agents a ON a.id = d.agent_id
        ORDER BY d.created_at DESC LIMIT 10;" 2>/dev/null \
    || note "(no delegations yet — run a flow first)"

# ─── audit_logs ──────────────────────────────────────────────────────────────
section "Audit log (last 15 agent-authorization events)"
if [ -n "${VERBOSE:-}" ]; then
    # Full row including changes/result JSONB. Wrapped output is OK in verbose.
    docker exec stratium-postgres psql -U stratium -d stratium_pap \
        -c "\\x on" \
        -c "SELECT timestamp, entity_type, action, actor,
                   agent_id, delegation_id, tool_name, action_tier,
                   agent_decision, delegation_decision, denied_at_depth, denied_principal,
                   chain_depth, chain_agent_ids,
                   changes, result
            FROM audit_logs
            WHERE agent_id IS NOT NULL OR delegation_id IS NOT NULL OR entity_type IN ('agent','delegation')
            ORDER BY timestamp DESC LIMIT 15;" 2>/dev/null \
        || note "(no audit rows yet — agent-gateway audit writes need eval-1.0.8+)"
else
    docker exec stratium-postgres psql -U stratium -d stratium_pap \
        -c "SELECT to_char(timestamp, 'HH24:MI:SS') AS time,
                  entity_type AS entity,
                  action,
                  substring(actor, 1, 8) AS actor,
                  coalesce(tool_name, '') AS tool,
                  coalesce(action_tier::text, '') AS tier,
                  coalesce(agent_decision, '') AS agent_dec,
                  coalesce(delegation_decision, '') AS deleg_dec,
                  coalesce(denied_at_depth::text, '') AS denied_depth
            FROM audit_logs
            WHERE agent_id IS NOT NULL OR delegation_id IS NOT NULL OR entity_type IN ('agent','delegation')
            ORDER BY timestamp DESC LIMIT 15;" 2>/dev/null \
        || note "(no audit rows yet — agent-gateway audit writes need eval-1.0.8+)"
fi

# ─── Gateway decision log ────────────────────────────────────────────────────
section "Gateway log (last 15 human-readable events)"
docker logs stratium-agent-gateway 2>&1 \
    | grep -E "Action authorized|Created delegation|Revoked|Suspended|denied at depth" \
    | tail -15 \
    || note "(no gateway events yet)"

# ─── Aggregate decision summary ──────────────────────────────────────────────
section "Decision summary (parsed from gateway log)"
allow=$(docker logs stratium-agent-gateway 2>&1 | grep -c "Action authorized" || true)
deny=$(docker logs stratium-agent-gateway 2>&1 | grep -c "denied at depth" || true)
created=$(docker logs stratium-agent-gateway 2>&1 | grep -c "Created delegation" || true)
echo "  Delegations created : $created"
echo "  Actions authorized  : $allow"
echo "  Actions denied      : $deny"

section "Done"
echo -e "${DIM}Run a flow (make demo-flow-claude / codex / chain / admin), then re-run this to see the deltas.${NC}"
