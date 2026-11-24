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
| [0009](0009-cpp-toolchain-presets-googletest.md) | C++20 with CMake presets, a C API at the boundary, and GoogleTest pinned by hash | accepted |
