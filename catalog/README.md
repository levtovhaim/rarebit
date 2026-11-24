# Service catalog

One file per service, `catalog/<service>.yaml`: who owns it, how critical it is, what it depends on, and where its runbook and SLOs are. The fields follow the [Backstage](https://backstage.io/docs/features/software-catalog/descriptor-format) `Component` format, so a portal can read them later, plus a top-level `slos` field of our own. The `plat` CLI will read them too.

| Field | Meaning |
|---|---|
| `metadata.name` | the service name, the same as `app.kubernetes.io/name` |
| `metadata.labels.tier` | how players feel an outage, the same value as the `tier` Kubernetes label (below) |
| `metadata.links` | the runbook and the README |
| `spec.owner` | who's accountable for it (`user:<github-login>`); the `owner` Kubernetes label carries the login alone, since label values can't contain `:` |
| `spec.lifecycle` | `experimental` until it runs in a shared environment, then `production` |
| `spec.dependsOn` | what it needs at runtime |
| `slos` | each SLO's indicator and target. Empty until the monitoring stack records them. |

Tiers:

| Tier | Meaning |
|---|---|
| `1` | Players can't play, or a round can't finish correctly, without it |
| `2` | A feature degrades, and the game goes on |
| `3` | Batch or offline work; players don't notice for hours |

A new service gets its file in the same PR that adds it (CLAUDE.md → Documentation map).
