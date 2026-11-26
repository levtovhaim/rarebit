# 0036. Private ECR repositories per service, separate for main and PR images, with immutable tags and lifecycle rules

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- Four images exist: `validator`, `game`, `web` and `bots`. The CI build workflow (not written yet) will build them on every PR and on `main`, tagged `pr-<number>-<sha7>` and `main-<sha7>` (CLAUDE.md → Conventions), and the cluster will pull them.
- Environments will pin images in the `image-tags.yaml` files under `deploy/envs/`. Promotion PRs that change only those files merge without a human (CLAUDE.md → Conventions).
- IAM can limit pushes by repository, but not by tag: ECR has no condition key for the image tag. A role allowed to push `pr-` images to a repository can push any tag there.
- PR jobs run code from the PR's own branch, and agents open PRs from branches of this repository, which get an OIDC token. So a PR job must be trusted less than a `main` build.
- The registry must not grow forever: every PR push adds an image.

## Decision

- **Two repositories per service.** In eu-central-1, from `infra/live/_global/ecr`:
  - **main** (`rarebit/<service>`): `main-<sha7>` images from `main`. Only main's CI role may push there (the GitHub OIDC roles PR), and it's where environments pull from.
  - **PR** (`rarebit/pr/<service>`): `pr-<number>-<sha7>` images. PR jobs push there, and previews pull from there.

  A PR job then can't put an image where a deployment would pull it.
- **Immutable tags** in both kinds. Immutability isn't enough on its own: once an image is deleted or expires, its tag can be pushed again with other content. So the CI build will **compare digests** when a tag exists: the same image means skip the push, a different one means fail. It also checks that the image's `org.opencontainers.image.revision` label is the full commit SHA. And a promotion **pins the digest** (`main-<sha7>@sha256:...`), which is a precondition for the first promotion.
- **Scanning:**
  - basic scanning, which is free, on every push, set at the registry level for every repository;
  - each repository's own `scan_on_push` stays on as a fallback;
  - the CI build will also run Trivy before the push.
- **AES256 encryption** with the key ECR manages. A customer-managed KMS key would cost $1/month plus requests, and add a key policy; IAM on the CI and node roles already decides who pushes and pulls.
- **Lifecycle rules per kind:**
  - **main:** keep the newest 50 `main-` images, by count. At 10 to 20 merges a day that's several days of history, for an environment that falls behind or a rollback.
  - **PR:** `pr-` images expire 7 days after the push, which is long enough for a preview to survive a weekend of nightly teardowns.
  - **both:** untagged images (from failed or replaced pushes) expire 1 day after the push.
  - **No rule selects `tagStatus = "any"`.** So only a repository's own rule for its kind can expire an image.
  - **What an environment runs must never expire.** Promotion uses only `main-` images, and an environment must not fall more than 50 `main` builds behind.
- **`prevent_destroy` and `force_delete = false`** on every repository. Terraform refuses to delete one, empty or not; deleting one on purpose is a reviewed change. The `_global` destroy guard is ADR 0037.

## Alternatives considered

| Option | Why not |
|---|---|
| One repository per service for both kinds | A PR job could push a `main-` tag before `main`'s build does, and immutability would then protect the planted image |
| One shared repository, services told apart by tag prefix | Same problem, and IAM couldn't scope a service's pipeline to its own images |
| Mutable tags (`latest`, `main`) | A deployment pinned to a tag could change without a commit |
| Enhanced scanning (Amazon Inspector) | Continuous rescans and language packages, but billed per image per month; Trivy in CI covers the build-time check for now |
| GitHub Container Registry | No IAM for the cluster's nodes: pulls would need a token as a Kubernetes secret |
| Keep 15 `main-` images, PR images 3 days | 15 builds is one or two days at today's merge rate; 3 days loses a Friday PR's preview by Monday |

## Consequences

- **Good:**
  - a PR can't touch what deployments pull;
  - IAM can scope push and pull per repository and per kind;
  - storage stays small without anyone cleaning up.
- **Bad / risks:**
  - **Eight repositories to keep in the unit's list.** A new service needs both entries (`plat new-service` will add them).
  - **A PR older than 7 days loses its images.** Its preview needs a new push before pods can be rescheduled.
  - **The count rule doesn't know what's deployed.** An environment more than 50 `main` builds behind loses its image. A protected `release-` tag for promoted images comes with the promotion PR (#62).
  - **Unverified untagged behavior.** Whether the untagged rule could count the untagged children of a multi-arch index, or attestation manifests, is unknown until the first CI push. That push is the check (#62).
  - **Base images from Docker Hub** are still pulled anonymously and rate-limited. An ECR pull-through cache comes in its own PR.
- **Follow-ups (#62):**
  - the repository policies: only the main CI role pushes to the main repositories, and nobody deletes images there;
  - digest pinning;
  - deleting a PR's images when it closes;
  - a mutable cache tag or repository if the build uses a registry cache.

## How we'll know it was right

- Pushing an existing tag fails with `ImageTagAlreadyExistsException`, and the PR role can't push to `rarebit/<service>` at all.
- After a week of PRs, `aws ecr describe-images` shows no `pr-` image older than 7 days, and at most 50 `main-` images per main repository.
- No `ImagePullBackOff` caused by an expired image.
