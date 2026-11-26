# 0001. Run on AWS in eu-central-1 (Frankfurt)

- **Status:** accepted; the Terragrunt live-layer path superseded by ADR 0033
- **Date:** 2026-11-23
- **Deciders:** @haimlevtov

## Context

- Rarebit's players are Hebrew speakers, mostly in Israel, so latency to them matters somewhat. Rounds are 20 seconds, so a few tens of milliseconds don't change the game, but every answer acknowledgement and timer update makes a round trip.
- The platform must stay cheap: it runs only during work sessions and demos (`plat env up` / `plat env down`).
- Measured on 2026-11-23:
  - EKS versions in eu-central-1: 1.34 to 1.37 are in standard support (1.34 until 2026-12-02; 1.37 is the default, until 2027-12-01)
  - TCP connect time from both CI runner fleets to eu-central-1 endpoints: 94–102 ms (`docs/benchmarks/ci-runners.md`), so the runners are far from Frankfurt

## Decision

All regional AWS resources live in **eu-central-1**: Terraform state, ECR, the VPC, EKS and its add-ons. The tooling sets the region (`AWS_REGION` in `.mise.toml`), and the Terragrunt live layer is `infra/live/prod/eu-central-1/`. Clusters target the newest EKS version in standard support (1.37 today).

## Alternatives considered

| Option | Why not |
|---|---|
| us-east-1 (N. Virginia) | Usually the cheapest region, with the most spot capacity, and close to the CI runners. But it's roughly twice as far from the players (an estimate, not measured). |
| il-central-1 (Tel Aviv) | Closest to the players. But it's typically more expensive, has fewer instance families and spot pools, and new services and features reach it later. |
| eu-west-1 (Ireland) | Similar cost and capacity to Frankfurt, and farther from the players. |

## Consequences

- **Good:** lower latency for players than a US region; data stays in the EU (the game stores no personal data beyond a nickname, but it's a sensible default).
- **Bad / risks:**
  - EC2, ALB and EBS usually cost about 10–20% more than us-east-1 (the EKS control plane and public IPv4 cost the same), so the cost model has to be re-priced for this region
  - spot capacity is smaller, so Karpenter NodePools allow several instance families and sizes, with an on-demand fallback
  - image pushes from the CI runners (far from Frankfurt) cross the Atlantic
- **Follow-ups:** re-price `docs/cost.md` with eu-central-1 prices; measure ECR push time from each runner fleet in `runner-edge.yml`.

## How we'll know it was right

- Next-day Cost Explorer actuals stay within ±30% of the re-priced model.
- Karpenter rarely fails to find spot capacity.
- p95 answer acknowledgement time meets its SLO for players in Israel.
