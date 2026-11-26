# Runbook: an image can't be pushed or pulled

- **Alert(s):** none yet; these show up as a failed CI push, or pods in `ImagePullBackOff`.
- **Service:** the image registries from `infra/live/_global/ecr` (ADR 0036)
- **Severity:** page when a running environment can't pull its image, ticket for a failed CI push
- **Last fired on purpose:** not yet

## What it means

| Error | What's wrong |
|---|---|
| `ImageTagAlreadyExistsException` on push | The tag exists, and tags are immutable. CI rebuilt a commit it had already pushed. The image already there is the one for that commit: skip the push. |
| `ImagePullBackOff` with `not found` or `manifest unknown` | The tag doesn't exist (anymore). Either the lifecycle rules expired it (a `pr-` image older than 3 days, or a `main-` image more than 15 builds old), or the tag in the deploy values is wrong. |
| `ImagePullBackOff` with `403` or `no basic auth credentials` | The node role can't pull: its IAM policy, or the image is in another account or region |
| `AccessDeniedException` on push from CI | The CI role's policy doesn't cover this repository, or the OIDC role wasn't assumed |
| `destroy` prints `Early exit … due to exclude block with no_run = true` and exits 0 | Expected: `_global` units can't be destroyed by Terragrunt (`infra/live/root.hcl`). Nothing was destroyed. |

## Impact on players

A failed pull matters only when a pod has to start: a rollout, a node replaced, a crash. Running pods keep running. A failed CI push blocks only that PR or merge.

## Diagnose (first 5 minutes)

All read-only. `R` is the repository (e.g. `rarebit/game`), `T` the tag:

```bash
aws ecr describe-images --profile rarebit --repository-name "$R" --image-ids imageTag="$T"   # does the tag exist?
aws ecr describe-images --profile rarebit --repository-name "$R" \
  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].[imageTags[0],imagePushedAt]' --output table   # newest first
aws ecr get-lifecycle-policy --profile rarebit --repository-name "$R" --query lifecyclePolicyText --output text
aws ecr describe-image-scan-findings --profile rarebit --repository-name "$R" --image-id imageTag="$T" \
  --query 'imageScanFindings.findingSeverityCounts'
kubectl -n <namespace> describe pod <pod> | grep -A3 -E 'Failed|Back-off'   # the pull error, word for word
```

## Fix

### A tag that expired while an environment still uses it

1. Find the commit the tag names: `main-<sha7>` is that commit on `main`.
2. Rebuild and push that commit's image by re-running its `main` CI run. That's a new push of the same tag, now allowed because the old image is gone. Or promote a newer `main-` tag through a promotion PR (`deploy/envs/*/image-tags.yaml`), which is the usual fix.
3. Then ask why the environment was more than 15 builds behind, and whether the rule (ADR 0036) or the promotion habit needs to change.

### A push refused because the tag exists

Nothing to fix in the registry: the image for that commit is already there. The CI build step checks with `describe-images` before building, and skips the push.

### A repository to delete

`_global` units can't be destroyed by Terragrunt, and `force_delete = false` refuses a repository with images. Deleting one on purpose means a reviewed PR that removes it from the unit's `repositories` list, after its images are deleted by hand. **State-changing:** a human runs the `aws ecr batch-delete-image` and the apply (CLAUDE.md → Rules, rule 2).

## Verify

- `describe-images` shows the tag, and the pod is `Running` with that image (`kubectl get pod -o jsonpath='{.status.containerStatuses[0].imageID}'`).

## Roll back or escalate

- Roll the environment back to a `main-` tag that still exists (a promotion PR).

## Prevention

- Promotion keeps environments within the newest 15 `main` builds (ADR 0036).
- CI checks a tag exists before building and skips the push if it does.
