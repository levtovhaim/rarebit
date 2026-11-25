# 0024. Run the local stack with docker compose, two game replicas behind nginx

- **Status:** accepted; the `make smoke` bullet is superseded by ADR 0025 (smoke runs the bots image)
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

The services exist and are tested one by one: the validator and the game each against throwaway containers, the bots against two game processes and a fake validator. Nothing yet runs them all together: the real validator answering the real game, through a load balancer, with more than one game replica. A contributor also needs one command that brings the whole game up on a laptop, and another that proves it works (`make up`, `make smoke`).

The stack should behave like the cluster where it matters: no sticky sessions, hardened containers, health-gated startup, a drain on SIGTERM. Kubernetes itself comes later (kind, then EKS).

## Decision

- **docker compose**, one file (`compose/compose.yaml`), with Postgres, a one-shot `migrate` (the validator image), the validator, Redis, **two game replicas** and **nginx** in front of them.
- **nginx** (`nginx-unprivileged`, read-only) spreads WebSockets over the replicas round robin, with no sticky sessions, re-resolving their names through Docker's DNS, and retrying the other replica when one refuses the connection. It's the only service that publishes a port, on `127.0.0.1`.
- **Health-gated startup:** every long-running service has a healthcheck that runs its own readiness (`check-ready` in the validator and game images, which have no shell). `depends_on` uses only hard dependencies: the validator waits for `migrate` to finish; the game waits for Redis; nginx waits for the replicas to start. `make up` returns once every healthcheck passes (`up --wait`).
- **Hardened like the cluster:** our services and Redis run read-only, with no capabilities, no privilege escalation and a non-root user.
- **Our images come from the Make targets** (`make validator-image`, `make game-image`), the same builds the image smoke tests check; compose never builds or pulls them.
- **`make smoke`** runs the bots' synthetic game through nginx from the host (`apps/bots/dist`).
- **The Postgres password** is generated per stack into a git-ignored `compose/.env`.

## Alternatives considered

| Option | Why not |
|---|---|
| kind (local Kubernetes) as the first stack | It's the next step, with the shared chart and Argo CD. As the first way to run the services together, it adds a cluster to debug before the services have ever met. |
| One game replica, its port published | Simpler, but it can't show what matters most: a game shared across replicas and surviving one of them. |
| Traefik or HAProxy as the proxy | Either works. nginx-unprivileged is already the web UI's planned server, so the stack needs one proxy, not two. |
| Health-gating every service on every other (`service_healthy` everywhere) | It hides the failure modes the cluster has, where nothing orders startup; one unhealthy dependency would keep everything down. |
| Building our images in compose (`build:`) | A second build definition beside the Make targets, which pass `GIT_SHA` and are what the smoke tests check. |
| A bots container for `make smoke` | No bots image yet; it comes with the synthetic CronJob. The host has Node from `.mise.toml`. |

## Consequences

- **Good:**
  - `make up` and `make smoke` prove the services work together: the real validator, two replicas, Redis fan-out, through a proxy;
  - the drills (a replica killed, a replica drained) run on a laptop and finish every game (compose/README.md → Drills);
  - the compose file states each service's health and dependencies, input for the chart later.
- **Bad / risks:**
  - nginx can't take a draining replica out of rotation (no active health checks in open-source nginx): new connections to it fail with `400` until the client reconnects elsewhere. The cluster handles this with readiness;
  - `docker kill` isn't a crash: the restart policy doesn't bring the replica back, unlike Kubernetes;
  - a second description of how the services run, beside the Helm chart to come: they can drift.
- **Follow-ups:**
  - the web UI joins behind the same nginx;
  - a bots image, so `make smoke` needs only Docker;
  - `make smoke` in CI.

## How we'll know it was right

A new contributor gets a working stack with `make up` and a passing `make smoke` on the first try, and the drills keep passing as the services change.
