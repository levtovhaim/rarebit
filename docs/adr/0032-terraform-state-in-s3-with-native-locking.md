# 0032. Keep Terraform state in one S3 bucket with native locking, created by Terraform itself

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- Every Terraform unit under `infra/live` needs its state somewhere shared and locked. A person applying from a laptop and CI planning on a pull request must read the same state, and two applies must never write it at the same time.
- Terraform 1.11 made native S3 locking generally available (`use_lockfile = true`). The lock is a `<key>.tflock` object that Terraform creates with an S3 conditional write, which fails if the object already exists. Locking through a DynamoDB table is deprecated.
- The state bucket is infrastructure too, so its settings belong in reviewed code. But Terraform can't keep the bucket's state in the bucket before the bucket exists.
- The project runs in one account and one region (ADR 0001).

## Decision

- **One bucket:** `rarebit-tfstate-<account-id>-eu-central-1`. Each unit gets one state file at `<unit path>/terraform.tfstate`, with its lock next to it.
- **Locking:** `use_lockfile = true`. No DynamoDB table.
- **The bucket's settings** are in `infra/modules/state-bootstrap`:
  - versioning on, so a bad write can be undone by restoring the version before it;
  - old versions expire after 90 days, except the newest 20 of each file;
  - no ACLs (`BucketOwnerEnforced`) and all four public access block settings on;
  - a bucket policy that refuses plain HTTP and TLS older than 1.2;
  - SSE-S3 encryption;
  - `prevent_destroy`, so a plan that would delete it fails.
- **Terraform creates the bucket,** from `infra/live/_global/bootstrap`. That unit's first apply keeps its state in a local file. `terragrunt init -migrate-state` then copies the state into the bucket, and from then on it's a unit like any other. Terragrunt never creates or changes the bucket: no `--backend-bootstrap`, and `disable_bucket_update` in the backend settings.
- **SSE-S3, not a customer-managed KMS key.** Who may read state is decided by IAM, on the people and on the CI roles. A KMS key would add a second check (its key policy) for $1/month plus request charges. Revisit if a principal must be able to list the bucket but not read state, or a compliance rule asks for a customer-managed key.
- **No S3 server access logs.** They need a second bucket (which would need logging of its own), and S3 delivers them best-effort. Reads and writes of state get audited with CloudTrail data events on this bucket, which come with the account's CloudTrail setup.

## Alternatives considered

| Option | Why not |
|---|---|
| A DynamoDB lock table | Deprecated since Terraform 1.11, and one more resource and IAM permission to keep right |
| Terragrunt's `--backend-bootstrap` | Terragrunt creates the bucket with its own defaults, and nothing records them: the bucket isn't in any Terraform state, and its settings aren't in reviewed code. Two tools would then own one bucket. |
| Create the bucket by hand, then `import` it | The same end state, but its first step is an unreviewed console or CLI action. Import is the right tool for resources that already exist (the budgets). |
| HCP Terraform for state | State outside AWS, one more service and identity to manage, and CI would need a token for it |
| Local state per machine | No locking, nothing shared with CI, and state files on laptops |
| SSE-KMS with a customer-managed key | See the decision: cost and a key policy for a check IAM already makes |

## Consequences

- **Good:**
  - one bucket and no lock table;
  - every bucket setting is reviewed code;
  - old state versions are kept for rollback;
  - Terraform refuses to delete the bucket.
- **Bad / risks:**
  - **Bootstrap is a special case.** The runbook documents the procedure: a new account, or a lost bucket.
  - **`prevent_destroy` only stops Terraform.** A console or CLI delete of the bucket would still work for an administrator.
  - **A crashed apply leaves its lock behind.** It stays until someone removes it with `force-unlock` ([runbook](../runbooks/terraform-state.md)).
- **Follow-ups:**
  - CloudTrail data events for this bucket;
  - the CI roles' access to state (read for plan, write for apply), in the GitHub OIDC PR.

## How we'll know it was right

- After the migration, `terragrunt plan` in `_global/bootstrap` reads its state from S3 and shows no changes.
- A second `plan` started while an `apply` runs fails with `Error acquiring the state lock` instead of waiting or writing.
- The stuck-lock drill and the restore-a-version procedure work as written in the runbook.
