# 0033. A thin Terragrunt live layer over plain Terraform modules

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner
- **Supersedes:** the live-layer path in ADR 0001 (`infra/live/prod/eu-central-1/`). The project runs in one region, so there's no region directory: units go under `_global`, and later `dev` and `prod`.

## Context

- The AWS setup splits into many small units: the state bucket, CI access, registries, budgets, then the network, the cluster and its add-ons per environment. Each unit is its own state, so a mistake in one can't touch the others.
- Every unit needs the same backend settings, the same provider (region, the account check, the tags) and the same version constraints. Written out per unit, they drift apart.

## Decision

- **Modules** in `infra/modules` are plain Terraform: no Terragrunt functions, a pinned provider, `examples/basic` that runs with plain `terraform`, and tests in `tests/` against a mocked provider.
- **Live config** lives only in `infra/live`:
  - `root.hcl`: Terraform and Terragrunt version constraints, the generated provider and the generated backend (ADR 0032);
  - `env.hcl` in each environment directory: `_global` for the account's foundation, later `dev` and `prod`;
  - one `terragrunt.hcl` per unit: the module it runs, its inputs and its dependencies on other units.
- **The generated provider:**
  - `allowed_account_ids`, so plan and apply stop before touching any other account. The account ID comes from an environment variable, not from git (ADR 0035);
  - `default_tags` on every resource: `Project`, `Env`, `ManagedBy`, `Owner` and `Source` (the unit's path).

## Alternatives considered

| Option | Why not |
|---|---|
| Plain Terraform root modules, with the backend and provider written in each | The same 20 lines in every unit, and they drift |
| Terraform workspaces, one per environment | One config for every environment, with the target picked by a hidden setting: easy to apply to the wrong one |
| Terragrunt stacks (`terragrunt.stack.hcl`) | They generate units from a stack file: more indirection than about ten units need. Revisit when the unit count grows. |
| `infra/live/<env>/<region>/` as ADR 0001 planned | One region, so the extra level would always hold the same name |

## Consequences

- **Good:**
  - a unit is a few lines: module, inputs, dependencies;
  - the backend, provider and tags are in one place;
  - a module can be tested and used without Terragrunt.
- **Bad / risks:**
  - **Two tools to know,** and both pinned in `.mise.toml`.
  - **The generated files aren't in git:** `terragrunt render` shows the effective config.
  - **Working copies live outside the checkout,** in `~/.cache/terragrunt` (`TG_DOWNLOAD_DIR` in `.mise.toml`). Terragrunt makes its generated files read-only and replaces them by renaming a new file over them. On a Windows drive mounted into WSL that rename fails with `permission denied` (seen on 2026-11-26), and the Linux filesystem is faster for provider binaries.
  - **The state key is the unit's path,** so moving or renaming a unit means moving its state first (runbook → Move or rename a unit).

## How we'll know it was right

- Adding a unit takes a `terragrunt.hcl` with a source and inputs, and nothing copied from another unit.
- `terragrunt render` of any unit shows the same provider, tags and backend, apart from the state key and the `Source` tag.
