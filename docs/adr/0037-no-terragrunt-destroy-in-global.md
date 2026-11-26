# 0037. Terragrunt's destroy command never runs in the account's foundation units

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- `infra/live/_global` holds the account's foundation, shared by every environment:
  - the state bucket (ADRs 0032, 0034);
  - the image registries (ADR 0036);
  - later, CI access and the budgets.

  Losing one of them takes down CI, deployments or the record of everything Terraform manages.
- Environments come and go: the platform is torn down every night (`plat env down`). A `terragrunt run --all destroy` started one directory too high, in `infra/live`, would reach `_global` too.
- Terragrunt's `exclude` block can leave units out of a run for given commands, both in a `run --all` and, with `no_run = true`, in the unit itself.

## Decision

- **One `exclude` block in `infra/live/root.hcl`,** shared by every unit: for `_global` units (`env = "global"`), `actions = ["destroy"]` and `no_run = true`.
  - A `run --all destroy` leaves them out of its queue.
  - A `destroy` in the unit itself prints `Early exit … due to exclude block with no_run = true` and exits 0. Nothing is destroyed.
- **What it doesn't stop:** `apply -destroy`, a `plan -destroy` applied later, or a resource removed from the code. These delete through `apply`, and the guard only knows the command name. So every `_global` module also sets `prevent_destroy` on what matters (the bucket and its versioning and policy, the repositories): a plan that would delete them fails, whatever the command. Review and CLAUDE.md rule 2 come before any apply.
- **`make infra` checks the guard:** `terragrunt find --as destroy` must list no `_global` unit, while `--as plan` lists them.
- **Taking a `_global` unit down on purpose** starts with a reviewed PR that changes this block and the modules' `prevent_destroy`.

## Alternatives considered

| Option | Why not |
|---|---|
| `prevent_destroy` alone | It stops the deletion, but only after a `destroy` has started and failed at plan; the exclude block keeps `_global` out of environment teardowns cleanly |
| An IAM deny on deleting these resources | The right long-term control, but the human admin role does everything today; it comes with roles that aren't admin |
| Keeping `_global` in another directory tree | `run --all` from the wrong directory would still reach it, and one `root.hcl` for everything is simpler |
| Nothing: rely on review | `destroy` isn't reviewed; it's a command someone types |

## Consequences

- **Good:**
  - an environment teardown can't reach the foundation;
  - an accidental `destroy` in a `_global` unit does nothing;
  - the check runs in every `make infra`.
- **Bad / risks:**
  - **A refused destroy exits 0:** in a script it looks like success, so the message is the only sign.
  - **The guard covers the command, not the intent:** `apply -destroy` gets past it, and `prevent_destroy` has to catch that.
  - **New `_global` units are covered automatically,** but their modules must set `prevent_destroy` themselves.

## How we'll know it was right

- `make infra` reports the `_global` units and none queued for destroy, and fails when the block is removed (checked on 2026-11-26).
- No `_global` resource is ever deleted by an environment teardown.
