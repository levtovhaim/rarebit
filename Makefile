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

# The CMake preset for this OS (native/CMakePresets.json): Windows sets OS=Windows_NT, macOS
# reports Darwin, anything else (Linux, WSL) uses GCC. Override it, e.g. for the sanitizer
# build: make native NATIVE_PRESET=linux-gcc-asan
NATIVE_PRESET ?= $(if $(filter Windows_NT,$(OS)),windows-msvc,$(if $(filter Darwin,$(shell uname -s)),macos-clang,linux-gcc))

native: ## Build and test the C++ code in native/ (NATIVE_PRESET=linux-gcc-asan for sanitizers)
	cd native && cmake --preset $(NATIVE_PRESET) && cmake --build --preset $(NATIVE_PRESET) && ctest --preset $(NATIVE_PRESET)

up smoke down kind-up kind-down: ## Not implemented yet (they arrive with the services, the local stack and kind)
	@echo "make $@: not implemented yet" >&2; exit 2
