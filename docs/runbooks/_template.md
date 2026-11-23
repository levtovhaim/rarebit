# Runbook: alert name or failure mode

- **Alert(s):** `AlertName` (link to the rule)
- **Service:** `catalog/<service>.yaml`
- **Severity:** page | ticket
- **Last fired on purpose:** YYYY-MM-DD (every alert is triggered deliberately at least once)

## What it means

What the alert measures, and what is probably broken when it fires.

## Impact on players

What players notice, and how fast it gets worse.

## Diagnose (first 5 minutes)

1. Events → `describe` → `logs --previous` → controller logs → CloudTrail (the triage order in the `systematic-debugging` skill)
2. The dashboard panels and queries to look at
3. The commands, read-only

## Fix

Steps in order. Mark every state-changing command, and say who may run it (CLAUDE.md → Rules, rule 2).

## Verify

How to prove it's fixed: the metric, the query or the request.

## Roll back or escalate

## Prevention

What would stop this from happening again (link the issue).
