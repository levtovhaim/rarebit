# 0004. Use the Claude API for LLM features, Haiku for volume and Sonnet for curation

- **Status:** accepted
- **Date:** 2026-11-23
- **Deciders:** @haimlevtov

## Context

Three planned features call an LLM:
- AI player personas in the test arena
- content agents that propose word lists and categories (by PR only)
- a scheduled exploratory QA agent

Constraints:
- LLM spend is capped at about $10 a month, with a per-run token cap and a kill switch (`LLM_ENABLED`).
- The AWS budget is reserved for the platform itself.

## Decision

- **Provider:** the Claude API, billed directly. It's a separate bill from AWS, with a hard ceiling: prepaid credits, auto-reload off.
- **Models, by workload** (prices per million tokens, input/output, as listed on 2026-11-23; re-checked before use):

  | Workload | Model | Price |
  |---|---|---|
  | personas, tournament, QA explorer | Haiku 5.5 | $0.10 / $0.50 |
  | curator, category creator (through the Batches API, half price) | Sonnet 5.5 | $2 / $10 |

- **Limits:**
  - A monthly spend cap returns HTTP 429 with `enforced_spend_limit_reached` and no `retry-after`. Code treats it like the kill switch: it stops calling the API and marks the LLM part of the run "skipped: budget". It never retries.
  - Ordinary rate-limit 429s are retried by the SDK.
- **The key** is created only when the first feature needs it. It's stored in SSM Parameter Store (in the cluster, through External Secrets) and in a GitHub environment secret limited to the jobs that use it, never in git.

## Alternatives considered

| Option | Why not |
|---|---|
| Amazon Bedrock | No stored key (IAM through OIDC and Pod Identity), a real advantage. But its spend would come out of the same AWS budget as the platform. |
| A self-hosted open model | GPU cost and operations far beyond the budget |
| No LLM features | Loses the arena personas, the content pipeline and exploratory QA |

## Consequences

- **Good:** a hard monthly ceiling independent of AWS; the cheapest capable model does the volume work.
- **Bad / risks:** a stored API key exists (mitigated: environment-scoped, rotated, created only when needed). Player text (answers, nicknames) reaches the models, so it's treated as data, never instructions, and model output is schema-constrained and reviewed by PR.
- **Follow-ups:** measure real token use per persona game and per curator run, and replace the cost sketch with actuals.

## How we'll know it was right

- Monthly LLM spend stays under the cap with the features on.
- The kill switch and the spend-cap path are tested on purpose once.
