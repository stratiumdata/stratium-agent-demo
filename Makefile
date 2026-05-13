# Stratium Agent Authorization (Demo)

.PHONY: docker-build docker-up docker-down demo-flow-claude demo-flow-codex demo-flow-all demo-flow-chain demo-flow-admin demo-flow-mcp-claude demo-flow-mcp-codex demo-inspect

# Verbose-mode toggle. Run any demo target with V=1 to see raw gRPC payloads,
# Keycloak token exchange, JWT claims, MCP server logs, and full audit-row
# JSONB. Example: make demo-flow-claude V=1
VERBOSE_ENV = $(if $(V),-e VERBOSE=1)

# Default target
help:
	@echo "Stratium Agent Authorization (Demo)"
	@echo "  quickstart        - Runs docker-down followed by docker-up"
	@echo "  docker-up         - Start all services in customer mode"
	@echo "  docker-down       - Stop customer services"
	@echo "  docker-clean      - Performs a docker-down and also removes docker volumes"
	@echo ""
	@echo "Agent delegation demos (require stack to be running):"
	@echo "  demo-flow-claude      - Claude Code delegation flow"
	@echo "  demo-flow-codex       - Codex delegation flow"
	@echo "  demo-flow-all         - Both per-agent flows back-to-back"
	@echo "  demo-flow-chain       - Multi-agent chain demo (claude -> codex, depth=2)"
	@echo "  demo-flow-admin       - Admin lifecycle (Register/List/Suspend/Cascade)"
	@echo "  demo-flow-mcp-claude  - Real Claude Code CLI calls the gateway via MCP (needs ANTHROPIC_API_KEY)"
	@echo "  demo-flow-mcp-codex   - Real Codex CLI calls the gateway via MCP (needs OPENAI_API_KEY)"
	@echo "  demo-inspect          - Show agents, delegations, audit_logs, and gateway log"
	@echo ""
	@echo "Verbose output: append V=1 to any demo target to see raw gRPC payloads,"
	@echo "JWT claims, Keycloak token exchange, and MCP server logs."
	@echo "  e.g.  make demo-flow-claude V=1"
	@echo "        make demo-flow-mcp-claude V=1"
	@echo "        make demo-inspect V=1"

# Quick start
quickstart: docker-down docker-up
	@echo "✓ Quickstart complete!"
	@echo ""
	@echo "Waiting for services to be healthy..."
	@sleep 5
	@echo ""
	@echo "You can now utilize the system!"
	@echo "  https://stratium.dev/docs - Golang CLI Client"

# Docker commands
docker-up:
	@echo "Starting all services with Docker Compose..."
	docker-compose -f docker-compose.yml up -d
	@echo "Services started!"
	@echo ""
	@echo "Enabling HTTPS on Keycloak"
	docker exec stratium-keycloak /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE --server http://localhost:8080 --realm master --user admin --password admin
	@echo ""
	@echo "Services available at:"
	@echo "  Platform:        localhost:50051 (gRPC)"
	@echo "  Key Manager:     localhost:50052 (gRPC)"
	@echo "  Key Access:      localhost:50053 (gRPC)"
	@echo "  Agent Gateway:   localhost:50054 (gRPC)"
	@echo "  Keycloak:        http://localhost:8080"
	@echo "  PostgreSQL:      localhost:5432"

docker-down:
	@echo "Stopping all services..."
	docker-compose -f docker-compose.yml down
	@echo "Services stopped!"

docker-clean:
	@echo "Cleaning volumes"
	docker-compose -f docker-compose.yml down -v
	@echo "Volumes removed!"

# ─── Agent delegation demos ───────────────────────────────────────────────────

demo-flow-claude:
	@docker exec $(VERBOSE_ENV) -it stratium-agent-claude-code /demo/flow.sh

demo-flow-codex:
	@docker exec $(VERBOSE_ENV) -it stratium-agent-codex /demo/flow.sh

demo-flow-all: demo-flow-claude demo-flow-codex

demo-flow-chain:
	@docker exec $(VERBOSE_ENV) -it stratium-agent-claude-code /demo/chain-flow.sh

demo-flow-admin:
	@docker exec $(VERBOSE_ENV) -it stratium-agent-claude-code /demo/admin-flow.sh

demo-flow-mcp-claude:
	@docker exec $(VERBOSE_ENV) -it stratium-agent-claude-code /demo/mcp-flow.sh

demo-flow-mcp-codex:
	@docker exec $(VERBOSE_ENV) -it stratium-agent-codex /demo/mcp-flow.sh

demo-inspect:
	@VERBOSE=$(V) ./bin/inspect.sh