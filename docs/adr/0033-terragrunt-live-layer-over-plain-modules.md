# 0033. A thin Terragrunt live layer over plain Terraform modules

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- The AWS setup splits into many small units: the state bucket, CI access, registries, budgets, then the network, the cluster and its add-ons per environment. Each unit is its own state, so a mistake in one can't touch the others.
- Every unit needs the same backend settings, the same provider (region, the account guard, the tags) and the same version constraints. Written out per unit, they drift apart.
- The repo is public. The account ID is what the wrong-account guard checks against, so the code needs it, but it shouldn't be committed. AWS doesn't treat account IDs as secret, but a published one makes the account easier to target.

## Decision

- **Modules** in `infra/modules` are plain Terraform: no Terragrunt functions, a pinned provider, `examples/basic` that runs with plain `terraform`, tests against a mocked provider.
- **Live config** lives only in `infra/live`:
  - `root.hcl`: Terraform and Terragrunt version constraints, the generated provider and the generated backend (ADR 0032);
  - `env.hcl` in each environment directory: `_global` for the account's foundation, later `dev` and `prod`;
  - one `terragrunt.hcl` per unit: the module it runs, its inputs and its dependencies on other units.
- **The generated provider:**
  - `allowed_account_ids`, so plan and apply stop before touching any other account;
  - `default_tags` on every resource: `Project`, `Env`, `ManagedBy`, `Owner` and `Source` (the unit's path).
- **The account ID** comes from `RAREBIT_AWS_ACCOUNT_ID`. People set it in `.mise.local.toml`, which git ignores; CI will set it from a repository variable. `get_env` without a default fails when it's unset, so nothing runs without it.
- **Terragrunt's working copies** go to `~/.cache/terragrunt` (`TG_DOWNLOAD_DIR` in `.mise.toml`), outside the checkout. Terragrunt makes its generated files read-only and replaces them by renaming a new file over them. On a Windows drive mounted into WSL, that rename fails with `permission denied` (seen on 2026-11-26); the Linux filesystem is also much faster for provider binaries.

## Alternatives considered

| Option | Why not |
|---|---|
| Plain Terraform root modules, with the backend and provider written in each | The same 20 lines in every unit, and they drift |
| Terraform workspaces, one per environment | One config for every environment, with the target picked by a hidden setting: easy to apply to the wrong one |
| Terragrunt stacks (`terragrunt.stack.hcl`) | They generate units from a stack file: more indirection than about ten units need. Revisit when the unit count grows. |
| Commit the account ID | Simpler, but it publishes the ID; one environment variable avoids that |
| `get_aws_account_id()` for the guard | It returns the account of whatever credentials are active, so the guard would allow any account |

## Consequences

- **Good:**
  - a unit is a few lines: module, inputs, dependencies;
  - the backend, provider and tags are in one place;
  - a module can be tested and used without Terragrunt.
- **Bad / risks:**
  - two tools to know, and both pinned in `.mise.toml`;
  - the generated files aren't in git: `terragrunt render` shows the effective config;
  - one more environment variable to set before anything runs.
- **Follow-ups:** CI sets `RAREBIT_AWS_ACCOUNT_ID` from a repository variable when the plan workflow exists.

## How we'll know it was right

- Adding a unit takes a `terragrunt.hcl` with a source and inputs, and nothing copied from another unit.
- `terragrunt render` of any unit shows the same provider, tags and backend, apart from the state key and the `Source` tag.
