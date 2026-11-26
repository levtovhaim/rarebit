# 0036. One private ECR repository per service image, with immutable tags and lifecycle rules

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- Four images exist: `validator`, `game`, `web` and `bots`. CI will build them on every PR and on `main`, tagged `pr-<number>-<sha7>` and `main-<sha7>` (CLAUDE.md → Conventions), and the cluster will pull them.
- Environments pin images by tag in `deploy/envs/*/image-tags.yaml`. A tag that changed meaning, or an image that disappeared, would break a deployment that looks unchanged in git.
- The registry must not grow forever: every PR push adds an image.

## Decision

- **One private ECR repository per service:** `rarebit/validator`, `rarebit/game`, `rarebit/web`, `rarebit/bots`, in eu-central-1, from `infra/live/_global/ecr`.
- **Immutable tags.** A tag names one image forever. CI checks whether a tag exists before building, because a second push of the same tag fails.
- **Scan on push** with basic scanning, which is free. The CI build also runs Trivy before the push and fails on fixable HIGH or CRITICAL findings.
- **AES256 encryption** with the key ECR manages. A customer-managed KMS key would cost $1/month plus requests, and add a key policy. IAM on the CI and node roles already decides who pushes and pulls.
- **Lifecycle rules, the same on every repository:**
  - PR images expire 3 days after they're pushed;
  - untagged images (layers left behind by multi-arch builds or failed pushes) expire after 1 day;
  - the newest 15 `main-` images are kept.
- **What an environment runs must never expire.** Promotion only uses `main-` tags. An environment must not stay more than 15 `main` builds behind: if it does, its tag expires, and the next pod on a new node fails with `ImagePullBackOff`. The runbook covers it.
- **`force_delete = false`**, and `_global` units can't be destroyed by Terragrunt (the `exclude` block in `root.hcl`).

## Alternatives considered

| Option | Why not |
|---|---|
| One shared repository, services told apart by tag prefix | IAM can't give a service's pipeline push rights to its own images only, and the lifecycle counts would mix services |
| Mutable tags (`latest`, `main`) | A deployment pinned to a tag could change without a commit; rollback would mean "whatever the tag points at now" |
| Enhanced scanning (Amazon Inspector) | Continuous rescans and OS plus language package findings, but billed per image per month; Trivy in CI covers the build-time check for now |
| GitHub Container Registry | No IAM for the cluster's nodes: pulls would need a token as a Kubernetes secret, and the public repo's packages would need care to stay private |
| Keep everything, no lifecycle | Storage grows with every PR push |

## Consequences

- **Good:**
  - a tag is a fixed reference that can't be overwritten;
  - IAM can scope push and pull per repository;
  - storage stays small without anyone cleaning up.
- **Bad / risks:**
  - **A long-lived PR's images expire after 3 days.** Its preview environment then needs a new push (a rebuild) before pods can be rescheduled.
  - **An environment more than 15 `main` builds behind loses its image.** Promotion has to keep up, or the rule changes.
  - **Pulls from Docker Hub** (the build's base images) are still anonymous and rate-limited. An ECR pull-through cache comes in its own PR: it needs a Docker Hub access token stored in Secrets Manager.
- **Follow-ups:** the CI roles' push rights per repository (the GitHub OIDC PR); the pull-through cache; checking image digests in deploy values once Argo CD runs.

## How we'll know it was right

- Pushing an existing tag fails with `ImageTagAlreadyExistsException`.
- After a few days of PRs, `aws ecr describe-images` shows no `pr-` image older than 3 days and at most 15 `main-` images per repository.
- No `ImagePullBackOff` caused by an expired image.
