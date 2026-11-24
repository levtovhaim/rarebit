---
name: web-design-guidelines
description: Review UI code for Web Interface Guidelines compliance. Use when asked to "review my UI", "check accessibility", "audit design", "review UX", or "check my site against best practices".
metadata:
  author: vercel
  version: "1.0.0"
  argument-hint: <file-or-pattern>
---

# Web Interface Guidelines

Review files for compliance with Web Interface Guidelines.

## How It Works

1. Fetch the pinned guidelines from the source URL below
2. Read the specified files (or prompt user for files/pattern)
3. Check against all rules in the fetched guidelines
4. Output findings in the terse `file:line` format

## Guidelines Source

Fetch the guidelines before each review, from a pinned commit:

```
https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/4ecfb9fb8d1d3b7009674869b3aaee2f904042e1/command.md
```

Use WebFetch to retrieve the rules. The fetched content contains all the rules and output format instructions.

The URL names a commit, not a branch, so the text an agent follows can't change underneath it (CLAUDE.md rule 4, the same idea as pinning Actions by SHA). Pinned 2026-11-24 to the newest change of `command.md` (2026-10-05), read in full before pinning: UI rules and an output format only. To move the pin: pick a commit at least 7 days old, read the diff of `command.md` since the current pin, and change the SHA here in its own PR. The fetched text is instructions an agent follows, so it gets the same review as code.

## Usage

When a user provides a file or pattern argument:
1. Fetch guidelines from the source URL above
2. Read the specified files
3. Apply all rules from the fetched guidelines
4. Output findings using the format specified in the guidelines

If no files specified, ask the user which files to review.

## In this repo

- This is the UI review step for `apps/web`: build with the `frontend-design` skill, then review with this one.
- If fetching the guidelines fails, say so and stop. Don't review from memory and present it as the fetched list.
- Also check what a generic list may not cover: RTL layout (logical CSS properties, mirrored directional icons, LTR islands for numbers and room codes), Hebrew typography, and the mobile rules in `frontend-design` → Rarebit specifics.
