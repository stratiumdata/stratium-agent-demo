#!/usr/bin/env node
/**
 * Stratium MCP server — exposes the agent-gateway as MCP tools.
 *
 * Transport: stdio (spawned by the host CLI as a child process).
 *
 * Tools exposed:
 *   - create_delegation : mint a delegation token for an agent
 *   - execute_action    : ask the gateway to authorize (and proxy) an action
 *   - revoke_delegation : revoke a delegation and cascade to children
 *
 * Auth: this server authenticates as the demo user (DEMO_USER/DEMO_PASS) on
 * each call by doing a Keycloak password grant. In a real deployment the
 * caller would supply their own token (e.g. via an HTTP header or sidecar
 * exchange).
 *
 * Transport choice rationale: stdio is the most broadly supported MCP
 * transport across CLIs. It also keeps deployment trivial (no extra
 * container, no port exposure) — the CLI spawns this script directly.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const KEYCLOAK_URL    = process.env.KEYCLOAK_URL    || "http://keycloak:8080";
const KEYCLOAK_REALM  = process.env.KEYCLOAK_REALM  || "stratium";
const KEYCLOAK_CLIENT = process.env.KEYCLOAK_CLIENT_ID     || "stratium-cli-client";
const KEYCLOAK_SECRET = process.env.KEYCLOAK_CLIENT_SECRET || "3gvfZGuzXB3E3IQxrJUD3zleb1kNrZc8";
const DEMO_USER       = process.env.DEMO_USER       || "user";
const DEMO_PASS       = process.env.DEMO_PASS       || "password123";
const GATEWAY_ADDR    = process.env.GATEWAY_ADDR    || "agent-gateway:50054";
const LOG_FILE        = process.env.MCP_LOG_FILE    || "/tmp/mcp-stratium.log";

// Log to stderr (so we don't corrupt stdio JSON-RPC framing) AND tee to a
// file so the flow scripts can surface what happened to the user even when
// the host CLI swallows the MCP server's stderr.
const log = (...args) => {
    const line = `[${new Date().toISOString()}] [stratium-mcp] ${args.map(a =>
        typeof a === "object" ? JSON.stringify(a) : String(a)
    ).join(" ")}`;
    console.error(line);
    try { appendFileSync(LOG_FILE, line + "\n"); } catch { /* best-effort */ }
};

/**
 * Get a fresh OIDC access token from Keycloak via password grant.
 * Returns { token, sub } where sub is the user's JWT subject claim.
 */
async function getUserToken() {
    const body = new URLSearchParams({
        grant_type:    "password",
        client_id:     KEYCLOAK_CLIENT,
        client_secret: KEYCLOAK_SECRET,
        username:      DEMO_USER,
        password:      DEMO_PASS,
    });
    const resp = await fetch(`${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
    });
    if (!resp.ok) {
        const detail = await resp.text();
        throw new Error(`Keycloak token request failed (${resp.status}): ${detail}`);
    }
    const data = await resp.json();
    return data.access_token;
}

/**
 * Call an agent-gateway gRPC method via grpcurl. Returns parsed JSON response.
 * On gRPC error throws an Error with the underlying gRPC code/message.
 */
function grpcCall(method, payload, headers = {}) {
    const args = ["-plaintext"];
    for (const [k, v] of Object.entries(headers)) {
        args.push("-H", `${k}: ${v}`);
    }
    args.push("-d", JSON.stringify(payload));
    args.push(GATEWAY_ADDR, method);

    let raw;
    try {
        raw = execFileSync("grpcurl", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
        // grpcurl writes the gRPC error to stderr and exits non-zero.
        const stderr = (e.stderr || "").toString();
        const match  = stderr.match(/Code:\s*(\S+)[\s\S]*?Message:\s*(.+)/);
        if (match) {
            throw new Error(`gRPC ${match[1]}: ${match[2].trim()}`);
        }
        throw new Error(`grpcurl failed: ${stderr || e.message}`);
    }
    return raw.trim() ? JSON.parse(raw) : {};
}

const server = new McpServer({
    name:    "stratium-agent-gateway",
    version: "1.0.0",
});

// ─── Tool: create_delegation ─────────────────────────────────────────────────
server.registerTool(
    "create_delegation",
    {
        title: "Mint a Stratium agent delegation token",
        description:
            "Create a scoped delegation JWT that authorizes an AI agent to act on behalf of the current user. " +
            "The returned delegation_token must be supplied to subsequent execute_action calls. " +
            "Scope is the intersection of what the user is allowed to do and what the agent is allowed to do. " +
            "Returns delegation_id and delegation_token.",
        inputSchema: {
            agent_id:            z.string().describe("UUID of the registered agent to delegate to"),
            approved_tools:      z.array(z.string()).describe("Tool names this delegation permits"),
            max_action_tier:     z.number().int().min(0).max(4).default(1).describe("Maximum action tier (0=reasoning, 1=read, 2=internal modify, 3=external comms, 4=destructive)"),
            classification_caps: z.record(z.string(), z.string()).optional().describe("Per-hierarchy classification cap, e.g. {nato: 'CONFIDENTIAL'}"),
            purpose:             z.string().describe("Human-readable purpose of this delegation"),
            ttl_seconds:         z.number().int().positive().max(3600).default(900).describe("Token TTL in seconds (max 1h)"),
        },
    },
    async (input) => {
        const token = await getUserToken();
        const payload = {
            agent_id:            input.agent_id,
            approved_tools:      input.approved_tools,
            approved_actions:    [0, 1, 2].slice(0, input.max_action_tier + 1),
            max_action_tier:     input.max_action_tier,
            classification_caps: input.classification_caps || {},
            purpose:             input.purpose,
            ttl_seconds:         input.ttl_seconds,
        };
        log("→ create_delegation", { agent_id: payload.agent_id, tools: payload.approved_tools, max_tier: payload.max_action_tier });
        try {
            const resp = grpcCall(
                "agent_gateway.AgentGatewayService/CreateDelegation",
                payload,
                { authorization: `Bearer ${token}` },
            );
            log("← create_delegation OK", { delegation_id: resp.delegationId, depth: resp.depth || 0 });
            return {
                content: [{
                    type: "text",
                    text: JSON.stringify({
                        delegation_id:    resp.delegationId,
                        delegation_token: resp.delegationToken,
                        depth:            resp.depth || 0,
                        root_delegation_id: resp.rootDelegationId,
                        expires_at:       resp.expiresAt,
                    }, null, 2),
                }],
            };
        } catch (e) {
            log("← create_delegation FAILED", { error: String(e.message || e) });
            throw e;
        }
    },
);

// ─── Tool: execute_action ────────────────────────────────────────────────────
server.registerTool(
    "execute_action",
    {
        title: "Ask the gateway to authorize an action under a delegation",
        description:
            "Submit an action (tool_name + action_tier + resource_attributes) for authorization against the supplied delegation token. " +
            "The gateway evaluates the entire delegation chain. Returns { authorized: true/false, reason? }.",
        inputSchema: {
            delegation_token:     z.string().describe("Delegation JWT returned from create_delegation"),
            tool_name:            z.string().describe("Tool being invoked (must be in delegation.approved_tools)"),
            action:               z.string().default("read").describe("Action verb: read|write|execute|delete|send"),
            action_tier:          z.number().int().min(0).max(4).default(1),
            resource_attributes:  z.record(z.string(), z.string()).optional().describe("e.g. {classification: 'CONFIDENTIAL', hierarchy: 'nato'}"),
        },
    },
    async (input) => {
        const payload = {
            delegation_token:    input.delegation_token,
            target_service:      "platform",
            method:              "GetDecision",
            action:              input.action,
            action_tier:         input.action_tier,
            tool_name:           input.tool_name,
            resource_attributes: input.resource_attributes || {},
        };
        log("→ execute_action", { tool: payload.tool_name, tier: payload.action_tier, resource: payload.resource_attributes });
        try {
            const resp = grpcCall("agent_gateway.AgentGatewayService/ExecuteAction", payload);
            const authorized = resp.authorized === true;
            log(authorized ? "← execute_action ALLOW" : "← execute_action DENY", {
                tool: payload.tool_name,
                denied_at_depth: resp.decision?.deniedAtDepth ?? null,
                denied_by: resp.decision?.deniedPrincipal || null,
                error: resp.error || null,
            });
            return {
                content: [{
                    type: "text",
                    text: JSON.stringify({
                        authorized,
                        error:           resp.error || null,
                        denied_at_depth: resp.decision?.deniedAtDepth ?? null,
                        denied_by:       resp.decision?.deniedPrincipal || null,
                    }, null, 2),
                }],
            };
        } catch (e) {
            log("← execute_action FAILED", { error: String(e.message || e) });
            throw e;
        }
    },
);

// ─── Tool: revoke_delegation ─────────────────────────────────────────────────
server.registerTool(
    "revoke_delegation",
    {
        title: "Revoke a delegation (cascades to children)",
        description: "Revoke a delegation by ID. Any child delegations in the chain are cascade-revoked.",
        inputSchema: {
            delegation_id: z.string().describe("UUID of the delegation to revoke"),
            reason:        z.string().default("revoked via MCP").describe("Audit-trail reason"),
        },
    },
    async (input) => {
        const token = await getUserToken();
        log("→ revoke_delegation", { delegation_id: input.delegation_id, reason: input.reason });
        try {
            const resp = grpcCall(
                "agent_gateway.AgentGatewayService/RevokeDelegation",
                { delegation_id: input.delegation_id, reason: input.reason },
                { authorization: `Bearer ${token}` },
            );
            log("← revoke_delegation OK", { revoked_count: resp.revokedCount || 0 });
            return {
                content: [{
                    type: "text",
                    text: JSON.stringify({
                        success:        resp.success === true,
                        revoked_count:  resp.revokedCount || 0,
                        revoked_ids:    resp.revokedDelegationIds || [],
                    }, null, 2),
                }],
            };
        } catch (e) {
            log("← revoke_delegation FAILED", { error: String(e.message || e) });
            throw e;
        }
    },
);

const transport = new StdioServerTransport();
await server.connect(transport);
log(`ready (gateway=${GATEWAY_ADDR}, user=${DEMO_USER})`);
