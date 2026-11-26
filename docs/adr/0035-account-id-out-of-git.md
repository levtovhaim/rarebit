# 0035. Keep the AWS account ID out of git: an environment variable locally, a masked secret in CI

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- Every unit's provider and backend check that the active credentials belong to the project account (`allowed_account_ids`, ADR 0002). The check needs the account ID as a fixed value: compared against itself, it would allow any account.
- The repo is public. AWS doesn't treat account IDs as secret, but a published ID makes the account easier to target (phishing that names it, guessing role names, finding resources shared by mistake), and it identifies the owner's account.
- CI logs are public too: anything a workflow prints, such as a plan's ARNs, ends up there.
- On 2026-11-26 a test showed that `allowed_account_ids = [""]` turns the provider's check off: a plan ran in an account that wasn't allowed. An empty value has to fail as hard as a missing one.

## Decision

- **One variable, `RAREBIT_AWS_ACCOUNT_ID`, read by `infra/live/root.hcl`** for the provider, the backend and the state bucket's name.
- **Locally,** each person sets it in `.mise.local.toml` in the repo root, which git ignores (`infra/README.md` → Setup). They take it from `aws sts get-caller-identity --profile rarebit`, after checking that it's the project account.
- **In CI,** from an Actions **secret**, which GitHub masks wherever it appears in a log, ARNs included. Not a repository variable: those aren't masked.
- **Fail closed:** `root.hcl` reads it with `regex("^[0-9]{12}$", get_env("RAREBIT_AWS_ACCOUNT_ID"))`. An unset variable, an empty one, or anything but 12 digits stops every unit before it reaches AWS. `make infra` checks that an empty value is refused.

## Alternatives considered

| Option | Why not |
|---|---|
| Commit the ID in `root.hcl` | The simplest, and the guard would then not depend on local config. But it publishes the ID, and CI logs would show it anyway. |
| A repository variable in CI | Not masked: plans, `init` output and `get-caller-identity` would print the ID into public logs |
| `get_aws_account_id()` for the check | It returns the account of whatever credentials are active, so the check would pass in any account |
| `get_env` alone | Fails when the variable is unset, but passes an empty value, which turns the provider's check off |

## Consequences

- **Good:**
  - the ID isn't in git or in CI logs;
  - a missing, empty or mistyped ID stops everything before any AWS call.
- **Bad / risks:**
  - **One more setup step** for every person, and every agent worktree needs its own `.mise.local.toml`: without it, every Terragrunt command fails there (safely).
  - **Masking covers logs, not PR comments.** A plan posted as a PR comment would show the ID: the plan workflow replaces it before posting (issue #62).
  - **Image URIs in deploy values** contain the ID (`<id>.dkr.ecr...`); deploy config will have to build them at run time, or the ID becomes public there.

## How we'll know it was right

- `git log -p` and the CI logs never show the 12-digit ID.
- With the variable unset, empty or wrong, `terragrunt plan` fails before reaching AWS, and `make infra` fails if a unit renders with an empty ID.
