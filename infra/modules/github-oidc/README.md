# github-oidc

How GitHub Actions reaches AWS: an IAM OIDC provider for GitHub's token issuer, and one role per kind of CI job (ADR 0038). No access key exists anywhere (CLAUDE.md → Rules, rule 5).

Each workflow run gets a short-lived token signed by `token.actions.githubusercontent.com`. Its claims say where the run comes from:

- `aud`: the audience, `sts.amazonaws.com` for AWS;
- `sub`: the repository and the kind of run. The repository uses GitHub's immutable subject, which names it with its owner's and its own numeric ID (`<owner>@<owner-id>/<name>@<repository-id>`, inputs `github_owner_id` and `github_repository_id`):
  - `repo:<owner>@<owner-id>/<name>@<repository-id>:pull_request` for pull requests;
  - `repo:<owner>@<owner-id>/<name>@<repository-id>:ref:refs/heads/main` for runs on main;
  - `repo:<owner>@<owner-id>/<name>@<repository-id>:environment:<env>` for a job that names an environment.

The job trades the token for a role's credentials (`aws-actions/configure-aws-credentials`, which calls `sts:AssumeRoleWithWebIdentity`). The credentials last one hour. Each role's trust policy decides which `sub` may take it, by exact match.

| Role key | Who may take it | What it may do |
|---|---|---|
| `pr` | pull request runs | push, read and delete images in the PR repositories (`rarebit/pr/*`) |
| `main` | runs on the `main` branch | push and read images in the main repositories; no delete |
| `tf_plan` | pull request runs | read configuration (`ReadOnlyAccess`) and write nothing; denied secret and parameter values, the account's contact, billing and cost data, data-plane reads (logs, messages, table items, objects outside the state bucket), the state of units listed in `private_state_prefixes`, and other accounts' buckets |

- **No inline policy** of a CI role may change IAM, repository policies, lifecycle rules, tag mutability, scanning or replication, or allow a `*` action. `ReadOnlyAccess` is AWS's managed policy of `Get*`, `List*` and `Describe*` actions.
- **Whoever opens a pull request** controls the code that runs with `pr` and `tf_plan`, and can take either: the denies on `tf_plan` are what limit it (ADR 0038).
- **Each role has exactly its policies** (`aws_iam_role_policies_exclusive`, `aws_iam_role_policy_attachments_exclusive`): a policy attached outside Terraform shows up in the next plan.
- **`prevent_destroy`** on the provider and the roles (ADR 0037): renaming a role, or changing its path, is a reviewed change that lifts it first.
- **The main repositories enforce the split on their side:** a repository policy refuses pushes from anyone but the main role and people (`ecr-repositories`, ADR 0040).
- **Apply and teardown roles** come with their workflows: they need GitHub environments with a required reviewer.

It's applied from `infra/live/_global/github-oidc`.

## Usage

From a Terragrunt unit under `infra/live` (the real one is `_global/github-oidc`, with names from `_global/shared.hcl`):

```hcl
inputs = {
  github_repository    = "levtovhaim/rarebit"
  github_owner_id      = "360220203"  # gh api repos/levtovhaim/rarebit → .owner.id
  github_repository_id = "1468801318" # → .id
  account_id           = include.root.locals.account_id
  region               = include.root.locals.region
  roles                = { pr = "gha-ci-pr", main = "gha-ci-main", tf_plan = "gha-tf-plan" }
  main_repositories    = ["rarebit/game"]
  pr_repositories      = ["rarebit/pr/game"]
  state_bucket         = include.root.locals.state_bucket
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
| [aws_iam_role_policies_exclusive.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_role_policies_exclusive) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.tf_plan_read_only](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachments_exclusive.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/iam_role_policy_attachments_exclusive) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The AWS account the roles and repositories are in, for the ARNs in the policies. | `string` | n/a | yes |
| github\_owner\_id | The numeric ID of the repository's owner on GitHub (gh api repos/<owner>/<name> → .owner.id). GitHub's immutable subject puts it in the token's sub. | `string` | n/a | yes |
| github\_repository | The GitHub repository, owner/name, whose workflow runs may take the roles. | `string` | n/a | yes |
| github\_repository\_id | The numeric ID of the repository on GitHub (gh api repos/<owner>/<name> → .id). GitHub's immutable subject puts it in the token's sub. | `string` | n/a | yes |
| main\_repositories | Names of the ECR repositories for main images (rarebit/<service>): the main role may push to these. | `list(string)` | n/a | yes |
| pr\_repositories | Names of the ECR repositories for PR images (rarebit/pr/<service>): the pr role may push to and delete from these. | `list(string)` | n/a | yes |
| region | The region of the ECR repositories. | `string` | n/a | yes |
| roles | The role names: pr (pull request image builds), main (main image builds), tf\_plan (pull request terraform plans). | `map(string)` | n/a | yes |
| state\_bucket | The Terraform state bucket: the only bucket whose objects the tf\_plan role may read (each unit's state). | `string` | n/a | yes |
| private\_state\_prefixes | Unit paths (state keys under the bucket, e.g. \_global/cost-alerts) whose state holds personal data: the tf\_plan role may not read them. | `list(string)` | `[]` | no |
| role\_path | The IAM path for the roles, e.g. /ci/; repository policies match the roles by their ARN, which includes it. | `string` | `"/ci/"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| provider\_arn | ARN of the IAM OIDC provider for GitHub Actions. |
| role\_arns | Role ARN by key (pr, main, tf\_plan): the role-to-assume of each workflow job. |
<!-- END_TF_DOCS -->
