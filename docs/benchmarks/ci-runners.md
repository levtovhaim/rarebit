# CI runner evaluation

Compares GitHub-hosted runners with Incredibuild runners for the job classes this repo will run. This first round is a **spike**: it records what each fleet offers and how it behaves on small, reproducible workloads, before any real CI exists. Later rounds (`runner-edge.yml`, Phase 2; burst, cache and compile benchmarks, Phase 8) use the real build.

## Setup

| | GitHub-hosted | Incredibuild |
|---|---|---|
| Label | `ubuntu-24.04` | `incredibuild-runner` |
| OS scope (2026-11-23) | Linux, Windows, macOS | Linux (Ubuntu x64) only; the GitHub Actions runners are in beta |
| Cost for this repo | free (public repository) | free trial (3 months) |
| Caching | none built in (`actions/cache` is opt-in) | "zero-config caching"; what it stores is not documented |

Workflow: [`.github/workflows/spike-runner.yml`](../../.github/workflows/spike-runner.yml). Every input is pinned, so both fleets do identical work:

- actions by full commit SHA; Go 1.27.4; Redis source at the commit of tag 8.10.3; base image `busybox:1.37.0` by digest
- the first run is **cold**; re-running the same workflow run gives the **warm** numbers

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

## Results

Pending: filled in from the runs of this workflow.

## Interpretation

Pending.
