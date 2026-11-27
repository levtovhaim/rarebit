# 0005. Route CI jobs to a runner fleet by job class

- **Status:** accepted
- **Date:** 2026-11-27 (proposed 2026-11-23)
- **Deciders:** @haimlevtov

## Context

The runner spike (`docs/benchmarks/ci-runners.md`, 2026-11-23, one cold and one warm run) compared GitHub-hosted runners with Incredibuild's hosted runners (beta):

- **Coverage:** Incredibuild served all three labels the Console lists: Linux x64, Linux Arm and Windows. It has no macOS runner.
- **CPU-bound builds:** about 1.9× faster on `incredibuild-ubuntu-2404` (8 vCPU vs 4). Redis `make` took 51 s vs 93 s. Incredibuild was steady across runs; GitHub-hosted varied widely (the same Go build took 14.7 s and 37.4 s).
- **Start-up:** every Incredibuild job waited about 2.5–3.5 minutes for a fresh machine (2:21–3:39 measured, once 8:38 on Arm), even on a re-run. GitHub-hosted jobs started in seconds. The policy's first runs (2026-11-27) queued 41 s and 11 s on Incredibuild: the start-up is re-measured (#67).
- **Caching:** no measurable effect from built-in caching on these small workloads. `actions/cache` worked the same on both fleets.
- **Windows:** the Incredibuild Windows runner has 8 GB RAM, vs 16 GB on GitHub-hosted.
- **Vendor status:** the runners are in beta. On 2026-11-23 the documentation and the Console differed on runner labels and OS scope; a real job settled it.
- **Credentials:** some jobs will take AWS roles through OIDC (ADR 0038): `docker` pushes images, `tf-plan` plans. The roles trust the token's `aud` and `sub`, which say nothing about whose machine asked for it, so a token minted on the vendor's runner works as well as one minted on GitHub's.

## Decision

**Jobs declare a class, and `ci/runner-policy.yaml` maps each class to a fleet per OS.** The file also holds facts: each fleet's runner label per OS (every one seen running a job) and the runner group GitHub reports for its jobs.

| Class | Linux | Windows | macOS | Why |
|---|---|---|---|---|
| `heavy-build` (long C/C++ and other large compiles) | Incredibuild | GitHub-hosted | GitHub-hosted | On Linux, 1.9× CPU outweighs the start-up past about 6–7 minutes of CPU-bound work. An MSVC build wants the 16 GB of GitHub's Windows runner more than a faster start. Incredibuild has no macOS runner |
| `docker` | GitHub-hosted | – | – | Our images build in a minute or two (an estimate, measured in #67), shorter than the start-up. Linux only: the images are Linux images. `github_only` |
| `e2e` | GitHub-hosted | GitHub-hosted | GitHub-hosted | Short browser runs on three OSes |
| `tf-plan` | GitHub-hosted | – | – | Seconds of CPU; Linux only. `github_only` |
| `light` (lint, unit tests) | GitHub-hosted | GitHub-hosted | GitHub-hosted | The start-up would be most of the job |

**The vendor fleet runs only jobs without credentials.** A class that takes an AWS role, holds a secret, builds a release or writes a cache that a trusted job reads is listed in `github_only`. Those classes run on GitHub-hosted runners whatever the overrides say, and the resolver refuses a policy that sends them elsewhere. Today that's `docker` and `tf-plan`; the tests require both.

**The resolver** (`ci/resolve-runners.sh`, in the reusable workflow `.github/workflows/_runners.yml`) turns the file into one label per class and OS. A top-level workflow calls it once and passes the labels on to its reusable workflows as an input. Every job takes its `runs-on` from there, except the resolver's own job and the runner measurements (`spike-runner.yml`, later `runner-edge.yml`), which name each fleet's labels on purpose; the tests fail on any other literal `runs-on`. Two repository variables override the policy:

1. `RUNNER_FLEET`:
   - `policy` (the default, also when unset) uses the file;
   - `github` or `incredibuild` forces that fleet for every class, on every OS where it has a runner (macOS falls back to GitHub-hosted). `RUNNER_FLEET=github` is the kill switch if the vendor degrades (`docs/runbooks/ci-runner-fallback.md`).
2. `RUNNER_LABEL`, when set, replaces the label of every Linux job. It must be one of the Linux labels in `fleets`. With `RUNNER_FLEET=github`, only a GitHub-hosted label applies, so the kill switch is always one variable.

Neither override moves a `github_only` class.

**The resolver refuses anything it doesn't know,** with exit 2:
- another `RUNNER_FLEET`, or one the file has no fleet for;
- a `RUNNER_LABEL` that isn't a known Linux label;
- a label in the file that isn't a runner label;
- a class that names a fleet or an OS without a runner;
- a `github_only` class sent elsewhere;
- more than one YAML document.

A wrong label leaves a job queued for up to a day with no error, so a loud failure is better.

**Proof:**
- `ci/test-resolve-runners.sh` checks the rules, the workflows and this table: in `make check`, with the `.mise.toml` pins, and in the `runner policy` workflow, with the runner image's own `yq` and `jq`.
- The `runner policy` workflow runs a job for every class and OS on its resolved label. Its `verify` job then checks each job's **runner group** in the jobs API, which is set on GitHub's side, unlike a runner's own name. A job still queued after 10 minutes fails it.
- It runs on pull requests that touch the policy, by hand, and weekly as a canary.

## Alternatives considered

| Option | Why not |
|---|---|
| Everything on GitHub-hosted | Simple, free for this public repo, starts in seconds. But slower and noisier on CPU-bound builds. |
| Everything on Incredibuild | About 1.9× CPU, but the per-job start-up makes short jobs slower end to end, one beta vendor becomes a single point of failure, and the vendor's machines would hold every job's credentials |
| One `RUNNER_LABEL` variable for every job | Can't send heavy and light jobs to different fleets, or pick per OS |
| Labels written in each workflow | Changing a fleet means editing every workflow, and the kill switch becomes a pull request |
| Trusting only GitHub-hosted runners in the AWS roles (the OIDC `runner_environment` claim) | Stronger: the role itself would refuse a vendor machine's token. But it changes every trust policy and the repository's OIDC subject; tracked in #62 |
| Self-hosted runners (ARC) on our own cluster | Operating burden, and the cluster is only up during work sessions; kept as a stretch option |

## Consequences

- **Good:**
  - each job runs where it finishes soonest;
  - a vendor problem is one variable change away from being contained;
  - only `heavy-build` on Linux depends on the vendor at all, and no job that holds credentials ever runs there.
- **Bad / risks:**
  - **Two fleets to monitor.**
  - **A job's class has to be right,** or it runs in the wrong place, and a class that gains credentials must join `github_only` in the same PR.
  - **The break-even rests on one spike:** roughly 6–7 minutes of CPU-bound work on a GitHub-hosted runner.
  - **The resolver adds a job of a few seconds to every workflow,** before anything else can start, on its one fixed label (`ubuntu-24.04`): if that label stopped working, every workflow would wait.
  - **CI's `yq` and `jq` come from the runner image,** not from `.mise.toml` (the image had jq 1.7 against the 1.8.2 pin). The resolver logs the versions it ran with, warns when they differ from the pins, and the tests run on the image too.
  - **Vendor caches are untrusted:** what Incredibuild's built-in cache stores, and how it's scoped, isn't documented. Until it's measured (#67), no cache a trusted job restores is written from the vendor fleet, and caches are keyed per fleet.
  - **The Incredibuild GitHub App's permissions.** It asks for repository `administration: write`, `actions: write`, `repository_hooks: write` and `statuses: write`. With those it could change rulesets and settings, add webhooks, dispatch workflows, and post commit statuses that look like passing checks. Mitigations:
    - install it on this repository only;
    - keep its runner group (`incredibuild`, the organization's settings) restricted to this repository, as it is (checked on 2026-11-27). Its workflow access is "All workflows". "Selected workflows" would let GitHub itself refuse the vendor's runners to any other workflow, but it pins workflow files at a ref, and pull request runs come from the PR's merge ref: decide it with the build workflows (#67);
    - when status checks become required, pin each one to the GitHub Actions app as its source;
    - ask the vendor whether runner registration can work with less;
    - uninstall it when the evaluation ends.
- **Follow-ups:**
  - #67: the queue-time check, `plat bench`, `runner-edge.yml` (medians of at least 5 runs, real workloads; `docker` and Windows `heavy-build` are revisited with those numbers) and the vendor cache experiment;
  - #68: the self-repository form for reusable workflow calls, once actionlint accepts it.

## How we'll know it was right

- The `runner policy` workflow shows `heavy-build` on Linux in the `incredibuild` runner group and every other class in `GitHub Actions`; with `RUNNER_FLEET=github`, all of them in `GitHub Actions`.
- Median PR lead time drops for builds routed to Incredibuild, and doesn't rise for light jobs.
- Switching `RUNNER_FLEET=github` restores CI within one run when the vendor degrades.
