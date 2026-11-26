# 0040. ECR repositories enforce who may push and delete with deny-only repository policies, and people keep both as break-glass

- **Status:** accepted; supersedes ADR 0036 in part (who may push to and delete from the main repositories)
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- ADR 0036 split the images into main repositories (`rarebit/<service>`) and PR repositories (`rarebit/pr/<service>`), because IAM can't limit pushes by tag. It said only main's CI role pushes to the main repositories, and nobody deletes images there.
- The CI roles' IAM policies (ADR 0038) say what each role may do. That doesn't stop another principal whose IAM policy allows more, such as an admin or a future role with `ecr:*`, from pushing a `main-` image.
- ECR's lifecycle rules delete images by themselves (ADR 0036). Nothing may get in their way.
- People sometimes need to push or delete by hand: rebuild an expired main image, or remove a bad one (`docs/runbooks/ecr.md`).

## Decision

- **Every repository gets a repository policy with two Deny statements, and no Allow:**
  - `OnlyTheseMayPush` denies the push actions (`InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`) to everyone whose `aws:PrincipalArn` doesn't match the kind's `push_principals`;
  - `OnlyTheseMayDelete` denies `BatchDeleteImage` to everyone whose `aws:PrincipalArn` doesn't match the kind's `delete_principals`.
- **Both statements apply only to requests made by a principal** (`Null aws:PrincipalArn = false`). AWS doesn't evaluate repository policies for lifecycle expiry anyway; the condition says so in the policy itself.
- **Who may do what:**

  | Kind | May push | May delete |
  |---|---|---|
  | main | `gha-ci-main`, IAM users | IAM users |
  | pr | `gha-ci-pr`, IAM users | `gha-ci-pr`, IAM users |

- **IAM users are people (ADR 0002), as break-glass.** This supersedes ADR 0036's "only main's CI role" pushes to the main repositories and "nobody deletes images there": people may do both by hand.

## Alternatives considered

| Option | Why not |
|---|---|
| No repository policy, IAM policies only | Any principal with broad ECR rights could push a `main-` image where deployments pull from |
| Allow statements in the repository policy | In the same account, a repository policy's Allow grants access even without an IAM allow: it would widen access, not narrow it |
| No exception for people | Fixing an image by hand would first need the policy changed, in a reviewed PR, during an incident |
| Naming the IAM users one by one | Exact, but puts people's IAM user names in a public repository. Needed once an IAM user that isn't a person exists (below) |
| Also denying policy and lifecycle changes (`SetRepositoryPolicy`, `PutLifecyclePolicy` and the like) | It needs an exception for the apply role, which doesn't exist yet. Decided with that role |

## Consequences

- **Good:**
  - a pull request job can't push a `main-` image, by its IAM policy and by the repository policy;
  - in the main repositories, only people delete images, and the lifecycle rules still expire them.
- **Bad / risks:**
  - **`user/*` means every IAM user.** That's people only while no IAM user for a machine exists, which rule 5 (no static keys) rules out. Before one is created, the pattern narrows to the named users or an IAM path for people.
  - **A person working through an assumed role** (not their IAM user) is refused: its ARN isn't `user/*`.
  - **The policy doesn't protect itself:** whoever may call `ecr:SetRepositoryPolicy` can replace it. That's people today. The apply role decides it later.
  - **IAM Access Analyzer can't validate ECR repository policies:** the resource type isn't supported. The module's tests and a read-back from AWS cover them.
- **Follow-ups (#62):**
  - verify that PR images older than 7 days really expire once CI pushes some (lifecycle expiry under these policies).

## How we'll know it was right

- A pull request run's push to `rarebit/<service>` fails with `explicit deny in a resource-based policy`.
- PR images disappear 7 days after their push, as ADR 0036's lifecycle rules say.
