# 0043. Pull requests run lint and the checks their changes need, summed up in one check, ci-ok

- **Status:** accepted; adds the class `gate` to ADR 0005's `github_only`
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- Until now no workflow ran the repository's checks: every `make` target in CLAUDE.md → Commands was run by hand before a merge.
- The repository holds six areas in four languages (C++, Go, TypeScript, Terraform), plus docs and data. Most pull requests touch one of them. Running every check on every pull request means compiling C++ and Go, three Node.js apps with their Redis tests and every Terraform module, even for a docs fix, and an Incredibuild start-up for each `heavy-build` job (ADR 0005).
- GitHub's required status checks are listed by name in the `main` ruleset:
  - a check from a workflow that didn't run (a `paths:` filter) stays "expected" forever and blocks the merge;
  - a job that was skipped counts as passed;
  - each new required job is a ruleset change, which only an admin can make.
- So picking checks by path and requiring them by name don't mix: a check that wasn't needed is either missing (blocked forever) or skipped (passed, also when it was skipped because something broke). Picking by path needs one check that knows which checks were needed and sums them up. That's why this is one decision: the picker and the summary check only work together.
- A pull request runs its own version of the workflow and of the scripts it calls.

## Decision

**One workflow, `.github/workflows/ci.yml`, runs on every pull request, the merge queue, pushes to `main` and by hand on `main`.**

- **Lint (`make check`) runs every time.**
- **Each other check runs when the change touches a path it covers.** `ci/checks.yaml` lists the checks (`infra`, `native`, `validator`, `game`, `web`, `bots`), each with its paths. A path ending in `/` covers a directory, any other path covers one file, and there are no globs. The known dependencies between areas are lines of their own:
  - `native` and the validator read the word lists;
  - the validator links `native/`;
  - a web test reads the game's list of error codes;
  - the bots run the game servers.
- **The `changes` job picks the checks** with `ci/changed-checks.sh`:
  - A pull request's checkout is GitHub's merge commit, so the job diffs it against its first parent, the base branch: exactly what merging would change.
  - Renames count as a delete plus an add, so moving a file out of a check's paths still runs that check.
  - A change to anything under `all` runs every check. That covers the CI wiring (`ci.yml`, every workflow it calls, `ci/`) and what every check runs with (`.mise.toml`, the `Makefile`).
  - The merge queue, `main` and manual runs run every check. The queue is the last gate, and runs everything that's merging together.
  - A manual run on any branch but `main` fails: its `ci-ok` would land on a pull request's head commit, checked without the merge with its base.
- **`ci-ok` waits for every other job and decides** (`ci/ci-ok.sh`). It passes only when:
  - each job every run needs (the resolver, `changes`, the gate tests, lint) succeeded;
  - each picked check succeeded;
  - each check that wasn't picked was skipped, or passed.
- **`ci-ok` fails closed:**
  - **Unknown picks:** outside a pull request, or when the picked checks are unknown (the `changes` job failed, or its output is missing), every check counts as picked.
  - **Unknown jobs:** if a check, or a picked name, isn't a job `ci-ok` waits for, it fails. So does a job result it doesn't know.
  - **Cancelled runs:** it runs with `if: always()`, so it still runs, and fails, when the run is cancelled.
  - **No resolver:** if the resolver failed, `ci-ok`'s `runs-on` expression has no label and the job fails. That one isn't a test case: the first live run checks it on purpose (`docs/runbooks/ci-checks.md`).
- **The jobs that decide run in the class `gate`,** which is in `github_only` (ADR 0005): `changes`, `ci-ok`, and a job that runs their scripts' tests on the runner image's `yq` and `jq`. Neither `RUNNER_FLEET` nor `RUNNER_LABEL` can move the merge decision onto a vendor's runner.
- **`native` and `validator` are `heavy-build`, for now:** they're the compile-bound checks, so on Linux they run on Incredibuild. Whether they're past ADR 0005's break-even isn't measured yet. Their durations go into `docs/benchmarks/ci-runners.md`, and #67 settles the class.
- **The ruleset will require only `ci-ok`,** with GitHub Actions as its source (#69).
- **The scripts are tested in `make check`:**
  - `ci/test-changed-checks.sh` covers the picker's rules. It also checks:
    - every check is a job in `ci.yml` that runs only when picked;
    - `ci-ok` waits for every job, and no other workflow has a job called `ci-ok`;
    - the gate jobs are class `gate`;
    - every path in the file exists, and the known dependencies between areas are covered;
    - every workflow `ci.yml` runs is under `all`;
    - no job there may fail without failing (`continue-on-error`).
  - `ci/test-ci-ok.sh` is the specification of `ci-ok`.
- **A pull request runs its own `ci.yml` and `ci/`.** A change there is caught in review: `.github/` and `ci/` have code owners. Approval isn't enforced yet (CLAUDE.md → Review, #69).

## Alternatives considered

| Option | Why not |
|---|---|
| Every check on every pull request | Nothing to pick, so nothing to get wrong. But every pull request pays for every compile and integration test, and for Incredibuild start-ups, a docs fix included |
| A `paths:` filter per workflow | A required check from a workflow that didn't run stays expected forever, so the merge is blocked. The usual workaround is a second, no-op workflow with the same check names |
| A path-filter action (`dorny/paths-filter` and similar) | Another third-party action that reads every pull request, with its own glob rules. The picker is one tested script with plain path prefixes |
| Requiring each job by name in the ruleset | Every new check is an admin's ruleset change. And a skipped job counts as passed, so a check skipped because `changes` broke would pass |
| A build-graph tool (Bazel, Nx, Turborepo) | It works out what's affected from the build graph, but it's a build system to adopt in four languages, for six areas |
| The gate jobs in class `light` | `RUNNER_FLEET=incredibuild` or a vendor `RUNNER_LABEL` would move them to the vendor's runners, which could then pick no checks, or pass `ci-ok` |

## Consequences

- **Good:**
  - a docs-only pull request runs lint alone;
  - one check to require: a new check is a line in `ci/checks.yaml`, a job in `ci.yml` and an entry in `ci-ok`'s `needs`, with no ruleset change;
  - each way the run can go wrong (a failed `changes` job, a cancel, a skipped check, a missing job) fails `ci-ok`, and the tests cover each one; the failed resolver is checked live.
- **Bad / risks:**
  - **The map is kept by hand.** An area that depends on another without a line in `ci/checks.yaml` has a check that doesn't run. To limit that:
    - the paths err on the side of more checks;
    - a change to the wiring runs everything;
    - the tests fail on a path that doesn't exist, or a known dependency that's gone;
    - `main` runs every check after each merge, and the merge queue will run them all before it, once it's on (#69).
  - **The checks are only as good as the pull request's own `ci.yml` and `ci/`,** until review is enforced (#69).
  - **The merge queue and `main` run everything,** so they're slower than a pull request, and `main` also runs both vendor jobs after a docs-only merge. Narrowing pushes to `main` waits for the merge queue.
  - **A retargeted pull request keeps its older `ci-ok`:** a base change alone doesn't start a run, so the checks against the new base wait for the next push, or the merge queue.
- **Follow-ups:**
  - #69: require `ci-ok` from GitHub Actions, the merge queue, and code-owner review of the CI wiring;
  - image builds and pushes, the first workflow that takes an AWS role (#62, "The CI build PR");
  - #67: `native` and `validator` against the break-even, and the `incredibuild` runner group's workflow access, now that a build workflow uses it.

## How we'll know it was right

- No pull request merges with a check broken because its paths weren't in `ci/checks.yaml`. If one does, add the path, and reconsider running everything.
- Docs-only and single-area pull requests finish in a few minutes, not the time of the whole suite.
