-- Stratium Agent Authorization Schema
-- This migration adds tables for AI agent registration, delegation tokens,
-- and agent-specific audit logging. Only applied when agent-auth feature is enabled.

-- Connect to the stratium_pap database
\c stratium_pap

-- ============================================================================
-- AGENTS TABLE
-- Stores registered AI agent identities and their permissions.
-- ============================================================================

CREATE TABLE IF NOT EXISTS agents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    provider        VARCHAR(100) NOT NULL,
    model_id        VARCHAR(255),
    trust_tier      SMALLINT NOT NULL DEFAULT 0
                    CHECK (trust_tier BETWEEN 0 AND 3),
    allowed_tools   JSONB NOT NULL DEFAULT '[]',
    allowed_actions JSONB NOT NULL DEFAULT '[0, 1]',
    tenant_id       VARCHAR(255) NOT NULL,
    cert_status     VARCHAR(50) NOT NULL DEFAULT 'PENDING'
                    CHECK (cert_status IN ('PENDING', 'CERTIFIED', 'SUSPENDED', 'REVOKED')),
    client_id       VARCHAR(255) UNIQUE NOT NULL,
    client_secret   BYTEA NOT NULL,
    metadata        JSONB DEFAULT '{}',
    enabled         BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      VARCHAR(255) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agents_tenant ON agents(tenant_id);
CREATE INDEX IF NOT EXISTS idx_agents_trust_tier ON agents(trust_tier);
CREATE INDEX IF NOT EXISTS idx_agents_client_id ON agents(client_id);
CREATE INDEX IF NOT EXISTS idx_agents_enabled ON agents(enabled) WHERE enabled = true;

-- Auto-update updated_at trigger
CREATE TRIGGER update_agents_updated_at
    BEFORE UPDATE ON agents
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- DELEGATIONS TABLE
-- Stores active and historical delegation tokens with chain metadata.
-- Supports N-level subagent delegation chains via linked parent references.
-- ============================================================================

CREATE TABLE IF NOT EXISTS delegations (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              VARCHAR(255) NOT NULL,
    agent_id             UUID NOT NULL REFERENCES agents(id),
    tenant_id            VARCHAR(255) NOT NULL,
    conversation_id      VARCHAR(255),
    approved_tools       JSONB NOT NULL DEFAULT '[]',
    approved_actions     JSONB NOT NULL DEFAULT '[]',
    max_action_tier      SMALLINT NOT NULL DEFAULT 1
                         CHECK (max_action_tier BETWEEN 0 AND 4),
    classification_caps  JSONB NOT NULL DEFAULT '{}',
    resource_constraints JSONB NOT NULL DEFAULT '{}',
    purpose              TEXT,
    expires_at           TIMESTAMPTZ NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked              BOOLEAN NOT NULL DEFAULT false,
    revoked_at           TIMESTAMPTZ,

    -- Delegation chain fields
    parent_delegation_id UUID REFERENCES delegations(id),
    root_delegation_id   UUID NOT NULL,
    depth                SMALLINT NOT NULL DEFAULT 0
                         CHECK (depth >= 0),
    chain_agent_ids      JSONB NOT NULL DEFAULT '[]'
);

-- Performance indexes for delegation lookups
CREATE INDEX IF NOT EXISTS idx_delegations_user_agent ON delegations(user_id, agent_id);
CREATE INDEX IF NOT EXISTS idx_delegations_expires ON delegations(expires_at) WHERE revoked = false;
CREATE INDEX IF NOT EXISTS idx_delegations_parent ON delegations(parent_delegation_id) WHERE parent_delegation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_delegations_root ON delegations(root_delegation_id);
CREATE INDEX IF NOT EXISTS idx_delegations_depth ON delegations(depth);
CREATE INDEX IF NOT EXISTS idx_delegations_active ON delegations(revoked, expires_at) WHERE revoked = false;
CREATE INDEX IF NOT EXISTS idx_delegations_agent ON delegations(agent_id);

-- ============================================================================
-- AUDIT LOG EXTENSIONS
-- Add agent-specific columns to the existing audit_logs table.
-- ============================================================================

-- Extend entity_type check to include 'agent' and 'delegation'
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_entity_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_entity_type_check
    CHECK (entity_type IN ('policy', 'entitlement', 'agent', 'delegation'));

-- Extend action check to include agent-authorization actions
-- (eval-1.0.8+: CreateDelegation writes 'create', ExecuteAction writes
--  'authorize', RevokeDelegation writes 'revoke', SuspendAgent writes 'suspend').
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
    CHECK (action IN ('create', 'update', 'delete', 'evaluate', 'test',
                      'authorize', 'revoke', 'suspend'));

-- Add agent authorization audit columns
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS agent_id UUID;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS delegation_id UUID;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS agent_trust_tier SMALLINT;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS tool_name VARCHAR(255);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS action_tier SMALLINT;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS execution_mode VARCHAR(20);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS conversation_id VARCHAR(255);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS user_decision VARCHAR(20);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS agent_decision VARCHAR(20);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS delegation_decision VARCHAR(20);
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS chain_depth SMALLINT;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS chain_agent_ids JSONB;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS root_delegation_id UUID;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS denied_at_depth SMALLINT;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS denied_principal VARCHAR(255);

-- Indexes for agent audit queries
CREATE INDEX IF NOT EXISTS idx_audit_logs_agent ON audit_logs(agent_id) WHERE agent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_delegation ON audit_logs(delegation_id) WHERE delegation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_root_delegation ON audit_logs(root_delegation_id) WHERE root_delegation_id IS NOT NULL;

-- ============================================================================
-- OPA POLICY FOR AGENT AUTHORIZATION
-- Seed a compound authorization policy for agent double-hop evaluation.
-- ============================================================================

INSERT INTO policies (name, description, language, policy_content, effect, priority, created_by) VALUES
    ('agent-compound-authorization', 'Compound policy evaluating user + agent + delegation scope', 'opa',
     'package stratium.agent_auth

import future.keywords.if
import future.keywords.in

default allow := false

allow if {
    user_allowed
    agent_allowed
    delegation_allowed
}

user_allowed if {
    input.subject_attributes.clearance_level >= input.resource_attributes.classification_level
    input.action in user_permitted_actions
}

user_permitted_actions := actions if {
    actions := input.subject_attributes.allowed_actions
}

agent_allowed if {
    input.agent_attributes.trust_tier >= required_trust_tier(input.delegation_context.action_tier)
    input.delegation_context.tool_name in input.agent_attributes.allowed_tools
}

delegation_allowed if {
    input.delegation_context.execution_mode == "DELEGATED"
    classification_within_caps
}

classification_within_caps if {
    hierarchy := input.resource_attributes.hierarchy
    resource_level := input.resource_attributes.classification_level
    cap_level := input.delegation_context.classification_caps[hierarchy]
    resource_level <= cap_level
}

required_trust_tier(action_tier) := 0 if { action_tier <= 1 }
required_trust_tier(action_tier) := 1 if { action_tier == 2 }
required_trust_tier(action_tier) := 2 if { action_tier == 3 }
required_trust_tier(action_tier) := 3 if { action_tier == 4 }', 'allow', 200, 'system')
ON CONFLICT (name) DO NOTHING;

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE agents TO stratium;
GRANT ALL PRIVILEGES ON TABLE delegations TO stratium;
