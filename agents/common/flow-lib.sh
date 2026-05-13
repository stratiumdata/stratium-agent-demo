#!/usr/bin/env bash
# Shared helpers for agent delegation demo flows.
# Sourced by agents/claude-code/flow.sh, agents/codex/flow.sh, and the chain demo.

set -euo pipefail

# ─── Configuration (override via env) ─────────────────────────────────────────
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-stratium}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-stratium-cli-client}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-3gvfZGuzXB3E3IQxrJUD3zleb1kNrZc8}"
DEMO_USER="${DEMO_USER:-user}"
DEMO_PASS="${DEMO_PASS:-password123}"
GATEWAY_ADDR="${GATEWAY_ADDR:-agent-gateway:50054}"

# ─── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

section() {
    echo
    echo -e "${BOLD}${CYAN}━━━ $* ━━━${NC}"
    echo
}

step()    { echo -e "${YELLOW}▶${NC} $*"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
note()    { echo -e "  ${DIM}$*${NC}"; }
show()    { echo -e "${DIM}$*${NC}"; }

# Verbose logging: prints only when VERBOSE=1 (or non-empty). Writes to stderr
# so it doesn't pollute the stdout-captured values from functions like
# get_user_token / grpc_call that callers consume via $(...) substitution.
vlog() { [ -n "${VERBOSE:-}" ] && echo -e "    ${DIM}[v] $*${NC}" >&2; return 0; }

# Pretty-print JSON for verbose mode. Falls back to raw if jq can't parse.
# Also writes to stderr (see vlog rationale).
vjson() {
    if [ -z "${VERBOSE:-}" ]; then return 0; fi
    local label="$1" body="$2"
    echo -e "    ${DIM}[v] $label:${NC}" >&2
    if echo "$body" | jq . >/dev/null 2>&1; then
        echo "$body" | jq . | sed 's/^/        /' >&2
    else
        echo "$body" | sed 's/^/        /' >&2
    fi
}

# Redact a header value for display. Bearer tokens and passwords are summarized
# as length only (e.g. "Bearer <1246 bytes>"). Everything else passes through.
redact_header() {
    local h="$1"
    case "$h" in
        *[Aa]uthorization:*[Bb]earer*)
            local v="${h#*Bearer }"
            local plen="${#v}"
            echo "${h%%Bearer*}Bearer <${plen} bytes>"
            ;;
        *[Pp]assword*=*)
            echo "${h%%=*}=<redacted>"
            ;;
        *)
            echo "$h"
            ;;
    esac
}

# Get an OIDC access token for the demo user via Keycloak password grant.
# Echoes the access token to stdout. Caller extracts the sub claim themselves
# via: USER_SUB=$(jwt_payload "$USER_TOKEN" | jq -r '.sub')
#
# Why we also need the sub: the agent-gateway's extractUserID currently doesn't
# decode the JWT — it returns the raw "Bearer ..." header as user_id, which
# overflows delegations.user_id VARCHAR(255). Sending x-user-id explicitly
# (alongside the Bearer header) lets the gateway use the real sub claim while
# the user still authenticates honestly through Keycloak.
get_user_token() {
    local url="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
    vlog "→ Keycloak password grant"
    vlog "    POST ${url}"
    vlog "    body: grant_type=password client_id=${KEYCLOAK_CLIENT_ID} username=${DEMO_USER} password=<redacted>"

    local body
    body=$(curl -sf -X POST "$url" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "grant_type=password&client_id=${KEYCLOAK_CLIENT_ID}&client_secret=${KEYCLOAK_CLIENT_SECRET}&username=${DEMO_USER}&password=${DEMO_PASS}") || {
        fail "Keycloak password grant failed for user '${DEMO_USER}'"
        return 1
    }
    local tok
    tok=$(echo "$body" | jq -r '.access_token')

    if [ -n "${VERBOSE:-}" ]; then
        vlog "← Keycloak issued access_token (${#tok} bytes, expires in $(echo "$body" | jq -r '.expires_in')s)"
        vjson "decoded JWT payload (sub claim is what we send to gateway as user_id)" \
              "$(jwt_payload "$tok" | jq '{sub, preferred_username, email, classification, role, exp, iss}')"
    fi
    echo "$tok"
}

# Decode a JWT payload (no signature verification, demo only).
# Usage: jwt_payload <token>
jwt_payload() {
    local jwt="$1"
    echo "$jwt" | cut -d. -f2 | tr '_-' '/+' | \
        awk '{l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print}' | \
        base64 -d 2>/dev/null
}

# Wrapper around grpcurl that always emits JSON. On gRPC error, emits
# {"grpc_error": "...", "grpc_code": "..."} so jq can keep working.
# Usage: grpc_call [-H "name: value"]... <method> <json_payload>
grpc_call() {
    local -a hdrs=()
    while [[ "${1:-}" == -H ]]; do
        hdrs+=("$1" "$2"); shift 2
    done
    local method="$1" data="${2:-}"

    if [ -n "${VERBOSE:-}" ]; then
        vlog "→ gRPC ${GATEWAY_ADDR}/${method}"
        local i=0
        while [ $i -lt ${#hdrs[@]} ]; do
            # hdrs alternates -H "name: value" -H "name: value" ...
            if [ "${hdrs[$i]}" = "-H" ]; then
                vlog "    header: $(redact_header "${hdrs[$((i+1))]}")"
            fi
            i=$((i+2))
        done
        [ -n "$data" ] && vjson "request payload" "$data"
    fi

    local started_at; started_at=$(date +%s%N 2>/dev/null || echo 0)
    local raw
    if [ -n "$data" ]; then
        raw=$(grpcurl -plaintext ${hdrs[@]+"${hdrs[@]}"} -d "$data" "$GATEWAY_ADDR" "$method" 2>&1) || true
    else
        raw=$(grpcurl -plaintext ${hdrs[@]+"${hdrs[@]}"} "$GATEWAY_ADDR" "$method" 2>&1) || true
    fi
    local ended_at; ended_at=$(date +%s%N 2>/dev/null || echo 0)
    local elapsed_ms=$(( (ended_at - started_at) / 1000000 ))

    local result
    if echo "$raw" | grep -q '^ERROR:'; then
        local code msg
        code=$(echo "$raw" | grep -E '^\s*Code:' | head -1 | awk '{print $2}')
        msg=$(echo "$raw" | grep -E '^\s*Message:' | head -1 | sed 's/^[[:space:]]*Message:[[:space:]]*//')
        result=$(printf '{"grpc_error": %s, "grpc_code": %s}' \
            "$(jq -Rn --arg m "$msg" '$m')" \
            "$(jq -Rn --arg c "$code" '$c')")
    else
        result="$raw"
    fi

    if [ -n "${VERBOSE:-}" ]; then
        vlog "← gRPC response (${elapsed_ms}ms)"
        vjson "response body" "$result"
    fi

    echo "$result"
}

# Assert that a JSON response indicates `authorized: true`.
# Proto3 omits zero-value bools, so absent counts as false.
assert_authorized() {
    local label="$1" resp="$2"
    local v; v=$(echo "$resp" | jq -r '.authorized // "false"')
    if [ "$v" = "true" ]; then
        ok "$label — ALLOWED"
    else
        fail "$label — expected ALLOW, got: $(echo "$resp" | jq -c .)"
    fi
}

# Assert that a JSON response indicates denial (authorized=false OR grpc error).
assert_denied() {
    local label="$1" resp="$2"
    local v; v=$(echo "$resp" | jq -r '.authorized // "false"')
    if [ "$v" = "false" ] || echo "$resp" | jq -e '.grpc_error' >/dev/null 2>&1; then
        ok "$label — DENIED (as expected)"
        local reason
        reason=$(echo "$resp" | jq -r '.error // .grpc_error // .decision.reason // empty')
        [ -n "$reason" ] && note "reason: $reason"
    else
        fail "$label — expected DENY, got: $(echo "$resp" | jq -c .)"
    fi
}
