# 0002. Short-lived CLI credentials with `aws login`, no access keys

- **Status:** accepted
- **Date:** 2026-11-23
- **Deciders:** @haimlevtov

## Context

- Humans need AWS credentials on their machines for `plan`, read-only checks and the commands CLAUDE.md reserves for humans. CI never uses human credentials: it reaches AWS only through GitHub OIDC.
- The rule is "no static keys" (CLAUDE.md → Rules, rule 5). A long-lived access key on a laptop is the classic leak: copied into a repo, a backup or a log, it works until someone notices.
- The account is a standalone account and will not join AWS Organizations. IAM Identity Center, the usual answer for short-lived human access, needs an organization.
- AWS CLI 2.32+ has `aws login`, verified in the AWS docs on 2026-11-23:
  - it signs in through the browser with console credentials and works with named profiles (`--profile`)
  - sessions last up to 12 hours, and the CLI and SDKs refresh the credentials every 15 minutes
  - credentials are cached under `~/.aws/login/cache`

## Decision

- The root user is locked away: MFA on, no access keys, unused day to day.
- People sign in as IAM users in a group with the needed policy (today: `Administrators` with `AdministratorAccess`), with **MFA and no access keys**.
- The CLI gets credentials with `aws login --profile rarebit`. Inside the repo, `.mise.toml` sets `AWS_PROFILE=rarebit`, so commands never fall back to a `default` profile that might point at another account.
- Contributors run `aws sts get-caller-identity` before any AWS command.
- Terraform's AWS provider will set `allowed_account_ids`, so `plan`/`apply` refuse to run in any other account.

## Alternatives considered

| Option | Why not |
|---|---|
| Access keys on the IAM user | A long-lived secret on disk, valid until rotated or revoked |
| Access key + `aws sts get-session-token` with MFA | Short-lived sessions, but the long-lived key still sits on disk |
| aws-vault | Encrypts the key at rest and handles MFA sessions, but a long-lived key still exists |
| IAM Identity Center (`aws sso login`) | Needs AWS Organizations |

## Consequences

- **Good:** no long-lived AWS secret exists on any machine; a lost laptop leaks at most a session lasting under 12 hours; MFA applies through the console sign-in.
- **Bad / risks:** a new sign-in at least every 12 hours. Older SDKs and tools may not read console credentials (to verify for Terraform, Terragrunt and `aws eks get-token`). The documented fallback is `credential_process = aws configure export-credentials --profile rarebit --format process`.
- **Follow-ups:** verify the Terraform/Terragrunt/kubectl compatibility when the first module and the cluster exist; add the `allowed_account_ids` guard in the generated provider block.

## How we'll know it was right

- The IAM credential report shows no active access keys for human users.
- No tool needs a long-lived key to work.
