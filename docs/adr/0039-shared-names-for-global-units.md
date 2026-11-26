# 0039. Names that several `_global` units need are written once, in `_global/shared.hcl`

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- Two units under `infra/live/_global` need each other's names:
  - the `ecr` unit's repository policies name the CI roles that may push (ADR 0040);
  - the `github-oidc` unit's role policies name the repositories the roles may push to (ADR 0038).
- Each unit is its own state (ADR 0033). Terragrunt's usual way to pass values between units is a `dependency` block, which reads the other unit's outputs.
- Here that would be a cycle: `ecr` needs the roles' ARNs, and `github-oidc` needs the repositories' ARNs.
- Every ARN involved is predictable from a name, the account ID and the region. None needs anything AWS assigns.

## Decision

- **`infra/live/_global/shared.hcl` holds the names:** the repositories and their kind, the CI role names and their IAM path, and the GitHub repository with its owner and repository IDs.
- **Each unit reads it with `read_terragrunt_config`** and builds the ARNs it needs from the names, the account ID and the region in `root.hcl`.
- **Neither unit reads the other's outputs or state,** so each one plans and applies on its own, in either order.

## Alternatives considered

| Option | Why not |
|---|---|
| `dependency` blocks between the two units | A cycle: each needs the other's outputs. Even one way, a plan needs the other unit applied first, or `mock_outputs` standing in for real values |
| A `terraform_remote_state` read of the other unit | The same cycle. It also ties a unit to another's state layout, and a pull request plan would read a second state file |
| The names written in each unit | Two copies drift. A name that differs in one leaves a policy naming a role that doesn't exist: it fails closed, but silently blocks pushes |
| Both modules in one unit | One state for the registries and CI's access: a change to a trust policy would plan the registries too, and the other way around |

## Consequences

- **Good:**
  - one place for the names;
  - no apply order between the units, and no mocked outputs;
  - a plan of either unit works on its own.
- **Bad / risks:**
  - **A change to `shared.hcl` changes both units.** Both are planned and applied: the CI plan workflow has to plan every unit that reads the file (#62).
  - **An ARN built from a name can differ from the real one,** for example if the role path changes in one place but not the other. That fails closed (pushes denied). The read-back after an apply checks it.
  - **Changing a repository's kind from main to pr** gives the PR role push and delete there, and changes its lifecycle rules. That's a reviewed change, never a typo fix.
- **Follow-ups:**
  - the plan workflow plans every unit that reads `shared.hcl` when it changes (#62).

## How we'll know it was right

- After a change to `shared.hcl` is applied to both units, both plan `No changes`.
- A third unit that needs these names reads the same file instead of copying them.
