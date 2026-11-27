# 0005. Route CI jobs to a runner fleet by job class

- **Status:** accepted (2026-11-27, with `ci/runner-policy.yaml` and its resolver)
- **Date:** 2026-11-23
- **Deciders:** @haimlevtov

## Context

The runner spike (`docs/benchmarks/ci-runners.md`, 2026-11-23, one cold and one warm run) compared GitHub-hosted runners with Incredibuild's hosted runners (beta):

- **Coverage:** Incredibuild served all three labels the Console lists: Linux x64, Linux Arm and Windows. It has no macOS runner.
- **CPU-bound builds:** about 1.9× faster on `incredibuild-ubuntu-2404` (8 vCPU vs 4). Redis `make` took 51 s vs 93 s. Incredibuild was steady across runs; GitHub-hosted varied widely (the same Go build took 14.7 s and 37.4 s).
- **Start-up:** every Incredibuild job waited about 2–3.5 minutes for a fresh machine (once 8.6 minutes on Arm), even on a re-run. GitHub-hosted jobs started in seconds.
- **Caching:** no measurable effect from built-in caching on these small workloads. `actions/cache` worked the same on both fleets.
- **Windows:** the Incredibuild Windows runner has 8 GB RAM, vs 16 GB on GitHub-hosted.
- **Vendor status:** the runners are in beta. On 2026-11-23 the documentation and the Console differed on runner labels and OS scope; a real job settled it.

## Decision

**Jobs declare a class, and `ci/runner-policy.yaml` maps each class to a fleet per OS.** The file also holds each fleet's runner label per OS, as facts: every label in it was seen running a job.

| Class | Linux | Windows | macOS | Why |
|---|---|---|---|---|
| `heavy-build` (long C/C++ and other large compiles) | Incredibuild | GitHub-hosted | GitHub-hosted | On Linux, 1.9× CPU outweighs the start-up past about 6–7 minutes of CPU-bound work. An MSVC build wants the 16 GB of GitHub's Windows runner more than a faster start. Incredibuild has no macOS runner |
| `docker` | GitHub-hosted | – | – | Our images build in a minute or two, shorter than the 2–3.5 minute start-up. Linux only: the images are Linux images |
| `e2e` | GitHub-hosted | GitHub-hosted | GitHub-hosted | Short browser runs on three OSes |
| `tf-plan` | GitHub-hosted | – | – | Seconds of CPU; Linux only |
| `light` (lint, unit tests) | GitHub-hosted | GitHub-hosted | GitHub-hosted | The start-up would be most of the job |

**The resolver** (`ci/resolve-runners.sh`, in the reusable workflow `.github/workflows/_runners.yml`) turns the file into one label per class and OS. Every job takes its `runs-on` from there, and no other workflow names a label. Two repository variables override it, in this order:

1. `RUNNER_LABEL`, when set, replaces the label of every Linux job, whatever the fleet.
2. `RUNNER_FLEET`:
   - `policy` (the default, also when unset) uses the file;
   - `github` or `incredibuild` forces that fleet for every class, on every OS where it has a runner (macOS falls back to GitHub-hosted). `RUNNER_FLEET=github` is the kill switch if the vendor degrades (`docs/runbooks/ci-runner-fallback.md`).

**The resolver refuses anything it doesn't know,** with exit 2: another `RUNNER_FLEET`, a `RUNNER_LABEL` that isn't a label, a class that names a fleet or an OS without a runner. A wrong label leaves a job queued with no error, so a loud failure is better.

**Proof:**
- `ci/test-resolve-runners.sh` checks the rules and this table in `make check`;
- the `runner policy` workflow runs a job for every class and OS on its resolved label, and checks from the runner's name which fleet took it.

## Alternatives considered

| Option | Why not |
|---|---|
| Everything on GitHub-hosted | Simple, free for this public repo, starts in seconds. But slower and noisier on CPU-bound builds. |
| Everything on Incredibuild | About 1.9× CPU, but the per-job start-up makes short jobs slower end to end, and one beta vendor becomes a single point of failure |
| One `RUNNER_LABEL` variable for every job | Can't send heavy and light jobs to different fleets, or pick per OS |
| Labels written in each workflow | Changing a fleet means editing every workflow, and the kill switch becomes a pull request |
| Self-hosted runners (ARC) on our own cluster | Operating burden, and the cluster is only up during work sessions; kept as a stretch option |

## Consequences

- **Good:**
  - each job runs where it finishes soonest;
  - a vendor problem is one variable change away from being contained, and light jobs never depend on the vendor at all.
- **Bad / risks:**
  - **Two fleets to monitor.**
  - **A job's class has to be right,** or it runs in the wrong place.
  - **The break-even rests on one spike:** roughly 6–7 minutes of CPU-bound work on a GitHub-hosted runner.
  - **The resolver adds a job of a few seconds to every workflow,** before anything else can start.
  - **The Incredibuild GitHub App's permissions.** It asks for repository `administration: write`, `actions: write`, `repository_hooks: write` and `statuses: write`. With those it could change rulesets and settings, add webhooks, and post commit statuses that look like passing checks. Mitigations:
    - install it on this repository only;
    - when status checks become required, pin each one to the GitHub Actions app as its source;
    - ask the vendor whether runner registration can work with less;
    - uninstall it when the evaluation ends.
  - **`RUNNER_LABEL` wins over `RUNNER_FLEET` on Linux,** so the kill switch also means clearing a `RUNNER_LABEL` that names an Incredibuild label (the runbook says so).
- **Follow-ups:**
  - `runner-edge.yml` repeats the measurements with medians of at least 5 runs and real workloads; `docker` and Windows `heavy-build` are revisited with those numbers;
  - burst and cache experiments run later;
  - the CI queue-time check comes with `plat bench`.

## How we'll know it was right

- The `runner policy` workflow shows `heavy-build` on Linux on an `Incredibuild-run-<id>` runner and every other class on GitHub-hosted runners; with `RUNNER_FLEET=github`, all of them on GitHub-hosted.
- Median PR lead time drops for builds routed to Incredibuild, and doesn't rise for light jobs.
- Switching `RUNNER_FLEET=github` restores CI within one run when the vendor degrades.
