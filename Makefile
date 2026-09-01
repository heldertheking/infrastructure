STACKS := ingress base monitoring logging medialab automation pelican
STACK  ?= $(error STACK is not set — usage: make <target> STACK=<stack-name>)

.PHONY: up down logs pull setup help

## Start a stack (requires STACK=<name>)
up:
	@$(call check_env,$(STACK))
	docker compose -f stacks/$(STACK)/compose.yaml --env-file stacks/$(STACK)/.env up -d

## Stop a stack (requires STACK=<name>)
down:
	@$(call check_env,$(STACK))
	docker compose -f stacks/$(STACK)/compose.yaml --env-file stacks/$(STACK)/.env down

## Follow logs for a stack (requires STACK=<name>)
logs:
	@$(call check_env,$(STACK))
	docker compose -f stacks/$(STACK)/compose.yaml --env-file stacks/$(STACK)/.env logs -f

## Pull latest images — pass STACK=<name> for one stack, or omit to pull all
pull:
ifdef STACK
	@$(call check_env,$(STACK))
	docker compose -f stacks/$(STACK)/compose.yaml --env-file stacks/$(STACK)/.env pull
else
	@for s in $(STACKS); do \
		if [ -f stacks/$$s/.env ]; then \
			echo "==> Pulling stack: $$s"; \
			docker compose -f stacks/$$s/compose.yaml --env-file stacks/$$s/.env pull; \
		else \
			echo "==> Skipping $$s (no .env found)"; \
		fi; \
	done
endif

## Copy .env.<stack>.example to stacks/<stack>/.env for each stack (skips if .env already exists)
setup:
	@for s in $(STACKS); do \
		env_file=stacks/$$s/.env; \
		example_file=stacks/$$s/.env.$$s.example; \
		if [ -f "$$env_file" ]; then \
			echo "==> $$s: .env already exists — skipping"; \
		elif [ -f "$$example_file" ]; then \
			cp "$$example_file" "$$env_file"; \
			echo "==> $$s: copied $$example_file → $$env_file  (edit before deploying)"; \
		else \
			echo "==> $$s: no example file found at $$example_file — skipping"; \
		fi; \
	done

## Show this help
help:
	@echo ""
	@echo "Usage: make <target> [STACK=<name>]"
	@echo ""
	@echo "Targets:"
	@grep -E '^##' Makefile | sed 's/## /  /'
	@echo ""
	@echo "Available stacks: $(STACKS)"
	@echo ""

# Internal helper — ensures a .env file exists for the given stack
define check_env
	@if [ ! -f stacks/$(1)/.env ]; then \
		echo "ERROR: stacks/$(1)/.env not found."; \
		echo "       Run 'make setup' or copy stacks/$(1)/.env.$(1).example to stacks/$(1)/.env and fill in the values."; \
		exit 1; \
	fi
endef
