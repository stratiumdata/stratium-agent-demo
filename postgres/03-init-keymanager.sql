-- Stratium Key Manager Database Schema
-- This schema supports encrypted key storage and management

-- Connect to the stratium_keymanager database
-- (Database is created by init-multiple-dbs.sh)
\c stratium_keymanager

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- KEY MANAGER TABLES
-- ============================================================================
-- Stores encrypted asymmetric key pairs for the Key Manager service
-- Private keys are encrypted using the admin key (KEK - Key Encryption Key)

-- Admin Keys Table
-- Stores the master admin key used to encrypt/decrypt private key material
CREATE TABLE IF NOT EXISTS admin_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    key_id VARCHAR(255) NOT NULL UNIQUE,
    encrypted_key_material BYTEA NOT NULL,
    encryption_algorithm VARCHAR(50) NOT NULL DEFAULT 'AES-256-GCM',
    key_version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    rotated_at TIMESTAMP WITH TIME ZONE,
    status VARCHAR(20) NOT NULL CHECK (status IN ('active', 'rotated', 'revoked')) DEFAULT 'active',
    metadata JSONB,
    CONSTRAINT admin_keys_unique_active UNIQUE NULLS NOT DISTINCT (key_id, status)
);

-- Key Pairs Table
-- Stores both public key metadata and encrypted private key material
CREATE TABLE IF NOT EXISTS key_pairs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    key_id VARCHAR(255) NOT NULL UNIQUE,
    key_type VARCHAR(50) NOT NULL CHECK (key_type IN ('RSA2048', 'RSA3072', 'RSA4096', 'ECC256', 'ECC384', 'ECC521', 'Kyber512', 'Kyber768', 'Kyber1024')),
    key_size INTEGER,
    provider_type VARCHAR(50) NOT NULL CHECK (provider_type IN ('software', 'hsm', 'smartcard')),

    -- Public key information (stored in plaintext)
    public_key_pem TEXT NOT NULL,
    public_key_der BYTEA,

    -- Private key information (encrypted with admin key)
    encrypted_private_key BYTEA NOT NULL,
    encryption_algorithm VARCHAR(50) NOT NULL DEFAULT 'AES-256-GCM',
    encryption_key_id VARCHAR(255) NOT NULL, -- References admin_keys.key_id
    nonce BYTEA, -- For AES-GCM

    -- Key lifecycle management
    status VARCHAR(20) NOT NULL CHECK (status IN ('active', 'inactive', 'expired', 'revoked', 'compromised')) DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    last_rotated TIMESTAMP WITH TIME ZONE,

    -- Usage tracking
    usage_count BIGINT DEFAULT 0,
    max_usage_count BIGINT,
    last_used_at TIMESTAMP WITH TIME ZONE,

    -- Metadata
    metadata JSONB,
    tags JSONB,

    CONSTRAINT fk_encryption_key FOREIGN KEY (encryption_key_id) REFERENCES admin_keys(key_id)
);

-- Client Keys Table (for storing public keys of subjects/clients)
CREATE TABLE IF NOT EXISTS client_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    subject_id VARCHAR(255) NOT NULL,
    key_id VARCHAR(255) NOT NULL UNIQUE,
    key_type VARCHAR(50) NOT NULL CHECK (key_type IN ('RSA2048', 'RSA3072', 'RSA4096', 'ECC256', 'ECC384', 'ECC521', 'Kyber512', 'Kyber768', 'Kyber1024')),

    -- Public key information
    public_key_pem TEXT NOT NULL,
    public_key_der BYTEA,

    -- Key integrity verification (HMAC-based tamper detection)
    key_integrity_hash VARCHAR(64),

    -- Lifecycle management
    status VARCHAR(20) NOT NULL CHECK (status IN ('active', 'inactive', 'expired', 'revoked')) DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,

    -- Metadata
    metadata JSONB,

    CONSTRAINT client_keys_subject_key UNIQUE (subject_id, key_id)
);

-- Key Audit Logs Table
-- Tracks all key operations for security and compliance
CREATE TABLE IF NOT EXISTS key_audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    key_id VARCHAR(255) NOT NULL,
    operation VARCHAR(50) NOT NULL CHECK (operation IN ('create', 'read', 'update', 'delete', 'encrypt', 'decrypt', 'sign', 'verify', 'rotate', 'revoke')),
    actor VARCHAR(255) NOT NULL,
    result VARCHAR(20) NOT NULL CHECK (result IN ('success', 'failure', 'denied')),
    error_message TEXT,
    ip_address VARCHAR(45),
    user_agent TEXT,
    metadata JSONB,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_admin_keys_status ON admin_keys(status);
CREATE INDEX IF NOT EXISTS idx_admin_keys_key_id ON admin_keys(key_id);

CREATE INDEX IF NOT EXISTS idx_key_pairs_key_id ON key_pairs(key_id);
CREATE INDEX IF NOT EXISTS idx_key_pairs_status ON key_pairs(status);
CREATE INDEX IF NOT EXISTS idx_key_pairs_provider_type ON key_pairs(provider_type);
CREATE INDEX IF NOT EXISTS idx_key_pairs_key_type ON key_pairs(key_type);
CREATE INDEX IF NOT EXISTS idx_key_pairs_expires_at ON key_pairs(expires_at);
CREATE INDEX IF NOT EXISTS idx_key_pairs_created_at ON key_pairs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_key_pairs_encryption_key_id ON key_pairs(encryption_key_id);

CREATE INDEX IF NOT EXISTS idx_client_keys_subject_id ON client_keys(subject_id);
CREATE INDEX IF NOT EXISTS idx_client_keys_key_id ON client_keys(key_id);
CREATE INDEX IF NOT EXISTS idx_client_keys_status ON client_keys(status);

CREATE INDEX IF NOT EXISTS idx_key_audit_logs_key_id ON key_audit_logs(key_id);
CREATE INDEX IF NOT EXISTS idx_key_audit_logs_operation ON key_audit_logs(operation);
CREATE INDEX IF NOT EXISTS idx_key_audit_logs_timestamp ON key_audit_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_key_audit_logs_actor ON key_audit_logs(actor);

-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-update updated_at for key_pairs
CREATE TRIGGER update_key_pairs_updated_at
    BEFORE UPDATE ON key_pairs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Grant permissions to stratium user
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO stratium;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO stratium;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO stratium;