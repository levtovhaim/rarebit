# 0044. CI installs the tools pinned in .mise.toml with mise-action, and puts them on PATH without mise's [env]

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- `.mise.toml` pins every tool's version, for every machine, agent and CI job (ADR 0003). The checks are `make` targets (CLAUDE.md → Commands). CI has to run the same commands with the same versions, or a check can pass locally and fail in CI.
- The runner images bring their own tools, and those change with every image update: the policy's first runs found jq 1.7 on the image, against 1.8.2 in `.mise.toml` (ADR 0005).
- `.mise.toml` also sets `[env]` for people's machines: `AWS_PROFILE=rarebit`, `AWS_REGION` and Terragrunt's cache directories.
- A mise shim applies `[env]` to every tool it starts. Checked in WSL on 2026-11-27: run through its shim, `jq` saw `AWS_PROFILE=rarebit`; run from the directory `mise bin-paths` lists, it saw no `AWS_PROFILE`.
- In CI, a job that takes an AWS role through OIDC (the image push and plan jobs to come) would then have its tools look for a profile that doesn't exist on the runner.
- `jdx/mise-action` installs mise and the tools, and can cache them. By default:
  - it exports `[env]` to every later step;
  - it puts the shims on PATH;
  - with `env: false`, it puts only the shims on PATH.

## Decision

**CI jobs run `make` through the reusable workflow `.github/workflows/_make.yml`**, with the job's class (ADR 0005), its tools and its targets as inputs. The workflow:

1. checks out the repository (without persisted credentials);
2. runs `jdx/mise-action`, pinned by commit SHA, with:
   - mise pinned by version (2026.11.10, the newest release at least 7 days old);
   - only the job's tools installed, by their names in `.mise.toml`;
   - `env: false` and `add_shims_to_path: false`;
   - the Actions cache only on GitHub-hosted runners (ADR 0005: until #67 measures the vendor's runners, nothing a vendor job writes is restored by another job);
3. appends `mise bin-paths` to `GITHUB_PATH`, so each tool runs from its own directory, with no shim and no `[env]`;
4. runs `make <targets>`.

The resolver, the `changes` job and `ci-ok` don't install anything: they start in seconds on the image's `yq` and `jq`, and log or test what they ran with (ADR 0005).

## Alternatives considered

| Option | Why not |
|---|---|
| A setup action per tool (`setup-go`, `setup-node`, `hashicorp/setup-terraform`, …) | Each version in two places, the workflow and `.mise.toml`, and a dozen actions to pin and keep current |
| The runner image's tools | Their versions change with each image update, and differ from the ones every local check runs |
| A CI image with every tool | One more image to build, scan and update, and the integration tests would need Docker inside a container |
| mise-action's defaults | They export `[env]` (`AWS_PROFILE` among it) to every step, and put the shims on PATH |
| `mise exec -- make …` | It applies `[env]` too |

## Consequences

- **Good:**
  - one place for every version: a bump in `.mise.toml` reaches CI in the same pull request;
  - CI runs the commands a developer runs;
  - a tool missing from a job's list fails loudly (`command not found`), and nothing outside `.mise.toml` sneaks in.
- **Bad / risks:**
  - **Downloads:** every job downloads its tools when the cache misses, and a job on the vendor's runners every time.
  - **Two more dependencies** to keep current: mise-action and mise itself (PR 10, Renovate or Dependabot).
  - **Each job's tool list is kept by hand** in `ci.yml`.
- **Follow-ups:** none beyond the dependency updates.

## How we'll know it was right

- The checks fail in CI only where they also fail locally on the same commit.
- If tool installs become a large share of a job's time, revisit caching (per fleet) or a CI image.
