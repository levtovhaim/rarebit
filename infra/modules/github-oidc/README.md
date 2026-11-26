# github-oidc

How GitHub Actions reaches AWS: an IAM OIDC provider for GitHub's token issuer, and one role per kind of CI job (ADR 0038). No access key exists anywhere (CLAUDE.md → Rules, rule 5).

Each workflow run gets a short-lived token signed by `token.actions.githubusercontent.com`. Its claims say where the run comes from:

- `aud`: the audience, `sts.amazonaws.com` for AWS;
- `sub`: the repository and the kind of run:
  - `repo:<owner>/<name>:pull_request` for pull requests;
  - `repo:<owner>/<name>:ref:refs/heads/main` for pushes to main;
  - `repo:<owner>/<name>:environment:<env>` for a job that names an environment.

The job trades the token for a role's credentials (`aws-actions/configure-aws-credentials`, which calls `sts:AssumeRoleWithWebIdentity`). The credentials last one hour. Each role's trust policy decides which `sub` may take it, by exact match.

| Role key | Who may take it | What it may do |
|---|---|---|
| `pr` | pull request runs | push, read and delete images in the PR repositories (`rarebit/pr/*`) |
| `main` | runs for the `main` branch | push and read images in the main repositories; no delete |
| `tf_plan` | pull request runs | read everything (`ReadOnlyAccess`) and write state lock objects; never read secret values, never touch another account's buckets |

- **No CI role may** change IAM, repository policies, lifecycle rules, tag mutability or scanning, and none has a `*` action.
- **The main repositories enforce the same split on their side:** a repository policy refuses pushes from anyone but the main role and humans (`ecr-repositories`, ADR 0036).
- **Apply and teardown roles** come with their workflows: they need GitHub environments with a required reviewer.

It's applied from `infra/live/_global/github-oidc`.

## Usage

From a Terragrunt unit under `infra/live` (the real one is `_global/github-oidc`, with names from `_global/shared.hcl`):

```hcl
inputs = {
  github_repository = "levtovhaim/rarebit"
  account_id        = include.root.locals.account_id
  region            = include.root.locals.region
  roles             = { pr = "gha-ci-pr", main = "gha-ci-main", tf_plan = "gha-tf-plan" }
  main_repositories = ["rarebit/game"]
  pr_repositories   = ["rarebit/pr/game"]
  state_bucket      = include.root.locals.state_bucket
}
```

[`examples/basic`](examples/basic) shows it with plain Terraform (plan only). `make infra` validates the module and runs its tests (`tests/`) against a mocked AWS provider, with no credentials. The trust assertions there are the specification of who may take which role.

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
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.tf_plan_read_only](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_role_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The AWS account the roles and repositories are in, for the ARNs in the policies. | `string` | n/a | yes |
| github\_repository | The GitHub repository, owner/name, whose workflow runs may take the roles. | `string` | n/a | yes |
| main\_repositories | Names of the ECR repositories for main images (rarebit/<service>): the main role may push to these. | `list(string)` | n/a | yes |
| pr\_repositories | Names of the ECR repositories for PR images (rarebit/pr/<service>): the pr role may push to and delete from these. | `list(string)` | n/a | yes |
| region | The region of the ECR repositories. | `string` | n/a | yes |
| roles | The role names: pr (pull request image builds), main (main image builds), tf\_plan (pull request terraform plans). | `map(string)` | n/a | yes |
| state\_bucket | The Terraform state bucket: the tf\_plan role may write and delete lock objects (*.tflock) there. | `string` | n/a | yes |
| role\_path | The IAM path for the roles, e.g. /ci/; repository policies match the roles by their ARN, which includes it. | `string` | `"/ci/"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| provider\_arn | ARN of the IAM OIDC provider for GitHub Actions. |
| role\_arns | Role ARN by key (pr, main, tf\_plan): the role-to-assume of each workflow job. |
<!-- END_TF_DOCS -->
