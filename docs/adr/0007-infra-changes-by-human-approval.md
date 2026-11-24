# 0007. Infra-changing commands run with a human's approval of the exact command

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

CLAUDE.md rule 2 said agents never run infra-changing commands (`terraform`/`terragrunt` apply and destroy, `plat env up/down`, helm writes, `aws` writes): they propose the command, and a human runs it. In practice the human ends up copying commands from the session into a terminal. That adds nothing: the decision that matters is whether this exact command should run now, not who types it.

Claude Code can already make that decision explicit. Commands matching an `ask` rule in `.claude/settings.json` stop for a prompt showing the exact command, and ask rules prompt in every permission mode except `bypassPermissions`.

## Decision

- An agent may run an infra-changing command only after a human approves that exact command in the Claude Code prompt. Before asking, the agent states the hourly cost impact.
- These commands stay **ask** rules (not deny) in `.claude/settings.json`, for both the Bash and PowerShell tools. Bypass mode is disabled in project settings (`disableBypassPermissionsMode: disable`), so the prompt can't be skipped.
- With no human at the prompt (headless or scheduled runs), the call is refused, and the agent proposes the command in its PR as before.
- Deny rules stay for actions that are never right here: force-pushes, `--no-verify`, and reading credential files and caches.

## Alternatives considered

| Option | Why not |
|---|---|
| Deny rules: the human always types the command | The same decision with extra copy-paste. A human copying a command from the session isn't a stronger check than approving it in the prompt. |
| Allow, and rely on IAM to stop mistakes | A session runs with an admin profile today; IAM wouldn't stop a wrong `apply`. |

## Consequences

- **Good:** one place where the human decides, with the exact command in front of them; the cost is stated each time; headless agents still can't change infrastructure.
- **Bad / risks:** an approval click can become routine. The prompt only shows the command, not its plan, so `terraform apply` must follow a reviewed `plan` in the same session. Project settings are in the repository, so a PR could weaken them; `.claude/` is code-owned for that reason.
- **Follow-ups:** an agent identity with no admin rights on AWS and GitHub (audit findings H2/M6), so a mistaken approval is bounded by IAM as well.

## How we'll know it was right

Every infra change in the session transcripts has a prompt approval right before it, and no infra change happens from a headless run.
