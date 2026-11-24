# Service catalog

One file per service, `catalog/<service>.yaml`: who owns it, how critical it is, what it depends on, and where its runbook and SLOs are. The fields follow the [Backstage](https://backstage.io/docs/features/software-catalog/descriptor-format) `Component` format, so a portal can read them later. The `plat` CLI will read them too.

| Field | Meaning |
|---|---|
| `metadata.name` | the service name, the same as `app.kubernetes.io/name` |
| `metadata.description` | one sentence: what it does |
| `metadata.labels.tier` | how players feel an outage, the same value as the `tier` Kubernetes label (below) |
| `metadata.links` | the runbook and the README |
| `spec.type` | `service` for a long-running server, `job` for batch work |
| `spec.lifecycle` | `experimental` until it runs in a shared environment, then `production` |
| `spec.owner` | who's accountable for it (`user:<github-login>`); the `owner` Kubernetes label carries the login alone, since label values can't contain `:` |
| `spec.system` | always `rarebit`, the same as `app.kubernetes.io/part-of` |
| `spec.dependsOn` | what it needs at runtime |

SLOs are added when the monitoring stack records them: each one's indicator, target and window, in a place in the file chosen then. Until a service has SLOs, its file says so in a comment.

Tiers:

| Tier | Meaning |
|---|---|
| `1` | Players can't play, or a round can't finish correctly, without it |
| `2` | A feature degrades, and the game goes on |
| `3` | Batch or offline work; players don't notice for hours |

A new service gets its file in the same PR that adds it (CLAUDE.md → Documentation map).
