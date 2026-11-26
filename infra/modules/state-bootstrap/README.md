# state-bootstrap

The S3 bucket that holds the Terraform state of every unit under `infra/live` (ADR 0032).

- **Locking:** native S3 locking. Terraform writes a `<key>.tflock` object next to the state with a conditional write, so there's no DynamoDB table.
- **Versioning:** on. Every state write keeps the version before it, which is how a bad apply or a corrupted state gets undone ([runbook](../../../docs/runbooks/terraform-state.md)).
- **Old versions:** an old version expires once it's older than `noncurrent_version_days` (90) and the newest `noncurrent_versions_kept` (20) of its file are newer. So every version from the last 90 days stays, and the newest 20 stay however old. Every lock also leaves a small old version and a delete marker; about 20 of those stay per lock file. Incomplete uploads are aborted after a day.
- **Access:** no ACLs (`BucketOwnerEnforced`), all four public access block settings on, and a bucket policy that refuses plain HTTP and TLS older than 1.2, and denies everyone deleting the bucket or an old version. Who may read or write state is decided by IAM policies on the roles.
- **Encryption:** SSE-S3 (AES256), with uploads under a caller-supplied key (SSE-C) blocked. Not a customer-managed KMS key: ADR 0032 says why.
- **Deletion:** `prevent_destroy` on the bucket, its versioning and its policy makes any plan that would delete them fail.

It's applied from `infra/live/_global/bootstrap`, and only there. That unit's first apply keeps its own state in a local file, because the bucket doesn't exist yet; then the state moves into the bucket (ADR 0034; [runbook](../../../docs/runbooks/terraform-state.md) → Bootstrap from nothing).

## Usage

From a Terragrunt unit under `infra/live` (the real one is `_global/bootstrap`):

```hcl
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/infra/modules//state-bootstrap"
}

inputs = {
  bucket_name = include.root.locals.state_bucket
}
```

[`examples/basic`](examples/basic) shows it with plain Terraform (plan only). `make infra` validates the module and runs its tests (`tests/`) against a mocked AWS provider, with no credentials.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.17 |
| aws | 6.73.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.73.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | Name of the state bucket. Bucket names are global across AWS, so include the account ID and the region (infra/live/root.hcl builds rarebit-tfstate-<account>-<region>). | `string` | n/a | yes |
| noncurrent\_version\_days | Days an old state version is kept after a newer write replaces it. The newest noncurrent\_versions\_kept versions are kept regardless of age. | `number` | `90` | no |
| noncurrent\_versions\_kept | How many old versions of each state file to keep, however old they are. | `number` | `20` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arn | ARN of the state bucket, for IAM policies that read or write state (the CI plan and apply roles). |
| bucket\_name | Name of the state bucket, for the backend configuration of every other unit. |
<!-- END_TF_DOCS -->
