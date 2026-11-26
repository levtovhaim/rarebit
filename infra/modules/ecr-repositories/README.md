# ecr-repositories

Private ECR repositories for the service images (ADR 0036), in two kinds, given as `name => kind`:

- **`main`**, e.g. `rarebit/game`: `main-<sha7>` images from `main`. Only main's CI may push here (the GitHub OIDC roles), and deployments pull from here.
- **`pr`**, e.g. `rarebit/pr/game`: `pr-<number>-<sha7>` images for pull requests. IAM can limit pushes by repository but not by tag, so this split is what keeps a PR job from planting a `main-` tag.

Every repository:

- **Immutable tags.** A tag can't be overwritten; deployments still pin the digest, because a deleted or expired tag could be pushed again.
- **Scanning:** basic (free) on every push, set at the registry level for every repository (`aws_ecr_registry_scanning_configuration`, one per account and region, so use this module once), and per repository as a fallback.
- **Encryption:** AES256 with the key ECR manages. Not a customer-managed KMS key: ADR 0036 says why.
- **Deletion:** `prevent_destroy` and `force_delete = false`, so Terraform refuses to delete a repository, empty or not.

**Lifecycle rules, per kind:**

| Kind | Rules |
|---|---|
| `main` | keep the newest 50 `main-` images (by count); untagged images 1 day after the push |
| `pr` | `pr-` images 7 days after the push; untagged images 1 day after the push |

No rule selects `tagStatus = "any"`. An image a running environment uses must never be one that expires ([runbook](../../../docs/runbooks/ecr.md)).

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
  repositories = {
    "rarebit/game"    = "main"
    "rarebit/pr/game" = "pr"
  }
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
| [aws_ecr_registry_scanning_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/ecr_registry_scanning_configuration) | resource |
| [aws_ecr_repository.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/ecr_repository) | resource |
| [aws_ecr_repository_policy.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/ecr_repository_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| delete\_principals | Per kind (main, pr), the principal ARN patterns that may delete images: everyone else is denied. Lifecycle expiry isn't a principal's request and isn't affected. | `map(list(string))` | n/a | yes |
| push\_principals | Per kind (main, pr), the principal ARN patterns that may push (aws:PrincipalArn, ArnLike): everyone else is denied by the repository policy, whatever their IAM policies allow. | `map(list(string))` | n/a | yes |
| repositories | The repositories to create: name => kind. "main" holds main-<sha7> images (e.g. rarebit/game), "pr" holds pr-<number>-<sha7> images (e.g. rarebit/pr/game). Each kind gets its own lifecycle rules. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| repository\_arns | Repository ARN by name, for the IAM policies of the roles that push (CI) and pull (the cluster's nodes). |
| repository\_urls | Repository URL by name (<account>.dkr.ecr.<region>.amazonaws.com/<name>), for CI to push to and deploy values to pull from. |
<!-- END_TF_DOCS -->
