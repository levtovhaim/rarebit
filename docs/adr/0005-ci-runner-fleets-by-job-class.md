# 0005. Route CI jobs to a runner fleet by job class

- **Status:** proposed (accepted when `ci/runner-policy.yaml` is implemented)
- **Date:** 2026-11-23
- **Deciders:** @haimlevtov

## Context

The runner spike (`docs/benchmarks/ci-runners.md`, 2026-11-23, one cold and one warm run) compared GitHub-hosted runners with Incredibuild's hosted runners (beta):

- **Coverage:** Incredibuild served all three labels the Console lists: Linux x64, Linux Arm and Windows.
- **CPU-bound builds:** about 1.9× faster on `incredibuild-ubuntu-2404` (8 vCPU vs 4). Redis `make` took 51 s vs 93 s. Incredibuild was steady across runs; GitHub-hosted varied widely (the same Go build took 14.7 s and 37.4 s).
- **Start-up:** every Incredibuild job waited about 2–3.5 minutes for a fresh machine (once 8.6 minutes on Arm), even on a re-run. GitHub-hosted jobs started in seconds.
- **Caching:** no measurable effect from built-in caching on these small workloads. `actions/cache` worked the same on both fleets.
- **Windows:** the Incredibuild Windows runner has 8 GB RAM, vs 16 GB on GitHub-hosted.
- **Vendor status:** the runners are in beta. On 2026-11-23 the documentation and the Console differed on runner labels and OS scope; a real job settled it.

## Decision

Jobs declare a class, and `ci/runner-policy.yaml` maps each class to a runner label per OS:

| Class | Fleet |
|---|---|
| `heavy-build` (long C/C++ and other large compiles) | Incredibuild |
| `light`, `tf-plan`, short `e2e` | GitHub-hosted |
| `docker` | decided after measuring real images |

Overrides:
- `RUNNER_FLEET` (`policy` | `github` | `incredibuild`) forces one fleet. It's the kill switch if the vendor degrades, with a runbook and a queue-time alert.
- `RUNNER_LABEL` overrides Linux jobs only.

## Alternatives considered

| Option | Why not |
|---|---|
| Everything on GitHub-hosted | Simple, free for this public repo, starts in seconds. But slower and noisier on CPU-bound builds. |
| Everything on Incredibuild | About 1.9× CPU, but the per-job start-up makes short jobs slower end to end, and one beta vendor becomes a single point of failure |
| Self-hosted runners (ARC) on our own cluster | Operating burden, and the cluster is only up during work sessions; kept as a stretch option |

## Consequences

- **Good:** each job runs where it finishes soonest. A vendor problem is one variable change away from being contained.
- **Bad / risks:**
  - two fleets to monitor
  - a job's class has to be right, or it runs in the wrong place
  - the break-even (roughly 6–7 minutes of CPU-bound work on a GitHub-hosted runner) rests on one spike
- **Follow-ups:** `runner-edge.yml` repeats the measurements with medians of at least 5 runs and real workloads; burst and cache experiments run later.

## How we'll know it was right

- Median PR lead time drops for builds routed to Incredibuild, and doesn't rise for light jobs.
- Switching `RUNNER_FLEET=github` restores CI within one run when the vendor degrades.
