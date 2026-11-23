# Common entry points for humans, agents and CI (CLAUDE.md → Commands).
# Tools come from .mise.toml: run `mise install` once.
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules

.PHONY: help check native up smoke down kind-up kind-down

help: ## Show the targets
	@grep -hE '^[a-zA-Z_ -]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-24s %s\n", $$1, $$2}'

check: ## Lint the repo with the pre-commit hooks. Run before every commit.
	pre-commit run --all-files --show-diff-on-failure

native up smoke down kind-up kind-down: ## Not implemented yet (they arrive with the services, the local stack and kind)
	@echo "make $@: not implemented yet" >&2; exit 2
