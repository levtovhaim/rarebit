# Architecture decision records

One decision per record. An accepted ADR is never edited; a reversal is a new ADR that supersedes it. New ADRs start from [0000-template.md](0000-template.md).

| # | Decision | Status |
|---|---|---|
| [0001](0001-aws-region-eu-central-1.md) | Run on AWS in eu-central-1 (Frankfurt) | accepted |
| [0002](0002-cli-credentials-aws-login.md) | Short-lived CLI credentials with `aws login`, no access keys | accepted |
| [0003](0003-tool-versions-with-mise.md) | Pin tool versions in one place with mise | accepted |
| [0004](0004-llm-provider-claude-api.md) | Use the Claude API for LLM features, Haiku for volume and Sonnet for curation | accepted |
| [0005](0005-ci-runner-fleets-by-job-class.md) | Route CI jobs to a runner fleet by job class | proposed |
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
