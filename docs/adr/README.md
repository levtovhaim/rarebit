# Architecture decision records

One decision per record. An accepted ADR is never edited; a reversal is a new ADR that supersedes it. New ADRs start from [0000-template.md](0000-template.md).

| # | Decision | Status |
|---|---|---|
| [0001](0001-aws-region-eu-central-1.md) | Run on AWS in eu-central-1 (Frankfurt) | accepted; the live-layer path superseded by 0033 |
| [0002](0002-cli-credentials-aws-login.md) | Short-lived CLI credentials with `aws login`, no access keys | accepted |
| [0003](0003-tool-versions-with-mise.md) | Pin tool versions in one place with mise | accepted |
| [0004](0004-llm-provider-claude-api.md) | Use the Claude API for LLM features, Haiku for volume and Sonnet for curation | accepted |
| [0005](0005-ci-runner-fleets-by-job-class.md) | Route CI jobs to a runner fleet by job class | accepted |
| [0006](0006-agent-permission-gate.md) | Gate aws and gh api calls with an allowlist hook, not ask rules | accepted |
| [0007](0007-infra-changes-by-human-approval.md) | Infra-changing commands run with a human's approval of the exact command | accepted |
| [0008](0008-hebrew-normalization-without-icu.md) | Normalize Hebrew with generated Unicode tables, not ICU | accepted |
| [0009](0009-cpp-toolchain-cmake-presets.md) | Build the C++ code as C++20 with CMake presets, one per OS | accepted |
| [0010](0010-c-api-at-the-cgo-boundary.md) | Expose native libraries to Go through a C API on a static archive | accepted |
| [0011](0011-googletest-through-fetchcontent.md) | Test C++ with GoogleTest, fetched by CMake and pinned by hash | accepted |
| [0012](0012-word-lists-as-json-per-category.md) | Keep word lists as one JSON file per category, each list with its own source and license | accepted |
| [0013](0013-validator-http-json-api.md) | Serve validation as an HTTP/JSON API | accepted |
| [0014](0014-migrations-and-content-load-in-the-validator.md) | Run schema migrations and the word-list load from the validator binary, as a Job | accepted |
| [0015](0015-validator-lookups-from-postgres.md) | Look up Postgres on every validation, and include the database in readiness | accepted |
| [0016](0016-own-migration-runner.md) | Apply migrations with a small runner in the validator, not a migration tool | accepted |
| [0017](0017-validator-image-distroless-cc.md) | Build the validator image in two stages and link glibc and libstdc++ dynamically, on distroless cc | accepted |
| [0018](0018-word-lists-in-the-validator-image.md) | Ship the word lists in the validator image | accepted |
| [0019](0019-game-state-in-redis.md) | Keep game state and matchmaking in Redis, changed only by compare-and-set | accepted |
| [0020](0020-game-client-protocol.md) | Speak to game clients in Socket.IO events with acknowledgements, resume tokens and server deadlines | accepted |
| [0021](0021-game-timers-swept-with-leases.md) | Run game timers from a deadline set that every pod sweeps, under per-room leases | accepted |
| [0022](0022-game-image-distroless-nodejs.md) | Run the game image on distroless Node.js, with Node itself as PID 1 | accepted |
| [0023](0023-bots-protocol-clients-judged-by-failed-games.md) | Build the bots as real protocol clients with a strategy hook, and judge runs by failed games | accepted |
| [0024](0024-local-stack-with-compose-and-nginx.md) | Run the local stack with docker compose, two game replicas behind nginx | accepted; the `make smoke` bullet superseded by 0025 |
| [0025](0025-bots-image-and-smoke-from-it.md) | Ship the bots as an image, and run `make smoke` from it | accepted |
| [0026](0026-web-ui-static-bundle-from-the-snapshot.md) | Build the web UI as one static bundle that renders from the room snapshot | accepted |
| [0027](0027-web-image-nginx-any-path.md) | Serve the web UI from its own nginx-unprivileged image, under any path prefix | accepted; the base image superseded by 0031 |
| [0028](0028-web-caching.md) | Cache the web UI's hashed assets for a year, and revalidate the page on every load | accepted |
| [0029](0029-web-security-headers.md) | Send a strict Content-Security-Policy and security headers on every web response | accepted |
| [0030](0030-rarebit-cli-in-cpp.md) | Write rarebit-cli in C++, judging answers offline with the validator's rules | accepted |
| [0031](0031-web-image-slim-base-with-pinned-alpine-updates.md) | Build the web image on the slim nginx-unprivileged base, with pinned Alpine security updates | accepted |
| [0032](0032-terraform-state-in-s3-with-native-locking.md) | Keep Terraform state in one S3 bucket with native locking | accepted; locking for pull request plans superseded by 0038 |
| [0033](0033-terragrunt-live-layer-over-plain-modules.md) | A thin Terragrunt live layer over plain Terraform modules | accepted |
| [0034](0034-terraform-creates-its-own-state-bucket.md) | Terraform creates its own state bucket: the first apply on local state, then a migration | accepted |
| [0035](0035-account-id-out-of-git.md) | Keep the AWS account ID out of git: an environment variable locally, a masked secret in CI | accepted |
| [0036](0036-ecr-repository-per-service.md) | Private ECR repositories per service, separate for main and PR images, with immutable tags and lifecycle rules | accepted; who may push to and delete from the main repositories superseded by 0040 |
| [0037](0037-no-terragrunt-destroy-in-global.md) | Terragrunt's destroy command never runs in the account's foundation units | accepted |
| [0038](0038-github-oidc-roles.md) | GitHub Actions reaches AWS through OIDC, with one role per kind of job, trusted by exact claims | accepted; the plan role's reading of every unit's state superseded by 0042 |
| [0039](0039-shared-names-for-global-units.md) | Names that several `_global` units need are written once, in `_global/shared.hcl` | accepted |
| [0040](0040-ecr-repository-policies.md) | ECR repositories enforce who may push and delete with deny-only repository policies, and people keep both as break-glass | accepted |
| [0041](0041-cost-alerts-imported.md) | The cost budgets and anomaly monitor are Terraform, imported from the console, not recreated | accepted |
| [0042](0042-private-state-units.md) | A unit whose state holds personal data is private: its value comes from the environment, and pull request plans can't read it | accepted |
