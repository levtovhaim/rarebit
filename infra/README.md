# infra

The AWS infrastructure as code: plain Terraform modules, and a thin Terragrunt layer that applies them to the account (ADRs 0032–0037).

```
infra/
├── modules/                 plain Terraform, one directory per module
│   ├── state-bootstrap/     the S3 bucket for Terraform state
│   │   ├── examples/basic/  the module with plain terraform (plan only)
│   │   └── tests/           terraform test, AWS mocked
│   └── ecr-repositories/    the private image registries (main and PR repositories per service)
│       ├── examples/basic/  the module with plain terraform (plan only)
│       └── tests/           terraform test, AWS mocked
└── live/                    the only place with real account config
    ├── root.hcl             provider, backend, version constraints: shared by every unit
    └── _global/             the account's foundation, shared by every environment
        ├── env.hcl
        ├── bootstrap/       unit: the state bucket
        └── ecr/             unit: the image registries ([runbook](../docs/runbooks/ecr.md))
```

A **unit** is a directory under `live/` with a `terragrunt.hcl`. Each unit is its own state file, keyed by its path, so one unit's change can't touch another's resources. Moving a unit means moving its state first ([runbook](../docs/runbooks/terraform-state.md) → Move or rename a unit).

## Setup (once per machine)

Run these in WSL, inside the repo, where mise is active.

1. `mise install` in the repo root (Terraform, Terragrunt, tflint, terraform-docs, Trivy, the AWS CLI).
2. Credentials: `aws login --profile rarebit`, then `aws sts get-caller-identity --profile rarebit`. Check that `Arn` is your user in the project account. Terraform and Terragrunt read these `aws login` credentials as they are: no access key and no `credential_process` (checked on 2026-11-26 by the bucket's first apply, which closes ADR 0002's open question).
3. The account ID: create `.mise.local.toml` in the repo root (git ignores it, and the repo is public; ADR 0035) with:

   ```toml
   [env]
   RAREBIT_AWS_ACCOUNT_ID = "<12-digit account ID>"
   ```

   Take it from `aws sts get-caller-identity --profile rarebit --query Account --output text`, after the check in step 2. Every unit's provider and backend refuse to run in any other account, and nothing runs while the variable is unset, empty or not 12 digits.

Terragrunt keeps its working copies in `~/.cache/terragrunt` (`TG_DOWNLOAD_DIR` in `.mise.toml`), not in the checkout. On a Windows drive mounted into WSL, Terragrunt can't replace its own generated files (ADR 0033), so run Terragrunt only where mise is active. With `TG_PROVIDER_CACHE=1` (also in `.mise.toml`), Terragrunt keeps one copy of each provider for all units instead of one per working copy.

## Working with a unit

```bash
cd infra/live/_global/bootstrap
terragrunt render --format json   # the effective config: generated provider, backend, inputs
terragrunt plan                   # what would change; it reads state and takes the lock for a moment
```

These change real infrastructure or its state: `apply`, `destroy`, `import`, `refresh`, `taint`/`untaint`, `force-unlock`, `init -migrate-state`, and the `state` commands that write (`push`, `mv`, `rm`). A human runs them or approves the exact command (CLAUDE.md → Rules, rule 2), and says what the change costs per hour first. In agent sessions the permission prompt also asks for the read-only `state list`, `show` and `pull`.

Terragrunt's destroy command skips units under `_global`, the account's foundation (the `exclude` block in `root.hcl`, ADR 0037). A `run --all destroy` leaves them out of its queue. A `destroy` in the unit prints `Early exit … due to exclude block with no_run = true` and exits 0, and nothing was destroyed. That guard knows only the command: `apply -destroy`, or a resource removed from the code, still deletes, and the modules' `prevent_destroy` is what refuses those.

The state bucket's unit is special the first time: its state starts in a local file and then moves into the bucket it created (ADR 0034; [runbook](../docs/runbooks/terraform-state.md) → Bootstrap from nothing).

## Checks

- `make infra` runs with no AWS credentials at all, so nothing can reach AWS:
  - for every module, `init -lockfile=readonly`, `validate`, `terraform test` against a mocked AWS provider, and its example's `validate`;
  - for every unit, the generated provider and backend are validated with a placeholder account ID and no backend, and the unit must refuse an empty account ID.

  It needs network access the first time, to download the provider.
- `make check` (the pre-commit hooks): `terraform fmt`, `terragrunt hcl format`, tflint (the `terraform` rules, all of them, and the AWS ruleset), `trivy config` with the checks built into the pinned Trivy (every severity fails; an accepted finding gets a `#trivy:ignore:<ID>` comment with its reason) and terraform-docs (each module README's inputs and outputs table is up to date). The first run downloads the tflint AWS ruleset from GitHub.

## Adding a module or a unit

- A module: `versions.tf` with the exact provider version, `variables.tf` and `outputs.tf` with descriptions, `README.md` with the terraform-docs markers, `examples/basic` (with `default_tags`), and tests in `tests/` with `mock_provider`. Then regenerate its table: `terraform-docs --config infra/.terraform-docs.yml infra/modules/<name>`. The provider's lock file goes in the module, its example and every unit that uses it, with hashes for all four platforms (`.claude/skills/dependency-versioning`).
- A unit: a `terragrunt.hcl` that `include`s `root.hcl`, names its module with `terraform { source = ... }` and passes `inputs`. The backend and provider come from `root.hcl`: don't write them in the unit.
