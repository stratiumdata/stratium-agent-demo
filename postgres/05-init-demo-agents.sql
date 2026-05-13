-- Demo seed: register two pre-built agent identities so the demo flow scripts
-- can mint delegations without first calling the admin-gated RegisterAgent RPC.
--
-- Fixed UUIDs:
--   claude-code-agent : 11111111-1111-1111-1111-111111111111
--   codex-agent       : 22222222-2222-2222-2222-222222222222
--
-- Both are CERTIFIED (trust_tier=2) so they can act on delegated calls
-- without further admin attestation in the demo.

\c stratium_pap

INSERT INTO agents (
    id, name, description, provider, model_id,
    trust_tier, allowed_tools, allowed_actions,
    tenant_id, cert_status, client_id, client_secret,
    metadata, enabled, created_by
) VALUES
(
    '11111111-1111-1111-1111-111111111111',
    'claude-code-agent',
    'Anthropic Claude Code CLI acting as a delegated research/code assistant',
    'anthropic',
    'claude-sonnet-4-6',
    2,
    '["read_file", "search", "list_documents", "web_fetch"]'::jsonb,
    '[0, 1]'::jsonb,
    'demo-tenant',
    'CERTIFIED',
    'agent_claude_code_demo',
    decode('64656d6f2d7365637265742d6e6f742d666f722d70726f64', 'hex'),  -- "demo-secret-not-for-prod"
    '{"purpose": "demo", "container": "stratium-agent-claude-code"}'::jsonb,
    true,
    'demo-bootstrap'
),
(
    '22222222-2222-2222-2222-222222222222',
    'codex-agent',
    'OpenAI Codex CLI acting as a delegated code-generation/execution agent',
    'openai',
    'gpt-5-codex',
    2,
    '["read_file", "write_file", "execute_code", "search"]'::jsonb,
    '[0, 1, 2]'::jsonb,
    'demo-tenant',
    'CERTIFIED',
    'agent_codex_demo',
    decode('64656d6f2d7365637265742d6e6f742d666f722d70726f64', 'hex'),  -- "demo-secret-not-for-prod"
    '{"purpose": "demo", "container": "stratium-agent-codex"}'::jsonb,
    true,
    'demo-bootstrap'
)
ON CONFLICT (id) DO NOTHING;

-- Sanity check (visible in postgres logs)
\echo 'Seeded demo agents:'
SELECT id, name, provider, trust_tier, cert_status, enabled
  FROM agents
  WHERE id IN ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
