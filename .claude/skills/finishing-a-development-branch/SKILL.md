---
name: finishing-a-development-branch
description: Use when implementation is complete and checks pass, to decide how to integrate the work. In this repo integration always goes through a pull request and the merge queue, never a local merge or a push to main.
---

# Finishing a Development Branch

## Overview

**Core principle:** Verify → Present options → Execute choice → Clean up only what you own.

`main` changes only through pull requests and the merge queue (`CLAUDE.md` → Rules, rule 1). There
is no local-merge option in this repo.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## Step 1: Verify

On the exact tree you're about to push:

```bash
make check
```

Quote the output. **If it fails**, report the failures and stop; the menu comes after a green run.

Then check:
- `git log origin/main..HEAD`: Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`,
  `infra:`), one issue's worth of change, no WIP commits
- the docs moved with the code (`CLAUDE.md` → Documentation map)
- the `cleanup` skill has run on this diff (it dispatches the reviewer agents)

## Step 2: Detect environment

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
WORKTREE_PATH=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)    # empty on a detached HEAD
```

The base branch is `main`: branches are cut from `origin/main`. If this one was cut from something
else, confirm the base with the user before opening the PR.

## Step 3: Present options

**On a named branch:**

```
Implementation complete. What would you like to do?

1. Push and open a pull request
2. Keep the branch as-is (I'll handle it later)

Which option?
```

**On a detached HEAD:**

```
Implementation complete. You're on a detached HEAD (externally managed workspace).

1. Push as a new branch and open a pull request
2. Keep as-is (I'll handle it later)

Which option?
```

Present the menu exactly as written and wait. The integration decision is the user's.

## Step 4: Execute choice

### Option 1: Push and open a pull request

```bash
git push -u origin "$BRANCH"
# From a detached HEAD: git push origin HEAD:refs/heads/<new-branch>
gh pr create --base main --title "<type>: <summary>" --body-file <file>
```

- **Title:** a Conventional Commit, e.g. `feat(game): add room codes`.
- **Body:** what changed and why; how it was verified (the command output); the linked issue.
- **Infra, CI, Argo CD or policy changes** also need: the exact commands a human must run
  (`CLAUDE.md` → Rules, rule 2), the Infracost diff for infra changes (rule 6), and a note that
  CODEOWNERS approval is required.
- **PR text is public.** Reread the title and body before creating the PR.

Report the PR URL. Merging is the user's decision: once checks and approvals are green, the PR goes
through the merge queue. Don't run `gh pr merge` unless the user asks.

Keep the worktree: PR feedback gets fixed there.

### Option 2: Keep as-is

Report: "Keeping branch <name>. Worktree preserved at <path>."

### If the user asks to discard the work

This path exists only as a response to an explicit request to throw the work away. Confirm first:

```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Wait for that exact word. Then clean up the worktree (Step 5) and force-delete the branch:
`git branch -D <branch>`.

## Step 5: Clean up the workspace

**Runs only after the PR is merged or closed, or after a confirmed discard.** Run it from the main
checkout, never from inside the worktree being removed.

Clean up **only worktrees under `../rarebit-agents/`**. Worktrees anywhere else belong to the host
environment: leave them.

```bash
git worktree remove "$WORKTREE_PATH"
git branch -d "$BRANCH"      # -d refuses an unmerged branch; after a squash merge, confirm the PR merged, then -D
git worktree prune
```

**If removal is refused** (`contains modified or untracked files`): those files exist nowhere else.
Never `--force` on your own initiative. Show the user:

```bash
git -C "$WORKTREE_PATH" status --porcelain -uall
```

```
Worktree removal refused — these files were never committed:

<file list>

1. Commit them to <branch> before cleanup
2. Move them into the main checkout
3. Delete them (unrecoverable)

Which?
```

Carry out the choice, then remove the worktree.

## Quick Reference

| Option | Push | Opens PR | Keeps worktree | Branch cleanup |
|--------|------|----------|----------------|----------------|
| 1. Push and open PR | yes | yes | yes, until merged or closed | after merge |
| 2. Keep as-is | - | - | yes | - |
| Discard (explicit request only) | - | - | - | yes (force) |

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "A local merge is quicker" | `main` changes only through PRs and the merge queue. There is no local-merge path. |
| "It's a one-line fix, I'll push it to main" | Never. One issue = one small PR, even for one line. |
| "Checks passed earlier this session" | Run `make check` on the tree you're about to push. A green run only proves the tree it ran on. |
| "They obviously want it merged" | Merging is the user's call, through the merge queue. Open the PR and wait. |
| "The push was rejected, force-push will fix it" | A rejected push means the remote moved. Investigate; force-push is denied in this repo's settings. |
| "PR text is only for us" | PR titles and bodies are public. Reread them before creating. |
| "The PR is up, so the worktree is clutter" | PR feedback gets fixed in that worktree. It stays until the work lands. |
| "This other worktree looks stale, I'll clean it too" | Clean up only your own, under `../rarebit-agents/`. |
| "Removal refused, `--force` finishes the cleanup" | The refusal means files exist only in that worktree. Ask first. |
