# 0006. Gate aws and gh api calls with an allowlist hook, not ask rules

- **Status:** accepted
- **Date:** 2026-11-23
- **Deciders:** platform owner

## Context

Claude Code checks every shell command against the permission rules in `.claude/settings.json`. The rules are evaluated deny, then ask, then allow; a matching ask rule prompts even when a more specific allow rule also matches. So the broad rules `Bash(aws *)` and `Bash(gh api *)` made every read (`aws sts get-caller-identity`, `gh api repos/...`) prompt, and no allow rule could relax that.

Two more gaps showed up while checking the rules against the documentation:

- `Bash(...)` rules don't cover the PowerShell tool, which has its own `PowerShell(...)` rules. On Windows, the same command sent through PowerShell met no ask rule at all.
- A rule like `Bash(kubectl delete *)` misses `kubectl -n x delete pod y`, because a flag comes before the verb.

## Decision

- A PreToolUse hook, `.claude/hooks/readonly-gate.sh`, decides `aws` and `gh api` calls. One plain read-only call (optionally piped into a text filter) is allowed. Any other command that runs `aws` or `gh api`, including any command the hook can't parse, asks. Commands that don't mention them get no decision from the hook.
- An `aws` read is `describe-*`, `list-*`, `get-*` or `s3 ls`, except calls that print secrets or create credentials (`get-*secret*`, `*password*`, `*token*`, `*credential*`, `*access-details*`, any `--with-decryption`), Cost Explorer (billed per request), `configure`, and downloads to local files. A read runs without a prompt only when it targets the project profile (`--profile rarebit` or `AWS_PROFILE`); the project settings set `AWS_PROFILE` and `AWS_REGION`, so sessions don't fall back to a machine's default profile.
- A `gh api` read is a call without flags that set the method, headers or body.
- The broad `Bash(aws *)` and `Bash(gh api *)` ask rules are removed. A short list of `aws` write verbs (`create-`, `delete-`, `modify-`, `put-`, `run-`, `terminate-`, `update-`) stays as ask rules, so they still prompt if hooks are disabled.
- Every ask and deny rule exists for both `Bash(...)` and `PowerShell(...)`, written as `tool *verb*` so flags before the verb still match.
- The hook runs with `onFailure: block`: if it can't run (no bash or jq), the `aws` or `gh` call is blocked, not allowed.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep `Bash(aws *)` as an ask rule | Every read prompts; agents and humans click through prompts until they stop reading them. |
| Replace it with ask rules for every `aws` write verb | About 70 verb prefixes for each shell, and it fails open: a write verb missing from the list runs without a prompt. |
| Allow only the exact `aws` operations we already use | Safest, but every new read prompts until someone adds it. The read prefixes plus carve-outs cover far more with a short list; a new secret-printing `get-*` operation is the residual risk, and IAM still bounds it. |
| `bypassPermissions` mode | Removes the human check on infrastructure-changing commands that CLAUDE.md rule 2 relies on. |

## Consequences

- **Good:** reads run without prompts; anything the gate doesn't recognise still prompts (fail closed); one tested script holds the policy, with table tests in `.claude/hooks/test-readonly-gate.sh`, run by `make check`.
- **Bad / risks:** the hook adds a bash and jq start to each shell call that mentions `aws` or `gh`. The gate matches command text, so a deliberately obfuscated command can get past it. It is a guard against mistakes, not a security boundary: the boundary is what the session's AWS role and GitHub token may do.
- **Follow-ups:** give agent sessions a read-only AWS role, so the gate and IAM agree; extend the gate to `kubectl`, `terraform` and `helm` reads once there is a cluster.

## How we'll know it was right

Prompts for `aws` and `gh api` reads disappear from agent transcripts, writes keep prompting, and no change to AWS or GitHub happens without a prompt. A gate bug found in review or in a drill gets a test row first, then the fix.
