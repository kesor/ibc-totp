.DEFAULT_GOAL := help

build: ## Build the Docker container
	docker compose build

up: ## Start the container
	docker compose up -d

down: ## Stop the container
	docker compose down

logs: ## Show container logs
	docker compose logs -f

ps: ## Show running containers
	docker compose ps

restart: ## Restart the container
	docker compose restart

extract-key: ## Manually attach JVMTI agent (normally automatic via attach-agent.sh)
	./scripts/decrypt/extract-key.sh

decrypt: ## Decrypt all .ibgzenc under jts/ (or LOG='path [path...]')
	./scripts/decrypt/decrypt.sh $(if $(LOG),$(LOG),--all)

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

.PHONY: build up down logs ps restart extract-key decrypt help
