# ecr-repositories

Private ECR repositories for the service images, one per service (ADR 0036). CI pushes `pr-<number>-<sha7>` and `main-<sha7>` tags (CLAUDE.md → Conventions); the cluster's nodes pull from here.

- **Immutable tags:** a tag names one image forever, so a deployed `main-<sha7>` is always the image that was tested. Pushing the same tag twice fails: CI checks whether the tag exists before it builds.
- **Scanning:** basic scanning (free) on every push.
- **Encryption:** AES256 with the key ECR manages. Not a customer-managed KMS key: ADR 0036 says why.
- **Lifecycle:** the same rules on every repository. PR images expire 3 days after they're pushed, untagged images after 1 day, and the newest 15 `main-` images are kept. An image a running environment uses must never be one that expires (ADR 0036; [runbook](../../../docs/runbooks/ecr.md)).
- **Deletion:** `force_delete = false`, so Terraform refuses to delete a repository that still holds images.

It's applied from `infra/live/_global/ecr`.

## Usage

From a Terragrunt unit under `infra/live` (the real one is `_global/ecr`):

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/infra/modules//ecr-repositories"
}

inputs = {
  repositories = ["rarebit/game", "rarebit/web"]
}
```

[`examples/basic`](examples/basic) shows it with plain Terraform (plan only). `make infra` validates the module and runs its tests (`tests/`) against a mocked AWS provider, with no credentials. The lifecycle assertions there are the specification of the rules.

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
| [aws_ecr_lifecycle_policy.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/ecr_repository) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| repositories | Names of the repositories to create, one per service image, e.g. rarebit/game. | `set(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| repository\_arns | Repository ARN by name, for the IAM policies of the roles that push (CI) and pull (the cluster's nodes). |
| repository\_urls | Repository URL by name (<account>.dkr.ecr.<region>.amazonaws.com/<name>), for CI to push to and deploy values to pull from. |
<!-- END_TF_DOCS -->
