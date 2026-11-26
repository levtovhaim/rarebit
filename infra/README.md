# infra

The AWS infrastructure as code: plain Terraform modules, and a thin Terragrunt layer that applies them to the account (ADRs 0032, 0033).

```
infra/
├── modules/                 plain Terraform, one directory per module
│   └── state-bootstrap/     the S3 bucket for Terraform state
│       ├── examples/basic/  the module with plain terraform
│       └── tests/           terraform test, AWS mocked
└── live/                    the only place with real account config
    ├── root.hcl             provider, backend, version constraints: shared by every unit
    └── _global/             the account's foundation, shared by every environment
        ├── env.hcl
        └── bootstrap/       unit: the state bucket
```

A **unit** is a directory under `live/` with a `terragrunt.hcl`. Each unit is its own state file, so one unit's change can't touch another's resources.

## Setup (once per machine)

1. `mise install` in the repo root (Terraform, Terragrunt, tflint, terraform-docs, Trivy, the AWS CLI).
2. The account ID: create `.mise.local.toml` in the repo root (git ignores it, and the repo is public) with:

   ```toml
   [env]
   RAREBIT_AWS_ACCOUNT_ID = "<12-digit account ID>"
   ```

   Every unit's provider refuses to run in any other account, and nothing runs without it.
3. Credentials: `aws login --profile rarebit`, then `aws sts get-caller-identity`. Its `Account` must match the ID above.

Terragrunt keeps its working copies in `~/.cache/terragrunt` (`TG_DOWNLOAD_DIR` in `.mise.toml`), not in the checkout. On a Windows drive mounted into WSL, Terragrunt can't replace its own generated files there (ADR 0033).

## Working with a unit

```bash
cd infra/live/_global/bootstrap
terragrunt render --format json   # the effective config: generated provider, backend, inputs
terragrunt plan                   # read-only: what would change
```

`apply`, `destroy`, `import` and every `state` command change real infrastructure: a human runs them or approves the exact command (CLAUDE.md → Rules, rule 2). Say what the change costs per hour first.

The state bucket's unit is special the first time: its state starts in a local file and then moves into the bucket it created ([runbook](../docs/runbooks/terraform-state.md) → Bootstrap from nothing).

## Checks

- `make infra`: for every module, `validate`, `terraform test` against a mocked AWS provider, and its example's `validate`; then every unit is rendered with a placeholder account ID. It needs no AWS credentials, only network access the first time, to download the provider.
- `make check` (the pre-commit hooks): `terraform fmt`, `terragrunt hcl format`, tflint (the `terraform` rules, all of them, and the AWS ruleset), `trivy config` (every severity fails; an accepted finding gets a `#trivy:ignore:<ID>` comment with its reason) and terraform-docs (each module README's inputs and outputs table is up to date).

## Adding a module or a unit

- A module: `versions.tf` with the exact provider version, `variables.tf` and `outputs.tf` with descriptions, `README.md` with the terraform-docs markers, `examples/basic`, and tests in `tests/`. Then regenerate its table: `terraform-docs --config infra/.terraform-docs.yml infra/modules/<name>`.
- A unit: a `terragrunt.hcl` that `include`s `root.hcl`, names its module with `terraform { source = ... }` and passes `inputs`. The backend and provider come from `root.hcl`: don't write them in the unit.
