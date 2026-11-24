# Common entry points for humans, agents and CI (CLAUDE.md → Commands).
# Tools come from .mise.toml: run `mise install` once.
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules

.PHONY: help check native hebrew-lib validator validator-integration up smoke down kind-up kind-down

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

# The validator calls native/hebrew-normalize through cgo (Linux and macOS; on Windows use WSL).
# hebrew-lib installs the archive and headers into HN_PREFIX, and cgo finds them there.
HN_PREFIX ?= $(CURDIR)/native/build/hn-prefix
CGO_ENV = CGO_ENABLED=1 CGO_CFLAGS="-I$(HN_PREFIX)/include" CGO_LDFLAGS="-L$(HN_PREFIX)/lib"
POSTGRES_IMAGE := postgres:18.7@sha256:c699303802144847d238196173655dbbecf7a96aeca1565f2b02eb671a1f0b6b

hebrew-lib: ## Build the hebrew-normalize archive for cgo (Release, no tests) into native/build/hn-prefix
	cmake -S native -B native/build/hn-release -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib
	cmake --build native/build/hn-release
	cmake --install native/build/hn-release --prefix "$(HN_PREFIX)"

validator: hebrew-lib ## Vet, test (race detector) and build apps/validator into apps/validator/build/
	cd apps/validator && $(CGO_ENV) go vet ./... && $(CGO_ENV) go test -race ./... && \
		$(CGO_ENV) go build -o build/validator ./cmd/validator

validator-integration: hebrew-lib ## Run the validator's Postgres tests against a throwaway container (Docker)
	name="rarebit-validator-it-$$$$"; \
	trap 'docker rm -f "$$name" >/dev/null' EXIT; \
	docker run -d --rm --name "$$name" -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1::5432 $(POSTGRES_IMAGE) >/dev/null; \
	for _ in $$(seq 60); do docker exec "$$name" pg_isready -q -h 127.0.0.1 -U postgres && break; sleep 1; done; \
	docker exec "$$name" pg_isready -q -h 127.0.0.1 -U postgres || { echo "Postgres didn't start" >&2; exit 1; }; \
	port="$$(docker port "$$name" 5432/tcp | head -n1 | sed 's/.*://')"; \
	cd apps/validator && VALIDATOR_TEST_DATABASE_URL="postgres://postgres@127.0.0.1:$$port/postgres?sslmode=disable" \
		$(CGO_ENV) go test -race -tags integration -count=1 ./...

up smoke down kind-up kind-down: ## Not implemented yet (they arrive with the services, the local stack and kind)
	@echo "make $@: not implemented yet" >&2; exit 2
