---
name: using-git-worktrees
description: Use when starting feature work that needs isolation from the current checkout, when several agents work in parallel, or before executing an implementation plan. Creates the worktree where this repo requires it (../rarebit-agents/<branch>, outside the main checkout) and checks a clean baseline.
---

# Using Git Worktrees

## Overview

Each piece of parallel work gets its own worktree, branch and PR (`CLAUDE.md` → Worktrees and
parallel work: one agent = one worktree = one branch = one PR).

**The hard rule in this repo:** worktrees live **outside** the main checkout, at
`../rarebit-agents/<branch>`. Never `.worktrees/`, `worktrees/` or `.claude/worktrees/` inside
the repo. Claude Code loads instruction files from every parent directory, and the main checkout
holds local, untracked config. A worktree nested inside it would pick that config up, and local
config must not leak into other workspaces.

**Announce at start:** "I'm using the using-git-worktrees skill to set up an isolated workspace."

## Step 0: Detect existing isolation

**Before creating anything, check whether you're already in a worktree.**

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
BRANCH=$(git branch --show-current)
```

**Submodule guard:** `GIT_DIR != GIT_COMMON` is also true inside a git submodule. If this prints a
path, you're in a submodule, so treat it as a normal checkout:

```bash
git rev-parse --show-superproject-working-tree 2>/dev/null
```

**If `GIT_DIR != GIT_COMMON` (and not a submodule):** you're in a linked worktree. Check where:

- under `../rarebit-agents/`: report "Already in isolated workspace at `<path>` on branch
  `<name>`" and skip to Step 2. Do NOT create another worktree.
- anywhere inside the main checkout (for example `.claude/worktrees/`): stop and tell the user. It
  breaks the hard rule above, so don't work there.

**If `GIT_DIR == GIT_COMMON`:** you're in the main checkout. Unless the user already asked for
isolated or parallel work, ask first:

> "Would you like me to set up an isolated worktree? It protects your current branch from changes."

If they decline, work in place and skip to Step 2.

## Step 1: Create the worktree

**Don't use native worktree tools here.** `claude --worktree` and the `EnterWorktree` tool create
worktrees under `.claude/worktrees/` inside the repo by default, which breaks the hard rule. Before
using any tool that creates worktrees for you, check where it puts them; use it only if the path is
under `../rarebit-agents/`.

Use git directly, from the main checkout:

```bash
branch="<type>/<short-name>"      # e.g. feat/room-codes, fix/round-timer, agent/issue-42
git fetch origin
git worktree add "../rarebit-agents/$branch" -b "$branch" origin/main
cd "../rarebit-agents/$branch"
```

Branch names are public: use a Conventional Commit type as the prefix and a neutral, descriptive
name.

Verify before doing any work:

```bash
git rev-parse --show-toplevel     # must be a path under ../rarebit-agents/
git status --short                # must be empty
```

The worktree is outside the repo, so there's no `.gitignore` entry to add.

**Sandbox fallback:** if `git worktree add` fails with a permission error, tell the user the
sandbox blocked it and work in the current checkout instead. Never fall back to a directory inside
the repo.

## Step 2: Project setup

Install only what the apps you'll touch need:

```bash
npm ci              # in apps/web, apps/game or apps/bots
go mod download     # in apps/validator
uv sync             # in platform/cli
```

## Step 3: Verify a clean baseline

```bash
make check
```

On a fresh branch `make check` may have nothing to test yet, because it covers what changed. Also run
the tests of each app you're about to touch (`go test ./...` in `apps/validator`, `npx vitest run`
in `apps/game` or `apps/bots`).

**If tests fail:** report the failures and ask whether to proceed or investigate.

**If tests pass:** report ready:

```
Worktree ready at <full-path>
Tests passing (<N> tests, 0 failures)
Ready to implement <feature-name>
```

## Cleanup

When the PR is merged or closed, from the main checkout:

```bash
git worktree remove "../rarebit-agents/<branch>"
git branch -d "<branch>"      # -d refuses an unmerged branch; that's the point
git worktree prune
```

Never `--force` on your own. If removal is refused, the worktree holds files that exist nowhere
else: show the user `git -C "../rarebit-agents/<branch>" status --porcelain -uall` and ask.

## Quick Reference

| Situation | Action |
|-----------|--------|
| Already in a worktree under `../rarebit-agents/` | Skip creation (Step 0) |
| In a worktree inside the main checkout | Stop and tell the user |
| In a submodule | Treat as a normal checkout |
| Native worktree tool available | Don't use it unless it creates under `../rarebit-agents/` |
| Creating a worktree | `git worktree add ../rarebit-agents/<branch> -b <branch> origin/main` |
| Permission error on create | Work in place; never inside the repo |
| Baseline tests fail | Report the failures and ask |
| PR merged or closed | `git worktree remove`, `git branch -d`, `git worktree prune` |

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "I'm obviously not in a worktree, no need to check" | Run Step 0. Harness-created worktrees and submodules both fool eyeballing. |
| "The native tool handles placement, so use it" | Here its default placement is the problem: `.claude/worktrees/` is inside the repo. Check the path first. |
| "`.worktrees/` is git-ignored, so it's fine" | Being ignored isn't the issue. A worktree inside the checkout sits under its local config, which then loads into that session. |
| "I'll branch from my current branch, it's close enough" | Branch from `origin/main`. Otherwise the PR carries unrelated commits. |
| "The workspace is fresh, baseline tests can wait" | A dirty baseline makes every later failure ambiguous. Run them now. |
| "Removal refused, `--force` just finishes the job" | The refusal means files exist only there. `--force` destroys them. Ask first. |
