# 0032. Keep Terraform state in one S3 bucket with native locking

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- Every Terraform unit under `infra/live` needs its state somewhere shared and locked. A person applying from a laptop and CI planning on a pull request must read the same state, and two applies must never write it at the same time.
- Terraform 1.11 made native S3 locking generally available (`use_lockfile = true`). The lock is a `<key>.tflock` object that Terraform creates with an S3 conditional write, which fails if the object already exists. Locking through a DynamoDB table is deprecated.
- State is the only record of what Terraform manages. Losing it, or a bad write without a way back, means rebuilding that record by hand with `import`.
- The project runs in one account and one region (ADR 0001).

## Decision

- **One bucket:** `rarebit-tfstate-<account-id>-eu-central-1`. Each unit gets one state file at `<unit path>/terraform.tfstate`, with its lock next to it. How the bucket itself gets created is ADR 0034.
- **Locking:** `use_lockfile = true`, for plans and applies alike. No DynamoDB table.
- **The bucket's settings** are in `infra/modules/state-bootstrap`:
  - versioning on, so a bad write can be undone by restoring the version before it;
  - an old version expires once it's older than 90 days and 20 newer old versions of its file exist;
  - no ACLs (`BucketOwnerEnforced`) and all four public access block settings on;
  - a bucket policy that refuses plain HTTP and TLS older than 1.2, and denies everyone `s3:DeleteBucket` and `s3:DeleteObjectVersion`. S3 doesn't check bucket policies for lifecycle actions, so expiry still works, and Terraform releases a lock with a plain `DeleteObject`;
  - SSE-S3 encryption, with uploads under a caller-supplied key (SSE-C) blocked;
  - `prevent_destroy` on the bucket, its versioning and its policy, so a plan that would remove any of them fails.
- **SSE-S3, not a customer-managed KMS key.** Who may read state is decided by IAM, on the people and on the CI roles (issue #62 adds a bucket-side allowlist). A KMS key would add a second check, its key policy, for $1/month plus request charges. Revisit if a principal must be able to list the bucket but not read state, or a compliance rule asks for a customer-managed key.
- **No S3 server access logs.** They need a second bucket (which would need logging of its own), and S3 delivers them best-effort. Reads and writes of state will be audited with CloudTrail data events on this bucket (issue #58); until then nothing records them. Changes to the bucket's settings are in CloudTrail's management events already.

## Alternatives considered

| Option | Why not |
|---|---|
| A DynamoDB lock table | Deprecated since Terraform 1.11, and one more resource and IAM permission to keep right |
| HCP Terraform for state | State outside AWS, one more service and identity to manage, and CI would need a token for it |
| Local state per machine | No locking, nothing shared with CI, and state files on laptops |
| SSE-KMS with a customer-managed key | See the decision: cost and a key policy for a check IAM already makes |
| MFA delete, cross-region replication, Object Lock or AWS Backup | For one maintainer, versioning and the delete Deny cover accidents and tools. MFA delete needs the root user for every versioning change; the others cost money for a risk (losing the whole account) they only partly cover. |

## Consequences

- **Good:**
  - one bucket and no lock table;
  - every bucket setting is reviewed code;
  - old state versions are kept for rollback, and nobody can delete them or the bucket, Terraform included.
- **Bad / risks:**
  - **Deleting the bucket on purpose** takes a reviewed change that removes the Deny statement, or the account's root user, which can always remove a bucket policy.
  - **A plan writes too:** it creates and deletes the lock object. A role that may only read state can't plan unless it runs with `-lock=false` (issue #62).
  - **A crashed apply leaves its lock behind.** It stays until someone removes it with `force-unlock` ([runbook](../runbooks/terraform-state.md)).
  - **Each lock leaves a small old version and a delete marker.** About 20 of each stay per lock file, a few kilobytes.
- **Follow-ups:**
  - CloudTrail data events for this bucket (issue #58);
  - the CI roles' access to state, and the bucket-side allowlist (issue #62).

## How we'll know it was right

- After the bucket's own state moved in, `terragrunt plan` in `_global/bootstrap` read it from S3 and showed no changes (2026-11-26).
- A second `plan` started while an `apply` runs fails with `Error acquiring the state lock` instead of waiting or writing.
- `aws s3api delete-object --version-id` on an old state version is refused with `AccessDenied`, by the admin too.
- The stuck-lock drill and the restore procedure work as written in the runbook.
