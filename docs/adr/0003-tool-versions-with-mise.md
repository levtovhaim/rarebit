# 0003. Pin tool versions in one place with mise

- **Status:** accepted
- **Date:** 2026-11-23
- **Deciders:** @haimlevtov

## Context

- The repo needs about 26 CLIs, linters, scanners and runtimes: Terraform, Terragrunt, kubectl, Helm, kind, Trivy, actionlint, Node, Go, Python and others.
- Humans, AI agents and CI must run the same versions. A kubectl three minor versions away from the cluster, or a linter a version apart between laptop and CI, produces failures that only happen "on that machine".
- CLAUDE.md requires pinning everything (rule 4), and new versions follow a 7-day publish-age rule (`.claude/skills/dependency-versioning`).

## Decision

- **`.mise.toml` is the single source of tool versions.** `mise install` installs exactly those versions, and inside the repo mise also sets `AWS_PROFILE` and `AWS_REGION`.
- The lint hooks in `.pre-commit-config.yaml` call these tools (`repo: local`, `language: system`) instead of pinning their own copies. CI will install the same file.
- `min_version` sets the oldest mise the file is known to work with.
- Versions change only by PR, following the 7-day rule. CODEOWNERS sends those PRs to the platform owner.
- Verified on 2026-11-23 in WSL with mise 2026.11.9: all 26 tools installed and report their pinned versions.

## Alternatives considered

| Option | Why not |
|---|---|
| asdf | The same idea, but slower shims, a plugin per tool, and no built-in env or task support |
| A devcontainer | Every editor session and agent would run inside Docker: heavier, and a second environment to maintain next to CI |
| Each pre-commit hook repo pins its own tool | Two places to pin every version, and they drift apart |
| OS package managers | Versions differ by distro and update on their own schedule |

## Consequences

- **Good:** one reviewed file defines the toolchain everywhere; version bumps are visible PRs; the right AWS profile is selected by the directory, not by memory.
- **Bad / risks:** contributors must install mise. Native Windows support is partial, so WSL is the supported environment on Windows. Tool downloads come from upstream releases (the aqua backend checks checksums).
- **Follow-ups:** install the toolchain in CI from the same file; consider mise's lockfile (pinned checksums) once it's stable.

## How we'll know it was right

- No "works on my machine" failures caused by tool versions.
- CI and local `make check` give the same results.
