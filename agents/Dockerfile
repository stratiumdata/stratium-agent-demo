# Generic agent container image.
# Build with --build-arg AGENT_PACKAGE and --build-arg AGENT_NAME for each agent.
FROM node:20-slim

ARG AGENT_PACKAGE
ARG AGENT_NAME
ARG GRPCURL_VERSION=1.9.1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates jq tar \
 && rm -rf /var/lib/apt/lists/*

# Install grpcurl (architecture-aware)
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) grpcurl_arch=x86_64 ;; \
        aarch64) grpcurl_arch=arm64 ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${grpcurl_arch}.tar.gz" \
        | tar -xz -C /usr/local/bin grpcurl

# Install the agent CLI (claude-code or codex)
RUN npm install -g "${AGENT_PACKAGE}"

# Stratium MCP server — wraps the agent-gateway as MCP tools for the CLI to use.
COPY mcp/package.json mcp/server.js /opt/stratium-mcp/
RUN cd /opt/stratium-mcp && npm install --omit=dev --no-audit --no-fund \
 && chmod +x /opt/stratium-mcp/server.js

# Demo flow scripts
COPY agents/common/flow-lib.sh /demo/flow-lib.sh
COPY agents/common/chain-flow.sh /demo/chain-flow.sh
COPY agents/common/admin-flow.sh /demo/admin-flow.sh
COPY agents/common/mcp-flow.sh /demo/mcp-flow.sh
COPY agents/${AGENT_NAME}/flow.sh /demo/flow.sh
RUN chmod +x /demo/flow.sh /demo/chain-flow.sh /demo/admin-flow.sh /demo/mcp-flow.sh /demo/flow-lib.sh

# Pre-register the Stratium MCP server with each CLI. Claude Code reads
# /root/.claude.json on startup; Codex reads /root/.codex/config.toml. We
# write both so the same image template works for either agent.
RUN mkdir -p /root/.codex && \
    printf '%s\n' \
        '{' \
        '  "mcpServers": {' \
        '    "stratium-agent-gateway": {' \
        '      "command": "node",' \
        '      "args": ["/opt/stratium-mcp/server.js"]' \
        '    }' \
        '  }' \
        '}' > /root/.claude.json && \
    printf '%s\n' \
        '[mcp_servers.stratium-agent-gateway]' \
        'command = "node"' \
        'args    = ["/opt/stratium-mcp/server.js"]' > /root/.codex/config.toml

LABEL stratium.agent.name="${AGENT_NAME}"
LABEL stratium.agent.package="${AGENT_PACKAGE}"

# Keep the container alive so `docker exec` works for the demo
CMD ["sleep", "infinity"]
