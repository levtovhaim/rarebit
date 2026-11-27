# Runbook: CI can't reach AWS

- **Alert(s):** none; these show up as a failed workflow step (`aws-actions/configure-aws-credentials`, a push, a plan).
- **Service:** the GitHub OIDC provider and CI roles from `infra/live/_global/github-oidc` (ADR 0038)
- **Severity:** ticket (CI is blocked; running environments aren't affected)
- **Last fired on purpose:** not yet: no workflow uses the roles yet. The module's trust tests failed for each of seven wrong variants of the trust conditions, tried by hand on 2026-11-26: `StringLike`, no audience, another repository, `refs/heads/*`, main accepting pull requests, an environment subject, and the name-only subject (`repo:<owner>/<name>:…`). The roles were read back from AWS after each apply the same day, and IAM's policy simulator showed `gha-tf-plan` refused the owner's contact, payment, invoice and budget data, Cost Explorer, queue messages, log queries, objects outside the state bucket, this account's SSM parameters and lock writes, while state, AWS's public parameters and resource configuration stay readable. To simulate S3, pass `s3:ResourceAccount` as a context entry: without it, the other-accounts deny matches every bucket, the state bucket too. On 2026-11-27 the simulator showed `s3:GetObject` on `_global/cost-alerts/terraform.tfstate`, in the default workspace and in `env:/staging/`, as `explicitDeny` (a private state unit, ADR 0042), on `_global/ecr/terraform.tfstate` as `allowed`, and `cloudtrail:LookupEvents` and `GetQueryResults` as `explicitDeny`.

## What it means

| Error | What's wrong |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The token's `sub` or `aud` doesn't match the role's trust policy. Common causes: a job that names an `environment:` (its `sub` is `…:environment:<env>`); a run from a fork or another repository; a merge queue run (`ref:refs/heads/gh-readonly-queue/…`); the wrong role for the event (a PR job asking for `gha-ci-main`); a trust policy with the name-only subject, while this repository's tokens carry the immutable one (`repo:levtovhaim@360220203/rarebit@1468801318:…`). |
| `Could not load credentials` / `ACTIONS_ID_TOKEN_REQUEST_URL` not set | The workflow or job lacks `permissions: id-token: write`, or the run is a fork pull request, which gets no token |
| `No OpenIDConnect provider found in your account for https://token.actions.githubusercontent.com` | The provider is missing in this account, or the job targets another account's role |
| `AccessDenied … explicit deny in a resource-based policy` on a push | The repository policy refused the push: a PR job pushing to a main repository, or a role not in its list (ADR 0040). A refused push usually fails first on `ecr:InitiateLayerUpload` |
| `AccessDenied … explicit deny in an identity-based policy` (plan) | The plan role tried something it's denied (ADRs 0038, 0042): a secret or SSM parameter value, the account's contact or billing data, Cost Explorer, a data read (logs, messages, table items, CloudTrail's event history, objects outside the state bucket), the state of a unit in `private_state_units` (`_global/cost-alerts`), or another account's bucket. `aws s3 ls` fails this way too: `ListAllMyBuckets` has no bucket, so the other-accounts deny catches it |
| `ExpiredToken` after an hour | The session lasts one hour; a longer job needs to assume the role again |

## Impact on players

None: CI is blocked, running environments aren't touched.

## Diagnose (first 5 minutes)

1. **The run's claims.** Add this step temporarily to the failing job. It prints the claims, never the token:

   ```bash
   curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
     | jq -r .value | python3 -c 'import base64, json, sys
   p = sys.stdin.read().strip().split(".")[1]; p += "=" * (-len(p) % 4)   # base64url, no padding
   c = json.loads(base64.urlsafe_b64decode(p))
   print({k: c.get(k) for k in ("sub", "aud", "ref", "event_name", "environment", "job_workflow_ref")})'
   ```

2. **What the role trusts** (read-only):

   ```bash
   aws iam get-role --profile rarebit --role-name gha-ci-pr --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
   ```

3. **What was refused,** from CloudTrail (read-only): `aws cloudtrail lookup-events --profile rarebit --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity --max-results 5`. The role is in the event's `requestParameters.roleArn`, the token's `sub` in `userIdentity`, and the reason in `errorCode`.
4. **A refused push:**

   ```bash
   aws ecr get-repository-policy --profile rarebit --repository-name <name> --query policyText --output text
   ```

## Fix

| Cause | Fix |
|---|---|
| `sub` doesn't match | Change the workflow, not the trust policy: PR jobs and main jobs don't name an environment, and each job asks for its own role. A new kind of job gets its own role (a reviewed change to the `github-oidc` module and `shared.hcl`). |
| No `id-token: write` | Add `permissions: id-token: write` to that job only, next to `contents: read` |
| Fork pull requests | By design they get no token, so they can't push or plan. A maintainer reruns the change from a branch of this repository. |
| No OpenIDConnect provider | Check the role ARN's account in the workflow. If the provider is really gone, apply `_global/github-oidc` (**state-changing:** a human runs it or approves the exact command, CLAUDE.md → Rules, rule 2). `prevent_destroy` makes this unlikely. |
| A plan refused by the plan role's denies | Don't widen the role. A unit whose refresh reads a denied value (an SSM parameter it manages, the budgets), or whose state is private (`private_state_units` in `_global/shared.hcl`), is planned locally, outside public PR logs (ADRs 0038, 0042, #62) |
| A repository policy refused the push | The push went to the wrong kind of repository: PR images go to `rarebit/pr/<service>` (ADR 0036) |
| The repository was renamed or recreated | `github_repository`, `github_owner_id` and `github_repository_id` in `infra/live/_global/shared.hcl` (`gh api repos/<owner>/<name>` → `.owner.id`, `.id`), then a plan and apply of `_global/github-oidc` (**state-changing:** rule 2) |

## Verify

The job's step `configure-aws-credentials` succeeds. `aws sts get-caller-identity` in the job prints an `Arn` of the form `arn:aws:sts::…:assumed-role/gha-ci-pr/…`, and the push or plan goes through.

## Roll back or escalate

- A bad change to a trust or permission policy: revert the PR and apply again (state-changing, rule 2).
- Someone outside this repository taking a role would be an incident. Check CloudTrail for `AssumeRoleWithWebIdentity` with a foreign `sub`, and narrow the trust.
- A policy attached to a CI role outside Terraform shows up in the next plan of `_global/github-oidc` (the exclusive-policy resources). Find who attached it (CloudTrail `AttachRolePolicy`, `PutRolePolicy`) before the apply removes it.

## Prevention

- The module's tests specify each role's exact trust and what it may do. IAM Access Analyzer finds nothing in the role permission policies; on the trust policies it warns only about the two pull request roles, an accepted warning (ADR 0038).
- `gha-ci-main` gets pinned to the build workflow, and the apply and teardown roles get GitHub environments with a required reviewer (#62).
