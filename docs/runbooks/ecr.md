# Runbook: an image can't be pushed or pulled

- **Alert(s):** none yet; these show up as a failed CI push, or pods in `ImagePullBackOff`.
- **Service:** the image registries from `infra/live/_global/ecr` (ADRs 0036, 0037, 0040)
- **Severity:** page when a running environment can't pull its image, ticket for a failed CI push
- **Last fired on purpose:** 2026-11-26, the destroy guard: `terragrunt run -- destroy`, the `destroy` shortcut and `run --all -- destroy` all left the `_global` units alone, and `make infra` fails when the guard is removed. Push and pull failures haven't been exercised: no images exist yet.

Main images (`main-<sha7>`) live in `rarebit/<service>`; PR images (`pr-<number>-<sha7>`) in `rarebit/pr/<service>` (ADR 0036).

## What it means

| Error | What's wrong |
|---|---|
| `ImageTagAlreadyExistsException` on push | The tag exists, and tags are immutable. The same commit was built again. The CI build workflow (not written yet) is to compare digests: the same image means skip, a different one means fail. |
| `ImagePullBackOff` with `not found` or `manifest unknown` | The tag doesn't exist (anymore): a `pr-` image older than 7 days, a `main-` image more than 50 builds old, or a wrong tag in the deploy values |
| `ImagePullBackOff` with `403` or `no basic auth credentials` | The node role can't pull: its IAM policy, or the image is in another account or region |
| `ImagePullBackOff` with `no match for platform in manifest` | The image was built for one CPU architecture (amd64) and the node is another (arm64 spot capacity, say) |
| `RepositoryNotFoundException` or `name unknown` on push | The repository isn't in `ecr_repositories` in `infra/live/_global/shared.hcl`: a new service needs its main and its PR entry, then an apply of `_global/ecr` and of `_global/github-oidc`, so the CI roles may push to it (ADR 0039) |
| `AccessDeniedException` on push from CI | The CI role may not push to this repository. A refused push usually fails first on `ecr:InitiateLayerUpload`, not `PutImage`. `explicit deny in a resource-based policy` means the repository policy refused it: a PR job pushing to a main repository, or a role not in its list (ADR 0040). `no identity-based policy allows` means the role's IAM policy doesn't cover the repository: a new service whose `github-oidc` unit wasn't applied yet. Otherwise the OIDC role wasn't assumed ([github-oidc runbook](github-oidc.md)) |
| `AccessDeniedException` on `BatchDeleteImage` | The repository policy allows deletes only to `delete_principals` (ADR 0040): in a main repository, IAM users only. A person working through an assumed role, or a PR cleanup job pointed at a main repository, is refused. Main images normally go by the lifecycle rules; a person deletes one by hand as their IAM user |
| `destroy` prints `Early exit … due to exclude block with no_run = true` and exits 0 | Expected: Terragrunt's destroy command skips `_global` units (ADR 0037). Nothing was destroyed. |

## Impact on players

A failed pull matters only when a pod has to start: a rollout, a replaced node, a crash, or the next `plat env up`. Running pods keep running. A failed CI push blocks only that PR or merge.

## Diagnose (first 5 minutes)

All read-only. `R` is the repository (`rarebit/game`, or `rarebit/pr/game` for a PR image), `T` the tag:

```bash
aws ecr describe-images --profile rarebit --repository-name "$R" --image-ids imageTag="$T"   # does the tag exist? its digest?
aws ecr describe-images --profile rarebit --repository-name "$R" \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].[imageTags[0],imagePushedAt,imageDigest]' --output table   # newest first
aws ecr get-lifecycle-policy --profile rarebit --repository-name "$R" --query lifecyclePolicyText --output text
aws ecr describe-image-scan-findings --profile rarebit --repository-name "$R" --image-id imageDigest=<digest> \
  --query 'imageScanFindings.findingSeverityCounts'   # for a multi-arch index, use a platform image's digest
kubectl -n <namespace> describe pod <pod> | grep -A3 -E 'Failed|Back-off'   # the pull error, word for word
```

## Fix

### A main image that expired while an environment still uses it

1. Promote a newer `main-` image to that environment: a promotion PR that changes its `image-tags.yaml` under `deploy/envs/`, pinning the digest. That's the usual fix.
2. If that exact commit has to come back, rebuild it. **State-changing:** it pushes an image. A human runs it, or approves the exact command (CLAUDE.md → Rules, rule 2):
   - re-run that commit's `main` CI run (`gh run rerun <run-id>`), possible for 30 days after the run;
   - after that, start the build workflow by hand with the commit SHA.

   The rebuilt image has a **new digest**, so update the pin.
3. Then ask why the environment was more than 50 builds behind, and whether the rule (ADR 0036) or the promotion habit needs to change.

### A preview whose PR image expired

PR images expire 7 days after their push. Push a new commit to the PR, or re-run the PR's CI build for its head commit. **State-changing:** that's the same push as above. It pushes `pr-<number>-<sha7>` again: the old image is gone, so the immutable tag accepts it. Pods pull it on their next start.

### A push refused because the tag exists

If the digest matches, nothing to fix: the image for that commit is already there. If it doesn't, stop: someone pushed different content under that tag. Find out who (CloudTrail `PutImage` events) before anything uses it.

### A repository to delete

Deletion is guarded three ways: `prevent_destroy` in the module, `force_delete = false`, and Terragrunt's destroy guard for `_global` (ADR 0037). Deleting one on purpose takes a reviewed PR that:

1. removes it from `ecr_repositories` in `infra/live/_global/shared.hcl`, and plans both `_global/ecr` and `_global/github-oidc`;
2. lifts `prevent_destroy` for that one apply.

Its images get deleted by hand first. **State-changing:** a human runs `aws ecr batch-delete-image` and the apply (rule 2).

## Verify

- `describe-images` shows the tag and the expected digest.
- The pod is `Running` with that image: `kubectl -n <namespace> get pod <pod> -o jsonpath='{.status.containerStatuses[0].imageID}'`.

## Roll back or escalate

- Roll the environment back to a `main-` image that still exists: a promotion PR that pins its digest.

## Prevention

- Promotion keeps every environment within the newest 50 `main` builds, and a protected `release-` tag for promoted images comes with the promotion PR (issue #62).
- The CI build is to compare digests and the revision label when a tag exists, instead of trusting the tag (#62).
- PR jobs can push only to the PR repositories: the CI roles' IAM policies (ADR 0038) and the main repositories' policies (ADR 0040) both say so.
