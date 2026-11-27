# CI runner evaluation

Compares GitHub-hosted runners with Incredibuild runners for the job classes this repo will run. This first round is a **spike**: it records what each fleet offers and how it behaves on small, reproducible workloads, before any real CI exists. Later rounds use the real build: `runner-edge.yml` (next, now that the runner policy `ci/runner-policy.yaml` exists; #67), and after it burst, cache and compile benchmarks.

## Setup

| | GitHub-hosted | Incredibuild |
|---|---|---|
| Label compared | `ubuntu-24.04` | `incredibuild-ubuntu-2404` |
| OS scope (2026-11-23) | Linux (x64, Arm), Windows, macOS | Docs and the Console banner: Linux (Ubuntu x64), beta. The Console's label table also lists Arm and Windows (below). The `probe` job checks which runners exist. |
| Cost for this repo | free (public repository) | free trial (3 months) |
| Caching | none built in (`actions/cache` is opt-in) | "zero-config caching"; what it stores is not documented |

Label mapping shown by the Incredibuild Console on 2026-11-23. The docs page still shows a single `incredibuild-runner` label, which no runner served for this repository.

| GitHub-hosted | Incredibuild |
|---|---|
| `ubuntu-latest` | `incredibuild-ubuntu-latest` |
| `ubuntu-24.04` | `incredibuild-ubuntu-2404` |
| `ubuntu-22.04` | `incredibuild-ubuntu-2204` |
| `ubuntu-24.04-arm` | `incredibuild-ubuntu-2404-arm` |
| `windows-2022` | `incredibuild-windows-2022` |

Workflow: [`.github/workflows/spike-runner.yml`](../../.github/workflows/spike-runner.yml). Every input is pinned, so both fleets do identical work:

- actions by full commit SHA; Go 1.27.4; Redis source at the commit of tag 8.10.3; base image `busybox:1.37.0` by digest
- the first run is **cold**; re-running the same workflow run gives the **warm** numbers
- it runs **on demand only**: Actions → runner-spike → Run workflow, or `gh workflow run spike-runner.yml`. It no longer runs on pull requests that edit it.
- removing that trigger isn't what keeps outside code off the vendor's runners. A fork pull request runs the fork's own workflow files, so it can add a trigger or a new workflow with an `incredibuild-*` label. The control is the repository setting that requires approval before workflows run for external contributors. Before approving such a run, check its `.github/workflows/` changes and `runs-on` labels.
- the results below were measured with `actions/setup-go` v7.0.0; a re-run's job log shows which version it used

## What is measured

| Metric | What it shows |
|---|---|
| machine facts, tool inventory | CPU count and model, memory, disk, preinstalled tools (Docker, compilers, CMake, Go, Node, cloud CLIs) |
| egress timings, `download_MBps` | DNS/TLS/total time to package registries and AWS endpoints in eu-central-1; download throughput |
| `go_std_cold` | `go build -a std` with an empty build cache: pure CPU and disk |
| `go_std_with_actions_cache` | the same build with a build cache restored by `actions/cache` (a hit on the warm run) |
| `redis_fetch`, `redis_make` | a shallow fetch and a `make -j$(nproc)` C build |
| `docker_build_first`, `docker_build_second` | an image build, then the same build again (the local layer cache) |
| queue time, job duration | from the GitHub API (`created_at` → `started_at` → `completed_at`) |
| `probe` job | whether the Arm and Windows labels are served, and the OS/CPU/memory/tools of each runner, next to its GitHub-hosted counterpart |

## Results

**Run conditions:** 2026-11-23, workflow run [45210393224](https://github.com/levtovhaim/rarebit/actions/runs/45210393224) on the [PR #1](https://github.com/levtovhaim/rarebit/pull/1) branch (squash-merged, so that commit isn't on `main`): attempt 1 (cold) and attempt 2 (warm, the same commit re-run). That's one run per condition, so the numbers are indicative, not statistically solid.

### Runners

| Label | OS | CPU | vCPU | RAM | Root/work disk |
|---|---|---|---|---|---|
| `ubuntu-24.04` | Ubuntu 24.04.5 | Intel Xeon 6975P-C | 4 | 15 GiB | 145 GB |
| `incredibuild-ubuntu-2404` | Ubuntu 24.04.4 | AMD EPYC | 8 | 15 GiB | 95 GB (overlay) |
| `ubuntu-24.04-arm` | Ubuntu 24.04.5 | Neoverse-N2 | 4 | 15 GiB | 145 GB |
| `incredibuild-ubuntu-2404-arm` | Ubuntu 24.04.5 | Ampere-1a | 4 | 15 GiB | 95 GB (overlay) |
| `windows-2022` | Windows Server 2022 Datacenter | AMD EPYC 9V74 | 4 | 16 GB | 220 GB (D:) |
| `incredibuild-windows-2022` | Windows Server 2022 Standard | AMD EPYC-v4 | 4 | 8 GB | 100 GB (D:) |

All three Incredibuild labels were served, Arm and Windows included. Both Linux x64 images ship the same preinstalled tools (Docker 28.0.4, gcc 13.3, clang 18, CMake 3.31.6, Ninja 1.13.2, Node 22, Python 3.12, aws-cli, kubectl, helm), with the Incredibuild image a few releases behind (git 2.54 vs 2.56, aws-cli 2.35 vs 2.40). Neither has Terraform.

### Queue time (job created → started)

| Label | Cold | Warm |
|---|---|---|
| `ubuntu-24.04` | 3 s | 2 s |
| `incredibuild-ubuntu-2404` | 3 min 30 s | 2 min 33 s |
| `ubuntu-24.04-arm` | 4 s | 4 s |
| `incredibuild-ubuntu-2404-arm` | 8 min 38 s | 2 min 33 s |
| `windows-2022` | 2 s | 2 s |
| `incredibuild-windows-2022` | 3 min 39 s | 2 min 21 s |

Later samples, from the runner policy's proof workflow (one no-op job each, so not yet a measurement): `incredibuild-ubuntu-2404` queued **41 s** (run 45956498946, 2026-11-27 07:09Z) and **11 s** (run 45958010438, 07:22Z). That's far below the spike's start-up; `runner-edge.yml` re-measures it with medians (#67).

The first real checks (`ci.yml` on pull request #71, run 46008430705, 2026-11-27 13:35Z; one sample, so not a median):

| Job | Fleet | Queued | Ran (install + make) |
|---|---|---|---|
| `heavy-build on linux` (runner policy probe, run 46008430662) | Incredibuild | 6 min 58 s | 3 s |
| `validator` (`make validator validator-integration`) | Incredibuild | 7 min 56 s | 50 s |
| `native` (`make native`) | Incredibuild | 13 min 54 s | 18 s |
| `lint` (`make check`) | GitHub-hosted | 2 s | 41 s |
| `infra`, `game`, `bots`, `web` | GitHub-hosted | 2–3 s | 67 s, 61 s, 100 s, 12 s |

- The three Incredibuild jobs, queued within 4 seconds of each other, started one after another: the probe at 13:42:39, `validator` at 13:43:41 (just after the probe finished), `native` at 13:49:39. Each job had its own runner (runner IDs 24, 25 and 37), so this run shows no machine reused between jobs. It does look like one machine at a time, possibly a trial limit; that's not confirmed (#67).
- A runner's name, `Incredibuild-run-<job ID>`, is the ID of the job it was started for, not of the job it ran: `validator` ran on the runner named after `native`'s job.
- Both checks are far below the break-even: under a minute of work each, behind 8–14 minutes of queue. #67 settles their class with medians.

### Linux x64 measurements (seconds unless noted)

| Metric | GitHub, cold | GitHub, warm | Incredibuild, cold | Incredibuild, warm |
|---|---|---|---|---|
| `go_std_cold` (empty cache) | 14.7 | 37.4 | 7.7 | 8.0 |
| `go_std_with_actions_cache` | 0.2 ¹ | 0.3 | 6.8 (cache miss) | 0.3 |
| `redis_fetch` | 1.0 | 1.5 | 1.2 | 1.2 |
| `redis_make` | 92.5 | 110.1 | 51.3 | 46.4 |
| `docker_build_first` | 1.1 | 4.0 | 2.0 | 2.2 |
| `docker_build_second` | 0.1 | 0.3 | 0.2 | 0.2 |
| `download_MBps` (MB/s) | 184.1 | 137.8 | 118.1 | 122.6 |
| job runtime (started → completed) | 2:39 | 3:07 | 2:16 | 1:53 |
| end to end (created → completed) | 2:42 | 3:09 | 5:46 | 4:26 |

¹ It restored a cache saved by an earlier, cancelled run of the same workflow, so this is a warm number.

Egress, from the cold run:
- latency to github.com: 0.03 s on GitHub-hosted, 0.21 s on Incredibuild
- TCP connect to AWS eu-central-1: 94 ms and 102 ms, so both fleets run far from Frankfurt

## Interpretation

1. **CPU-bound work runs about 1.9× faster on Incredibuild in this sample**, in line with its 8 vCPUs vs 4. The speedup comes from a bigger machine; nothing was cached between runs. Incredibuild was steady across runs (7.7 / 8.0 s; 51.3 / 46.4 s), while GitHub-hosted varied a lot (14.7 / 37.4 s for the same build). Compare medians of several runs, never single GitHub runs.
2. **Every Incredibuild job pays a start-up of about 2.5–3.5 minutes** (8.6 minutes seen once on Arm), even on a re-run. Each job gets a fresh machine. GitHub-hosted jobs start in seconds.
3. **Break-even is long jobs.** At about 1.9× speed and about 3 minutes of start-up, a job needs roughly 6–7 minutes of CPU-bound work on a 4-vCPU GitHub-hosted runner before Incredibuild finishes first. Shorter jobs finish sooner on GitHub-hosted.
4. **The built-in caching showed no measurable effect on these workloads.** Docker layers were not reused across runs, the Redis build changed within run-to-run noise, and the Go build was unchanged without `actions/cache`. `actions/cache` worked the same on both fleets. Larger, dependency-heavy builds may behave differently, so the next round measures real workloads.
5. **The Windows runner has half the RAM** of the GitHub-hosted one (8 vs 16 GB). Memory-hungry builds (MSVC with many parallel jobs) need checking before routing them there.
6. **Network:** lower download throughput and higher latency to github.com on Incredibuild.

**Input for the runner policy** (decided on 2026-11-27 in [ADR 0005](../adr/0005-ci-runner-fleets-by-job-class.md) and [`ci/runner-policy.yaml`](../../ci/runner-policy.yaml): `heavy-build` on Linux to Incredibuild, everything else to GitHub-hosted; the proposal was):
- long C/C++ and other heavy compiles (`heavy-build`) → Incredibuild
- `light`, `tf-plan` and short `e2e` jobs → GitHub-hosted
- `docker` → decided after measuring real images

**Limits of this round:** one run per condition; noisy GitHub-hosted performance; a tiny Docker workload; no dependency-heavy cache test yet. The next round, `runner-edge.yml`, repeats this with at least 5 runs per runner (medians) and real workloads.
