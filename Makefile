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

extract-key: ## Attach the JVMTI key-extraction agent to the running TWS JVM
	./scripts/decrypt/extract-key.sh

decrypt: ## Decrypt a log: make decrypt LOG=path/to/log.ibgzenc
	@if [ -z "$(LOG)" ]; then echo "usage: make decrypt LOG=path/to/log.ibgzenc"; exit 1; fi
	./scripts/decrypt/decrypt.sh "$(LOG)"

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

.PHONY: build up down logs ps restart help