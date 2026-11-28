# Rarebit: a real-time Hebrew word game on an internal developer platform

**Rarebit** is a multiplayer word game in the style of **Eretz Ir (ארץ עיר)**, played from phones: in a private room with a room code, or in public quick play with other players. The rarer your valid answer, the more points it scores. Around it is an internal developer platform (IDP) built so many contributors, human or AI agent, can ship in parallel safely. It includes:
- golden-path templates
- one shared Helm chart
- reusable CI
- GitOps
- a preview environment per PR
- policy guardrails
- observability
- cost controls

## Architecture
- `apps/web`: React + Vite static UI (Hebrew, RTL), served by nginx-unprivileged. One build and one image work under any path prefix: the page reads its prefix from its own URL, so there's no `BASE_PATH` setting.
- `apps/game`: Node.js + TypeScript + Socket.IO (websocket transport only). Rounds are server-authoritative. **All room and matchmaking state is in Redis**, so any pod can serve any room. Nicknames and answers pass an offensive-word filter. Answer events go to a Redis Stream for the data pipeline.
- `apps/validator`: Go. Checks answers against the word lists in Postgres, using `native/hebrew-normalize` through cgo for normalization and fuzzy matching. The same image runs the `migrate` and `rarity` jobs.
- `apps/bots`: TypeScript simulated players: load tests, synthetic monitoring, and the test arena's personas and bot swarm.
- `apps/content-agents`: scheduled agents (answer curator, category creator) that propose content changes as PRs to `data/`. They never write to the database.
- `native/`: C++ (CMake + CMakePresets), built and tested on Linux (gcc), Windows (MSVC) and macOS (clang).
  - `hebrew-normalize`: Hebrew normalization (niqqud, final letters, spelling variants), Unicode NFC/NFD, fuzzy matching
  - `rarebit-cli`: a cross-platform command-line tool (word check, local bots runner); tagged releases ship signed binaries for all three OSes
- `data/`: word lists and categories as files. Content changes only by PR: data CI → preview → review → merge queue → a new validator image → its `validator migrate` Job.
- `ci/runner-policy.yaml`: which runner each job class (`heavy-build`, `docker`, `e2e`, `tf-plan`, `light`) uses on each OS.
- `platform/cli`: `plat`, the golden-path CLI (Python + Typer). Commands: `status`, `doctor`, `env`, `new-service`, `bench`, `agents`, `cost`.
- `deploy/`: one generic Helm chart (`charts/service`), Argo CD app-of-apps and ApplicationSets (platform, apps, previews), and per-env values.
- `infra/`: plain Terraform modules (`infra/modules`) plus a thin Terragrunt live layer (`infra/live`).
- `tests/`: Playwright e2e (Linux, Windows, macOS × Chromium, Firefox, WebKit), arena scenarios, balance simulations, and the content agents' eval set.
- Data pipeline: game → Redis Stream → ingest worker → Postgres (answers partitioned by month, with retention) → `rarity` job → a versioned rarity table, which the game reads through a cache.
- Runtime: AWS EKS in eu-central-1 (Frankfurt), with:
  - Karpenter spot nodes
  - one shared ALB (AWS Load Balancer Controller, IngressGroup)
  - CloudNativePG and Redis
  - External Secrets (SSM Parameter Store)
  - kube-prometheus-stack, Kyverno, KEDA
- CI: GitHub Actions. Each job's runner comes from `ci/runner-policy.yaml` through the reusable workflow `.github/workflows/_runners.yml` (ADR 0005): `heavy-build` on Linux runs on Incredibuild runners, every other class and OS on GitHub-hosted runners, and the classes in `github_only` (they hold credentials, or decide merges) never leave them. `.github/workflows/ci.yml` runs `make check` on every pull request, plus each check in `ci/checks.yaml` whose paths the change touches, through `_make.yml` with the `.mise.toml` pins, without mise's `[env]` and without the Actions cache (ADRs 0043, 0044); `ci-ok` sums them up and is the one check to require (#69). A new check is a line in `ci/checks.yaml`, a job in `ci.yml` and an entry in `ci-ok`'s `needs`. Repo variables:
  - `RUNNER_FLEET` (`policy`, `github` or `incredibuild`) forces one fleet, e.g. as a fallback (runbook `docs/runbooks/ci-runner-fallback.md`, written together with `ci/runner-policy.yaml`)
  - `RUNNER_LABEL`, when set, overrides the runner label for Linux jobs: one of the Linux labels in the policy, and with `RUNNER_FLEET=github` only a GitHub-hosted one
- Test arena: every PR labeled `preview` gets its preview played by AI personas and scripted bots, tested in browsers on three OSes, and hit with pod kills during play. One PR comment reports the results; a failed game blocks the merge. A scheduled exploratory QA agent also tests previews and opens issues (it can't push).
- LLM use (arena personas, content agents, exploratory QA) has a per-run token cap, a monthly cap and a kill switch (repo variable `LLM_ENABLED`).

## Commands
- `mise install`: install the pinned tool versions from `.mise.toml`. Inside the repo, mise also sets `AWS_PROFILE=rarebit`; check `aws sts get-caller-identity` before any AWS command.
- `make check`: lint and tests. Today it lints every file (gofmt included) and runs the permission-gate tests, the dependency age-scan tests, the CI script tests (`ci/test-*.sh`: the runner policy, the check picker and `ci-ok`) and the word-list check (`data/tools/check_data.py`); it narrows to what changed once there's enough to test. Run it before every commit.
- `make infra`: with no AWS credentials at all, for every module in `infra/modules`, `terraform validate`, `terraform test` against a mocked AWS provider and its example's `validate` (lock files read-only); then it validates every Terragrunt unit in `infra/live` with a placeholder account ID and admin address and no backend, and checks that each refuses an empty account ID. Run it whenever `infra/` changes. Real units read the account ID from `RAREBIT_AWS_ACCOUNT_ID` in `.mise.local.toml`, which git ignores (`infra/README.md` → Setup).
- `make native`: build and test the C++ code in `native/` for the current OS (the library and `rarebit-cli`), using its CMake preset (on Windows without `make`: the three `cmake --preset windows-msvc` steps from `native/`). `make check` doesn't build C++: run `make native` whenever `native/` changes. When the validator's matching rules or `rarebit-cli check` change, run the parity test too: `bash native/rarebit-cli/tests/parity.sh` (needs `make up` and `make bots-image`).
- `make validator`: build the library for cgo, then `go vet`, `go test -race` and `go build` in `apps/validator` (Linux; macOS unverified; on Windows in WSL). `make validator-integration` adds the Postgres tests against a throwaway container. Run both whenever `apps/validator` or `native/` changes. `make validator-image-smoke` builds the container image and runs it non-root and read-only against a throwaway Postgres: run it whenever `apps/validator`, `native/` or `data/categories/` changes.
- `make game`: `npm ci` (install scripts disabled), type check, unit tests and build in `apps/game`. `make game-integration` runs the Redis tests, with several game servers as pods, against a throwaway Redis container. Run both whenever `apps/game` changes. `make game-image-smoke` builds the game image and runs it non-root and read-only against a throwaway Redis: run it whenever `apps/game` changes too (after `make game`, which installs its test client).
- `make web`: `npm ci`, type check, unit tests and `vite build` in `apps/web` (static files in `dist/`). Run it whenever `apps/web` changes. `make web-image-smoke` builds the web image (nginx-unprivileged) and checks it non-root and read-only: the runtime contract, caching and security headers, any path prefix, the graceful stop. Run it whenever `apps/web` changes too. `cd apps/web && npm run dev` serves the UI on http://localhost:5173 against the local stack (`make up`), reloading on every edit.
- `make bots`: `npm ci`, type check, unit tests and build in `apps/bots`. `make bots-integration` plays the bots against two real game servers (`apps/game/dist`), a throwaway Redis and a fake validator, including a server killed and one drained mid-round. Run both whenever `apps/bots` or `apps/game` changes (after `make game`). `make bots-image-smoke` builds the bots image and checks its contract: run it whenever `apps/bots` or `data/categories/` changes.
- `make up` / `make smoke` / `make down`: local stack with docker compose (`compose/`): Postgres, migrate, the validator, Redis, two game replicas and the web UI behind nginx on 127.0.0.1:8080 (play there); `smoke` = the bots image plays a full game through it.
- `make deploy`: `helm lint` the shared chart, render every service in `deploy/apps` with it, validate the manifests with kubeconform, and check them against the golden path and each service's shutdown timing (`deploy/test/render.sh`, ADR 0045). Run it whenever `deploy/` or `catalog/` changes.
- `make kind-up` / `make kind-down`: local Kubernetes (kind) with Argo CD syncing from git. Planned: until it's built, both targets exit 2.
- `plat doctor`: verify tools, versions, AWS identity and kube context.
- `plat env up` / `plat env down`: create or destroy the AWS platform. **A human runs it or approves the exact command** (rule 2). Until `plat` exists, `bash platform/env.sh up` / `down` does it (ADR 0049), and `bash platform/env.sh status` shows what exists (read-only); runbook `docs/runbooks/eks.md`.
- PR labels: `preview` creates the PR's preview environment and runs the test arena; `arena:full` adds the full persona tournament.

## Rules for every contributor (humans and agents)
1. **PRs only.** Never push to `main`. One issue = one small PR. Use Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`, `infra:`).
2. **Infra-changing commands need a human's decision.** Never run these on your own:
   - `terraform` or `terragrunt` `apply`/`destroy`/`import`/`state`/`force-unlock`/`refresh`/`taint`/`untaint`, and `init -migrate-state`
   - `plat env up` / `plat env down`, and `bash platform/env.sh up` / `down`
   - `kubectl apply`/`delete` outside your own preview namespace
   - `helm install`/`upgrade`/`uninstall`/`rollback`
   - any `aws` command that creates, changes or deletes something

   A human runs the command, or approves that exact command when Claude Code prompts for it (`.claude/settings.json`; bypass mode is disabled, so the prompt can't be skipped). Say what it costs per hour before asking. With no human at the prompt (a headless run), propose the command in the PR instead (ADR 0007). Plain read-only `aws` and `gh api` calls run without a prompt through `.claude/hooks/readonly-gate.sh` (ADR 0006); add a test row when you change it.
3. **Use the golden path:**
   - new services via `plat new-service`
   - deploy with `deploy/charts/service` (its `values.schema.json` must pass)
   - CI through the reusable workflows in `.github/workflows/_*.yml`

   Don't copy-paste pipelines or charts.
4. **Pin everything:**
   - GitHub Actions by full commit SHA
   - base images by digest
   - Terraform providers and modules by version
   - Helm charts by version
5. **No secrets in git, ever.** Config comes from env vars. Secrets come from External Secrets (SSM). CI reaches AWS only through GitHub OIDC; there are no static keys.
6. **Cost guardrails:**
   - no NAT Gateways (we use a NAT instance)
   - no new load balancers (join IngressGroup `rarebit`)
   - no EKS version in extended support
   - every AWS resource tagged through provider `default_tags`
   - Infra PRs must show an Infracost diff.
7. **Runtime contract for every service:**
   - endpoints: `/healthz` (liveness), `/readyz` (readiness; false while draining), `/metrics` (Prometheus), `/version` (git SHA)
   - JSON logs to stdout
   - config validated at startup
   - graceful drain on the image's stop signal: SIGTERM, or SIGQUIT for nginx, whose SIGTERM is a fast stop (ADR 0027)
   - runs as non-root with a read-only root filesystem
8. **Docs move with the code.** An architecture change needs an ADR in `docs/adr/`. An ops change needs a runbook in `docs/runbooks/`. An incident or chaos finding gets a postmortem in `docs/postmortems/`.
9. **Don't bypass checks.** No `--no-verify`, no disabled tests, no skipped scanners. Fix the cause, or open an issue explaining why not.
10. **When unsure, stop and ask** in the issue or PR instead of guessing.

## Conventions
- Code, comments, commits and docs are in English. Player-facing UI strings are in Hebrew (RTL).
- Image tags: `pr-<number>-<sha7>` for PRs, pushed to `rarebit/pr/<service>`; `main-<sha7>` for main, pushed to `rarebit/<service>`. Tags are immutable in ECR. PR images expire 7 days after the push; each main repository keeps the newest 50 `main-` images (ADR 0036).
- Promotion: a promotion PR changes only `image-tags.yaml` files under `deploy/envs/`. They are the one path under `deploy/` without a code owner (`.github/CODEOWNERS`), so promotions merge without a human; anything else in `deploy/` requests review. A promotion pins only `main-` images from the main repositories, by digest (`main-<sha7>@sha256:...`), and no environment may fall more than 50 `main` builds behind, or its image expires (ADR 0036).
- Kubernetes labels: `app.kubernetes.io/name`, `app.kubernetes.io/part-of=rarebit`, `owner`, `tier`. The values of `owner` and `tier` come from the service's `catalog/<service>.yaml` (`catalog/README.md` defines the tiers).
- Terraform: each module has a `README.md` (terraform-docs), `examples/basic` (works with plain `terraform`), `versions.tf` and tests in `tests/`. Live config lives only in `infra/live`.
- Tests: the Go validator uses table-driven tests; game and bots use vitest; the C++ code uses GoogleTest through CTest; Terraform modules use `terraform test` with a mocked provider (`mock_provider`), so no test reaches AWS; game e2e runs through `apps/bots`, browser e2e through Playwright.
- C++ (`native/`): C++20, warnings as errors, built with the CMake preset for the OS (`make native`). Each library is a static archive with a C API, so cgo links it without C++ name mangling (ADRs 0009–0011).
- Line endings: LF everywhere (`.gitattributes`).

## Worktrees and parallel work
- Worktrees live **outside** the main checkout: `git worktree add ../rarebit-agents/<branch> -b <branch> origin/main`.
- Never create `.worktrees/` or `.claude/worktrees/` inside the repo. Local, untracked config must not leak into other workspaces.
- One agent = one worktree = one branch = one PR. Clean up with `git worktree remove` when the PR is merged or closed.

## Documentation map (docs-sync-reviewer enforces these couplings)
| Doc | Purpose | Update in the same PR when |
|---|---|---|
| `README.md` | what it is, quickstart, highlights | user-visible behavior, commands or setup change |
| `docs/architecture.md` | components and data flow | a service, dependency or network path changes |
| `docs/adr/NNNN-*.md` | one decision each | a tool or pattern is chosen or reversed. Write a new ADR; supersede old ones, don't edit them. |
| `docs/runbooks/*.md` | how to operate and fix | an alert, failure mode or ops procedure is added or changed |
| `docs/postmortems/*.md` | incidents and chaos findings | after every incident or chaos experiment |
| `docs/cost.md` | cost model vs actuals | instance types, sizing or always-on resources change |
| `docs/benchmarks/*.md` | measured results | CI, load or agent experiments are re-run |
| `catalog/<service>.yaml` | owner, tier, SLOs, runbook link | a service is added or renamed, or its SLOs change |
| `CLAUDE.md` | rules for all contributors | a convention or workflow changes |

## Skills and reviewers
| When | Use |
|---|---|
| Before claiming anything works | `verification-before-completion` |
| Bugs and incidents | `systematic-debugging` |
| Parallel work | `using-git-worktrees` + `dispatching-parallel-agents` |
| Adding or bumping any dependency | `dependency-versioning` |
| UI work in `apps/web` | `frontend-design` while building; `web-design-guidelines` to review it |
| Before merge (one round per PR, before any apply) | `cleanup`. It dispatches, in parallel, `security-reviewer`, `resilience-reviewer` or `auditor` as the diff needs, and one `convention-compliance-reviewer` on a cheaper model that also runs the `docs-sync-reviewer` checklist. |
| Infra, CI and cost changes | `auditor` (`.claude/agents/auditor.md`); address its CRITICAL and HIGH findings |

## Review
Infra, CI, Argo CD, policy, `plat` CLI, ADR and quality-gate paths have code owners (`.github/CODEOWNERS`), so GitHub requests their review on every PR that touches them. Approval is **not enforced yet**: the `main` ruleset requires a PR but no approvals, and a human merges every PR by hand. Required approval and code-owner review come with a separate GitHub identity for agents; until then, never merge your own PR unless a human tells you to.
