# 0044. CI installs the tools pinned in .mise.toml with a hash-checked mise, puts them on PATH without mise's [env], and restores no cache

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- `.mise.toml` pins every tool's version, for every machine, agent and CI job (ADR 0003). The checks are `make` targets (CLAUDE.md → Commands). CI has to run the same commands with the same versions, or a check can pass locally and fail in CI.
- The runner images bring their own tools, and those change with every image update: the policy's first runs found jq 1.7 on the image, against 1.8.2 in `.mise.toml` (ADR 0005). Both fleets' images also ship CMake, Ninja, Node.js and Python (`docs/benchmarks/ci-runners.md`).
- `.mise.toml` also sets `[env]` for people's machines: `AWS_PROFILE=rarebit`, `AWS_REGION` and Terragrunt's cache directories.
- A mise shim applies `[env]` to every tool it starts. Checked in WSL on 2026-11-27: run through its shim, `jq` saw `AWS_PROFILE=rarebit`; run from the directory `mise bin-paths` lists, it saw no `AWS_PROFILE`. In CI, a job that takes an AWS role through OIDC would then have its tools look for a profile that doesn't exist on the runner.
- `jdx/mise-action` would install mise and the tools, but:
  - the repository's Actions policy allows GitHub's own actions only (`patterns_allowed: []`, read back on 2026-11-27);
  - by default it exports `[env]` to every later step, and puts the shims on PATH;
  - its cache setting doesn't stop a job from writing cache entries.
- **The Actions cache can't be trusted while a vendor runs jobs.** Any job holds a runtime token that can write cache entries for its ref. A job on Incredibuild's runners in a run on `main` can write entries that every pull request's jobs would restore, whatever a workflow file says (the security review of this change, from mise-action's source). The cache keys are predictable. ADR 0005 kept vendor jobs from *using* the cache, and that isn't enough.

## Decision

**CI jobs run `make` through the reusable workflow `.github/workflows/_make.yml`**, with the job's class (ADR 0005), its tools and its targets as inputs. The workflow:

1. checks out the repository, without persisted credentials;
2. downloads the mise release (2026.11.10, the newest release at least 7 days old) from GitHub and checks it against the SHA-256 written in the workflow (the release's `SHASUMS256.txt` entry, checked against a download), before running it;
3. installs only the job's tools, by their names in `.mise.toml`, into the job's temporary directory, which the runner empties after the job;
4. appends `mise bin-paths` to `GITHUB_PATH`, so each tool runs from its own directory, with no shim and no `[env]`;
5. runs `make <targets>`.

**No job restores anything from the Actions cache.** Tools are downloaded again for every job, until #67 has measured the vendor's runners. The tests fail on any workflow that uses `actions/cache`, a `setup-*` action or mise-action, except the runner measurements (`spike-runner.yml`), whose caches only they read.

**`_make.yml` never gets `id-token: write`.** A job that takes an AWS role (image pushes, plans) gets its own workflow, with as few tools as it can do with. A test enforces the rule for `_make.yml`.

The resolver, the `changes` job and `ci-ok` don't install anything: they start in seconds on the image's `yq` and `jq`, and their tests also run on the image (ADR 0005, ADR 0043).

## Alternatives considered

| Option | Why not |
|---|---|
| `jdx/mise-action` | The repository's Actions policy would need a third-party exception. Its JavaScript would run in every job, the jobs that will take AWS roles included. Its cache, the one thing it adds, can't be trusted while vendor jobs run (above) |
| A setup action per tool (`setup-go`, `setup-node`, `hashicorp/setup-terraform`, …) | Each version in two places, the workflow and `.mise.toml`, and a dozen actions to allow, pin and keep current |
| The runner image's tools | Their versions change with each image update, and differ from the ones every local check runs |
| A CI image with every tool | One more image to build, scan and update, and the integration tests would need Docker inside a container |
| `mise exec -- make …`, or mise's shims | They apply `[env]` (`AWS_PROFILE` among it) to every tool |
| The Actions cache for GitHub-hosted jobs only | It stops honest vendor jobs, but not a vendor runner that's compromised: its token can still write the entries GitHub-hosted jobs would restore |

## Consequences

- **Good:**
  - one place for every version: a bump in `.mise.toml` reaches CI in the same pull request;
  - CI runs the commands a developer runs;
  - no third-party action in the jobs, and nothing a vendor runner wrote is ever run by another job.
- **Bad / risks:**
  - **No cache:** every job downloads its tools. In the rehearsal in WSL on 2026-11-27, the lint job's 18 tools installed in 27 s, and go, cmake and ninja in 11 s.
  - **A tool missing from a job's list isn't always loud.** If the runner image has its own copy (CMake, Ninja, Node.js, Python, jq, yq), that copy runs instead, at its own version. The install step prints the versions it installed.
  - **mise's version and its hash are pinned by hand,** in `_make.yml` and apart from `.mise.toml`'s `min_version`. A bump changes both lines (#70). The hash covers Linux x64 only; another OS or architecture fails until its hash is added.
  - **Tools that resolve their own dependencies at install time** aren't pinned beyond their own version: the Python packages behind `pipx:yamllint` and the `pre-commit-hooks` environment (#70).
- **Follow-ups:**
  - #70: dependency automation, `mise.lock`, and the transitive Python pins;
  - #67: the vendor's runners and caches, measured.

## How we'll know it was right

- The checks fail in CI only where they also fail locally on the same commit.
- If tool installs become a large share of a job's time, revisit caching once #67 has answered who can write to it.
