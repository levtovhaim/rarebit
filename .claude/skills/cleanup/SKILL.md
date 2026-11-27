---
name: cleanup
description: >-
  Use this skill for code review and cleanup tasks in this repo. Invoke it when the user wants to
  inspect code quality, clean something up before merging, audit a file or folder for issues, or
  get a pre-merge review of local changes, a branch, or an open PR: "review this", "clean this
  up", "look for dead code", "flag anything that needs fixing", "review before I merge",
  "review PR #N", or "have a look at [file/chart/workflow/module]". Do NOT invoke for: adding
  features, fixing a specific known bug, explaining code, running tests or builds, or writing
  documentation.
---

Review code for REAL problems and present a cleanup plan. Never invent work: a clean file gets
"looks clean", not padding. Do NOT change anything until the user approves the plan (exception:
when the user already ordered a review-then-act workflow, e.g. "review each PR, then fix it", the
review verdict gates that action, with no separate approval round).

`CLAUDE.md` wins over anything stated here. Before adding a rule to this skill, check that the
thing it names exists in the repo.

## Phase 1: Determine scope

- Named file → that file. Named directory → its files, plus whatever composes them: the Argo CD
  Application or ApplicationSet that deploys a chart, the workflow that calls a reusable workflow,
  the Terragrunt unit that calls a module.
- A PR → `gh pr diff N` and `gh pr checks N`. A branch, or no scope given →
  `git diff origin/main...HEAD --name-only`; if that's empty, ask rather than guess.

## Phase 2: Scan

**Delegate when the scope is a diff, a PR, or more than about 5 files.** Dispatch the reviewer
subagents in `.claude/agents/` in parallel and fold their findings into the plan:

| Agent | Dispatch when the scope touches |
|---|---|
| `security-reviewer` | `infra/`, `.github/`, `deploy/`, `platform/policies/`, or anything with IAM, OIDC, RBAC, secrets, images or network exposure |
| `resilience-reviewer` | `apps/game`, `apps/validator`, `apps/bots`, `deploy/charts/`, `platform/cli/` (env up/down), or anything with drain, retries, reconnects or teardown order |
| `auditor` | `infra/`, `.github/`, `deploy/`, `platform/`: cost, IaC and GitOps hygiene. Its CRITICAL and HIGH findings are fixed or waived with a written reason. |
| `convention-compliance-reviewer`, on a cheaper model (`model: sonnet`) | every diff. Tell it to also run the `docs-sync-reviewer` checklist (`.claude/agents/docs-sync-reviewer.md`): one agent checks both the rules and conventions and the Documentation Map in `CLAUDE.md` |

**One review round per PR,** and it comes before anything that's costly to repeat:
- **Self-check first.** Before dispatching anyone, fix what reviews keep finding:
  - a doc the Documentation Map couples to the change;
  - a number without its source;
  - an ADR with more than one decision;
  - a runbook missing a section of `docs/runbooks/_template.md`;
  - a deferral without a linked issue;
  - a claim written as true before it is;
  - a new rule without a negative control.
- **Then review once,** before any AWS apply or live run, so all the fixes land in one apply and one verification.
- **No new round for follow-ups:** none for a docs-only change or for a small fix a live run turns up, unless it changes security-relevant behavior.

For small scopes, check directly, in this order.

**1. Contributor rules (`CLAUDE.md` → Rules). These outrank style.**
- Loose pinning: an action by tag instead of full SHA, an image by tag instead of digest, an
  unpinned Terraform provider, module or Helm chart
- A secret, key or token in git; a static AWS key anywhere in CI
- A NAT Gateway, a new load balancer, an AWS resource outside provider `default_tags`, an EKS
  version in extended support
- A service missing part of the runtime contract: `/healthz`, `/readyz` (false while draining),
  `/metrics`, `/version`; JSON logs to stdout; config validated at startup; graceful drain on
  the image's stop signal (SIGTERM, or SIGQUIT for nginx); non-root with a read-only root
  filesystem
- A copy-pasted pipeline or chart instead of `.github/workflows/_*.yml` or `deploy/charts/service`
- An infra-changing command run instead of proposed in the PR for a human to run

**2. Dead code and hygiene**
- Unused imports, symbols, Helm values, Terraform variables or outputs
- Unreachable code and commented-out blocks
- Debug leftovers (`console.log`, `fmt.Println`, `set -x`) where the service should log JSON
- TODO/FIXME without a linked issue
- Comments that restate the code, or went stale against it

**3. Stack conventions (`CLAUDE.md` → Conventions)**
- Config comes from env vars and is validated at startup; no hardcoded hosts, ports or credentials
- Image tags are `pr-<number>-<sha7>` or `main-<sha7>`; nothing deploys `:latest`
- Kubernetes objects carry `app.kubernetes.io/name`, `app.kubernetes.io/part-of=rarebit`, `owner`
  and `tier`
- Chart values validate against `deploy/charts/service/values.schema.json`
- Terraform modules have `README.md`, `examples/basic`, `versions.tf` and tests in `tests/`
  against a mocked provider; live config lives only in `infra/live`
- Tests: table-driven in Go; vitest for game and bots
- Player-facing strings are Hebrew (RTL); code, comments and docs are English
- LF line endings

## Phase 3: Plan

Present findings **before making any changes**, grouped by file:

```
## Cleanup Plan

### [filename]
- [ ] Issue — proposed fix (be specific: name the symbol, line, or pattern)

### Nothing to do
- [file] — looks clean
```

If there is genuinely nothing worth fixing, say so clearly and stop, with no approval question.

When the plan HAS items, end with: **"Shall I apply all of these, or pick specific items?"**

## Phase 4: Execute (only after approval)

- Apply ONLY approved items. No refactoring beyond them, no comments or annotations on code you
  didn't change, no placeholder files, no error handling for scenarios that can't happen.
- Verify, and quote the output rather than asserting it passed:

  ```
  make check
  ```

  Add `make smoke` when app behavior changed, and `helm template`, `terraform validate` or
  `tflint` for the charts and modules you touched.
- Never verify with an infra-changing command (`CLAUDE.md` → Rules, rule 2).
- Leave nothing running. If you started docker compose or a kind cluster to check something, stop
  it in the same turn (`make down`, `make kind-down`).

## Doc coupling

The Documentation Map in `CLAUDE.md` is the contract, and the `docs-sync-reviewer` checklist enforces it. For
small scopes, check it directly: a doc that should have changed in the same diff and didn't is a
finding.
