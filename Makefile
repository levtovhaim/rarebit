# Common entry points for humans, agents and CI (CLAUDE.md → Commands).
# Tools come from .mise.toml: run `mise install` once.
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules

.PHONY: help check infra native hebrew-lib validator validator-integration validator-image validator-image-smoke game game-integration game-image game-image-smoke bots bots-integration bots-image bots-image-smoke web web-image web-image-smoke up smoke down kind-up kind-down

help: ## Show the targets
	@grep -hE '^[a-zA-Z_ -]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-24s %s\n", $$1, $$2}'

check: ## Lint the repo with the pre-commit hooks. Run before every commit.
	pre-commit run --all-files --show-diff-on-failure

# Terraform keeps one copy of each provider here instead of one per directory (the AWS provider is
# several hundred MB). make infra's Terragrunt working copies go to INFRA_TG_DOWNLOAD_DIR, apart from
# the ones real runs use (TG_DOWNLOAD_DIR in .mise.toml), because they're built with a placeholder
# account ID and no backend.
TF_PLUGIN_CACHE_DIR ?= $(HOME)/.cache/terraform/plugins
INFRA_TG_DOWNLOAD_DIR ?= $(HOME)/.cache/terragrunt-make-infra

# make infra runs with no AWS credentials at all. `terraform test` applies for real unless a test
# mocks its provider, so a test that forgot the mock fails at provider setup instead of creating
# resources with whoever's credentials are active.
NO_AWS_CREDENTIALS = unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
	AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE \
	AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI; \
	export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true

infra: ## Check infra/ with no AWS credentials: validate and test each module (AWS mocked) and its example, validate each Terragrunt unit
	@$(NO_AWS_CREDENTIALS); \
	mkdir -p "$(TF_PLUGIN_CACHE_DIR)"; export TF_PLUGIN_CACHE_DIR="$(TF_PLUGIN_CACHE_DIR)"; \
	for m in infra/modules/*/; do \
		m="$${m%/}"; echo "== $$m"; \
		terraform -chdir="$$m" init -backend=false -input=false -lockfile=readonly -no-color >/dev/null; \
		terraform -chdir="$$m" validate -no-color; \
		terraform -chdir="$$m" test -no-color; \
		terraform -chdir="$$m/examples/basic" init -backend=false -input=false -lockfile=readonly -no-color >/dev/null; \
		terraform -chdir="$$m/examples/basic" validate -no-color; \
	done; \
	units="$$(find infra/live -name terragrunt.hcl -not -path '*/.terragrunt-cache/*' -exec dirname {} \; | sort)"; \
	[ -n "$$units" ] || { echo "make infra: no Terragrunt units found under infra/live" >&2; exit 1; }; \
	echo "== infra/live (a placeholder account ID and admin address, no backend; nothing reaches AWS)"; \
	export TG_DOWNLOAD_DIR="$(INFRA_TG_DOWNLOAD_DIR)" TG_NON_INTERACTIVE=true TG_LOG_LEVEL=error; \
	export RAREBIT_ADMIN_CIDR=192.0.2.1/32; \
	for u in $$units; do \
		if RAREBIT_AWS_ACCOUNT_ID= terragrunt render --working-dir "$$u" --format json >/dev/null 2>&1; then \
			echo "make infra: $$u renders with an empty account ID, so its account check would be off" >&2; exit 1; \
		fi; \
		RAREBIT_AWS_ACCOUNT_ID=000000000000 terragrunt run --working-dir "$$u" --no-auto-init -- \
			init -backend=false -input=false -lockfile=readonly -no-color >/dev/null; \
		RAREBIT_AWS_ACCOUNT_ID=000000000000 terragrunt run --working-dir "$$u" --no-auto-init -- validate -no-color >/dev/null; \
		echo "$$u: valid (and refuses an empty account ID)"; \
	done; \
	echo "== infra/live: no destroy reaches a _global unit (ADR 0037)"; \
	planned="$$(RAREBIT_AWS_ACCOUNT_ID=000000000000 terragrunt find --working-dir infra/live --as plan)"; \
	destroyed="$$(RAREBIT_AWS_ACCOUNT_ID=000000000000 terragrunt find --working-dir infra/live --as destroy)"; \
	grep -q '^_global/' <<<"$$planned" || { echo "make infra: terragrunt find listed no _global unit to plan, so the destroy check would prove nothing" >&2; exit 1; }; \
	if grep -q '^_global/' <<<"$$destroyed"; then \
		echo "make infra: a destroy would reach $$(grep '^_global/' <<<"$$destroyed" | tr '\n' ' ')(the exclude block in infra/live/root.hcl)" >&2; exit 1; \
	fi; \
	echo "$$(grep -c '^_global/' <<<"$$planned") _global units, none queued for destroy"

# The CMake preset for this OS (native/CMakePresets.json): Windows sets OS=Windows_NT, macOS
# reports Darwin, anything else (Linux, WSL) uses GCC. Override it, e.g. for the sanitizer
# build: make native NATIVE_PRESET=linux-gcc-asan
NATIVE_PRESET ?= $(if $(filter Windows_NT,$(OS)),windows-msvc,$(if $(filter Darwin,$(shell uname -s)),macos-clang,linux-gcc))

native: ## Build and test the C++ code in native/ (NATIVE_PRESET=linux-gcc-asan for sanitizers)
	cd native && cmake --preset $(NATIVE_PRESET) && cmake --build --preset $(NATIVE_PRESET) && ctest --preset $(NATIVE_PRESET)

# The validator calls native/hebrew-normalize through cgo (Linux; macOS unverified; on Windows use WSL).
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
	. apps/validator/test/pg.sh; \
	name="rarebit-validator-it-$$$$"; \
	trap 'docker rm -fv "$$name" >/dev/null 2>&1' EXIT; \
	pg_start "$$name" $(POSTGRES_IMAGE); \
	cd apps/validator && VALIDATOR_TEST_DATABASE_URL="postgres://postgres:$$PG_PASSWORD@127.0.0.1:$$(pg_port "$$name")/postgres?sslmode=disable" \
		$(CGO_ENV) go test -race -tags integration -count=1 ./...

REDIS_IMAGE := redis:8.10.3-alpine@sha256:7958cfbb9d152f87dadfbc89f1b0b15938f0b81ff8982feb327476f4911935c3

game: ## Install the locked npm packages, type-check, unit-test and build apps/game
	cd apps/game && npm ci --no-fund && npm run typecheck && npm test && npm run build && test -f dist/main.js

game-integration: ## Run the game's Redis tests (several servers as pods) against a throwaway Redis (Docker)
	name="rarebit-game-it-$$$$"; \
	trap 'docker rm -fv "$$name" >/dev/null 2>&1' EXIT; \
	docker run -d --name "$$name" -p 127.0.0.1::6379 $(REDIS_IMAGE) >/dev/null; \
	for _ in $$(seq 30); do docker exec "$$name" redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 0.5; done; \
	port="$$(docker port "$$name" 6379/tcp | head -n1 | sed 's/.*://')"; \
	cd apps/game && TEST_REDIS_URL="redis://127.0.0.1:$$port" npm run test:integration

web: ## Install the locked npm packages, type-check, unit-test and build apps/web (static files in dist/)
	cd apps/web && npm ci --no-fund && npm run typecheck && npm test && npm run build && test -f dist/index.html

# Sets $sha for an image's GIT_SHA build arg: exactly 7 characters (`--short` grows when 7 are
# ambiguous), the same as the <sha7> in image tags, plus -dirty when the tree has uncommitted
# changes, so a local build never claims a commit it doesn't match. Each git call is its own
# command, so its failure stops the recipe with a message. (Inside one assignment, a git failure
# was lost: the status of an assignment with several $(…) is the last one's, and an empty SHA
# went on to docker build.)
IMAGE_SHA = head="$$(git rev-parse HEAD)" && status="$$(git status --porcelain)" \
	|| { echo "$@: git can't read the commit or the tree's status" >&2; exit 1; }; \
	sha="$${head:0:7}$${status:+-dirty}"

WEB_IMAGE ?= rarebit-web:dev

web-image: ## Build the web UI image (apps/web/Dockerfile; the context is the repo root)
	$(IMAGE_SHA); \
	docker build -f apps/web/Dockerfile --build-arg GIT_SHA="$$sha" -t "$(WEB_IMAGE)" .

web-image-smoke: web-image ## Run the web image non-root and read-only: the UI under any prefix, caching, the contract, the stop
	bash apps/web/test/image-smoke.sh "$(WEB_IMAGE)"

bots: ## Install the locked npm packages, type-check, unit-test and build apps/bots
	cd apps/bots && npm ci --no-fund && npm run typecheck && npm test && npm run build && test -f dist/main.js

bots-integration: ## Run the bots against two real game servers, a throwaway Redis and a fake validator (needs make game and make bots)
	test -f apps/game/dist/main.js || { echo "apps/game isn't built: run make game first" >&2; exit 2; }; \
	test -f apps/bots/dist/main.js || { echo "apps/bots isn't built: run make bots first" >&2; exit 2; }; \
	name="rarebit-bots-it-$$$$"; \
	trap 'docker rm -fv "$$name" >/dev/null 2>&1' EXIT; \
	docker run -d --name "$$name" -p 127.0.0.1::6379 $(REDIS_IMAGE) >/dev/null; \
	for _ in $$(seq 30); do docker exec "$$name" redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 0.5; done; \
	port="$$(docker port "$$name" 6379/tcp | head -n1 | sed 's/.*://')"; \
	cd apps/bots && TEST_REDIS_URL="redis://127.0.0.1:$$port" npm run test:integration

BOTS_IMAGE ?= rarebit-bots:dev

bots-image: ## Build the bots image (apps/bots/Dockerfile; the context is the repo root)
	$(IMAGE_SHA); \
	docker build -f apps/bots/Dockerfile --build-arg GIT_SHA="$$sha" -t "$(BOTS_IMAGE)" .

bots-image-smoke: bots-image ## Check the bots image's contract: non-root, read-only, word lists, SIGTERM
	bash apps/bots/test/image-smoke.sh "$(BOTS_IMAGE)"

GAME_IMAGE ?= rarebit-game:dev

game-image: ## Build the game image (apps/game/Dockerfile; the context is the repo root)
	$(IMAGE_SHA); \
	docker build -f apps/game/Dockerfile --build-arg GIT_SHA="$$sha" -t "$(GAME_IMAGE)" .

game-image-smoke: game-image ## Run the game image non-root and read-only against a throwaway Redis (needs make game first)
	bash apps/game/test/image-smoke.sh "$(GAME_IMAGE)" "$(REDIS_IMAGE)"

VALIDATOR_IMAGE ?= rarebit-validator:dev

validator-image: ## Build the validator image (apps/validator/Dockerfile; the context is the repo root)
	$(IMAGE_SHA); \
	docker build -f apps/validator/Dockerfile --build-arg GIT_SHA="$$sha" -t "$(VALIDATOR_IMAGE)" .

validator-image-smoke: validator-image ## Run the image non-root and read-only against a throwaway Postgres
	bash apps/validator/test/image-smoke.sh "$(VALIDATOR_IMAGE)" "$(POSTGRES_IMAGE)"

COMPOSE := docker compose -f compose/compose.yaml
# The port nginx publishes on 127.0.0.1; compose reads it from the environment.
RAREBIT_PORT ?= 8080
export RAREBIT_PORT

# The stack's Postgres password is random and kept in compose/.env (git-ignored; compose reads it)
# for as long as the stack exists, so a second `make up` reuses it. `make down` removes it with
# the database.
up: validator-image game-image web-image ## Start the local stack (compose/compose.yaml) and wait until it's healthy
	test -f compose/.env || printf 'RAREBIT_PG_PASSWORD=%s\n' "$$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" > compose/.env
	$(COMPOSE) up -d --wait --wait-timeout 180
	@echo "up: http://127.0.0.1:$(RAREBIT_PORT) (make smoke plays a game through it; make down removes it all)"

smoke: bots-image ## The web UI answers at /, then bots play a full game through nginx (make up first)
	curl -fsS --max-time 5 "http://127.0.0.1:$(RAREBIT_PORT)/" | grep -q 'id="root"' || \
		{ echo "smoke: no web UI at http://127.0.0.1:$(RAREBIT_PORT)/" >&2; exit 1; }
	$(COMPOSE) run --rm bots synthetic --timeout 300

down: ## Stop the local stack and remove its containers, network and data
	$(COMPOSE) down --volumes --remove-orphans
	rm -f compose/.env

kind-up kind-down: ## Not implemented yet (they arrive with kind)
	@echo "make $@: not implemented yet" >&2; exit 2
