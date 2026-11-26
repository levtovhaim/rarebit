# 0034. Terraform creates its own state bucket: the first apply on local state, then a migration

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- Every unit keeps its state in one S3 bucket (ADR 0032). That bucket is infrastructure too, so its settings belong in reviewed code that Terraform applies and records like any other resource.
- But Terraform needs a backend before it can create anything, and this backend is the bucket that doesn't exist yet: the unit that creates the bucket can't start with its state inside it.
- The same problem comes back if the account is ever rebuilt, or the bucket is lost.

## Decision

- **The bucket is a normal Terraform unit,** `infra/live/_global/bootstrap`, running the `state-bootstrap` module, with the S3 backend from `root.hcl` like every other unit.
- **Its first apply keeps the state locally.** With `RAREBIT_BOOTSTRAP_LOCAL_STATE=true`, the unit generates `backend_override.tf`, a Terraform override file that replaces the S3 backend with a local file next to the unit (`bootstrap.tfstate`, which git ignores). Without the variable, Terragrunt removes the override again.
- **Then the state moves into the bucket:** `terragrunt run -- init -migrate-state` copies it, and a `terragrunt plan` that says `No changes` proves the copy is complete. The local file is then deleted.
- **Terragrunt never creates or changes the bucket:** no `--backend-bootstrap`, and `disable_bucket_update` in the backend settings.
- The steps are the runbook's "Bootstrap from nothing" ([runbook](../runbooks/terraform-state.md)). They ran for real on 2026-11-26.

## Alternatives considered

| Option | Why not |
|---|---|
| Terragrunt's `--backend-bootstrap` | Terragrunt creates the bucket with its own defaults, and nothing records them: the bucket isn't in any Terraform state, and its settings aren't in reviewed code. Two tools would then own one bucket. |
| Create the bucket by hand, then `import` it | The same end state, but its first step is an unreviewed console or CLI action. Import is the right tool for resources that already exist (the budgets). |
| Keep the bootstrap unit on local state for good | No locking and no history for the unit that matters most, and its state would live on one laptop |
| A comment-out-the-backend edit for the first apply | Works, but it's an edit to committed code that has to be undone by hand; the variable leaves the code as it is and switches itself off |

## Consequences

- **Good:**
  - the bucket's settings are reviewed code with a state of their own, and changing them is a normal plan and apply;
  - the procedure needs no edit to committed files, and the runbook can repeat it.
- **Bad / risks:**
  - **A leftover `RAREBIT_BOOTSTRAP_LOCAL_STATE=true`** after the migration points the backend back at a local file. Terraform stops with `Backend configuration changed` instead of switching, so it fails safe, but the error has to be understood (runbook).
  - **Terragrunt copies the unit's directory into its working copy,** so a local state file there would be copied too and never removed. `exclude_from_copy` keeps state files out.
  - **If the bucket is lost,** so is every other unit's state: after the bootstrap, each unit comes back with `import` blocks.

## How we'll know it was right

- 2026-11-26: the first apply created 7 resources with local state, the migration copied the state (same size, serial 1), and the next plan said `No changes` reading from S3.
- Rebuilding from nothing, following the runbook, works without editing a committed file.
