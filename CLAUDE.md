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
- `apps/web`: React + Vite static UI (Hebrew, RTL), served by nginx-unprivileged. Supports `BASE_PATH`.
- `apps/game`: Node.js + TypeScript + Socket.IO (websocket transport only). Rounds are server-authoritative. **All room and matchmaking state is in Redis**, so any pod can serve any room. Nicknames and answers pass an offensive-word filter. Answer events go to a Redis Stream for the data pipeline.
- `apps/validator`: Go. Checks answers against the word lists in Postgres, using `native/hebrew-normalize` through cgo for normalization and fuzzy matching. The same image runs the `migrate` and `rarity` jobs.
- `apps/bots`: TypeScript simulated players: load tests, synthetic monitoring, and the test arena's personas and bot swarm.
- `apps/content-agents`: scheduled agents (answer curator, category creator) that propose content changes as PRs to `data/`. They never write to the database.
- `native/`: C++ (CMake + CMakePresets), built and tested on Linux (gcc), Windows (MSVC) and macOS (clang).
  - `hebrew-normalize`: Hebrew normalization (niqqud, final letters, spelling variants), Unicode NFC/NFD, fuzzy matching
  - `rarebit-cli`: a cross-platform command-line tool (word check, local bots runner); tagged releases ship signed binaries for all three OSes
- `data/`: word lists and categories as files. Content changes only by PR: data CI → preview → review → merge queue → a loader Job.
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
- CI: GitHub Actions. Each job's runner comes from `ci/runner-policy.yaml`: heavy job classes run on Incredibuild runners, light ones on GitHub-hosted runners. Repo variables:
  - `RUNNER_FLEET` (`policy`, `github` or `incredibuild`) forces one fleet, e.g. as a fallback (runbook: `docs/runbooks/ci-runner-fallback.md`)
  - `RUNNER_LABEL`, when set, overrides the runner label for Linux jobs
- Test arena: every PR labeled `preview` gets its preview played by AI personas and scripted bots, tested in browsers on three OSes, and hit with pod kills during play. One PR comment reports the results; a failed game blocks the merge. A scheduled exploratory QA agent also tests previews and opens issues (it can't push).
- LLM use (arena personas, content agents, exploratory QA) has a per-run token cap, a monthly cap and a kill switch (repo variable `LLM_ENABLED`).

## Commands
- `mise install`: install the pinned tool versions from `.mise.toml`. Inside the repo, mise also sets `AWS_PROFILE=rarebit`; check `aws sts get-caller-identity` before any AWS command.
- `make check`: lint and unit tests for what changed. Run it before every commit.
- `make native`: build and test the C++ code in `native/` for the current OS, using its CMake preset.
- `make up` / `make smoke` / `make down`: local stack with docker compose; `smoke` = bots play a full game.
- `make kind-up` / `make kind-down`: local Kubernetes (kind) with Argo CD syncing from git.
- `plat doctor`: verify tools, versions, AWS identity and kube context.
- `plat env up` / `plat env down`: create or destroy the AWS platform. **Humans only.**
- PR labels: `preview` creates the PR's preview environment and runs the test arena; `arena:full` adds the full persona tournament.

## Rules for every contributor (humans and agents)
1. **PRs only.** Never push to `main`. One issue = one small PR. Use Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`, `infra:`).
2. **Never run infra-changing commands:**
   - `terraform` or `terragrunt` `apply`/`destroy`/`import`/`state`
   - `plat env up` / `plat env down`
   - `kubectl apply`/`delete` outside your own preview namespace
   - `helm install`/`upgrade`/`uninstall`
   - any `aws` command that creates, changes or deletes something

   Propose the command in the PR; a human runs it. Claude Code prompts before these (`.claude/settings.json`). Plain read-only `aws` and `gh api` calls run without a prompt through `.claude/hooks/readonly-gate.sh` (ADR 0006); add a test row when you change it.
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
   - graceful drain on SIGTERM
   - runs as non-root with a read-only root filesystem
8. **Docs move with the code.** An architecture change needs an ADR in `docs/adr/`. An ops change needs a runbook in `docs/runbooks/`. An incident or chaos finding gets a postmortem in `docs/postmortems/`.
9. **Don't bypass checks.** No `--no-verify`, no disabled tests, no skipped scanners. Fix the cause, or open an issue explaining why not.
10. **When unsure, stop and ask** in the issue or PR instead of guessing.

## Conventions
- Code, comments, commits and docs are in English. Player-facing UI strings are in Hebrew (RTL).
- Image tags: `pr-<number>-<sha7>` for PRs, `main-<sha7>` for main. Tags are immutable in ECR.
- Kubernetes labels: `app.kubernetes.io/name`, `app.kubernetes.io/part-of=rarebit`, `owner`, `tier`.
- Terraform: each module has a `README.md` (terraform-docs), `examples/basic` (works with plain `terraform`) and `versions.tf`. Live config lives only in `infra/live`.
- Tests: the Go validator uses table-driven tests; game and bots use vitest; the C++ code uses CTest; game e2e runs through `apps/bots`, browser e2e through Playwright.
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
| Before merge | `cleanup`. It dispatches `security-reviewer`, `resilience-reviewer`, `docs-sync-reviewer` and `convention-compliance-reviewer` in parallel. |
| Infra, CI and cost changes | `auditor` (`.claude/agents/auditor.md`); address its CRITICAL and HIGH findings |

## Review
Infra, CI, Argo CD and policy changes need CODEOWNERS approval.
