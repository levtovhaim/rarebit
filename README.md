# Rarebit

A real-time multiplayer word game in the style of Eretz Ir (ארץ עיר), played from phones, and the internal developer platform it runs on.

Each round shows a Hebrew letter and a category, and every player has 20 seconds to answer. The rarer your valid answer, the more points it scores. Players join a private room with a code, or use public quick play.

## Status

Early setup: the game runs locally, web UI included (`make up`, below, then play at http://127.0.0.1:8080); no platform yet. In place so far: the contributor rules, shared tooling for agents and reviewers, the CI runner evaluation ([results](docs/benchmarks/ci-runners.md)), permission guardrails for agent sessions (ADRs [0006](docs/adr/0006-agent-permission-gate.md) and [0007](docs/adr/0007-infra-changes-by-human-approval.md)), the C++ Hebrew normalization library ([native/hebrew-normalize](native/hebrew-normalize/README.md), `make native`), seed word lists for the six regular categories ([data/](data/README.md)), the Go validator that checks answers against them in Postgres, with its container image ([apps/validator](apps/validator/README.md), `make validator`, `make validator-image-smoke`), the game server, which keeps every room in Redis so any pod can serve it, with its container image ([apps/game](apps/game/README.md), `make game`, `make game-image-smoke`), the bots that play it: the synthetic game, load tests and the chaos observer ([apps/bots](apps/bots/README.md), `make bots`), the local stack that runs them all ([compose/](compose/README.md)), and the web UI for phones, in Hebrew, with its nginx image ([apps/web](apps/web/README.md), `make web`, `make web-image-smoke`). What exists and what's planned: [docs/architecture.md](docs/architecture.md). The CI golden path, the Kubernetes platform and the infrastructure arrive in small pull requests.

## What it will include

- **Game services:** a React web UI (Hebrew, RTL), a Node.js + Socket.IO game server that keeps all room state in Redis, a Go validator backed by a C++ Hebrew normalization library, and simulated players for load and end-to-end tests.
- **A platform around them:** golden-path templates, one shared Helm chart, reusable GitHub Actions workflows, GitOps with Argo CD, a preview environment per pull request, policy guardrails, observability with SLOs, and cost controls.
- **Built for many parallel contributors, human or AI agent:** CI scoped to what changed, a merge queue, isolated previews and least-privilege identities.

## Set up a machine

1. On Windows, work inside WSL (Ubuntu): the tools, scripts and hooks assume a Linux shell ([ADR 0003](docs/adr/0003-tool-versions-with-mise.md)). Install [mise](https://mise.jdx.dev), then run `mise install` in the repo root. It installs the pinned tool versions from `.mise.toml` (Terraform, Terragrunt, kubectl, Helm, kind, linters and scanners, language runtimes, CMake and Ninja), and inside this directory it sets `AWS_PROFILE=rarebit`. The C/C++ compiler for `make native` and `make validator` comes from the OS (on Ubuntu: `sudo apt install build-essential`), the integration targets (`make *-integration`) need Docker, and the image targets (`make *-image`, `make *-image-smoke`, and `make up`, which builds the images) need Docker with BuildKit (the default since Docker 23) and curl.
2. Sign in to GitHub: `gh auth login`.
3. Maintainers with AWS access only: `aws login --profile rarebit`. It gives short-lived credentials from a console sign-in, so no access keys are stored.

## Run it locally

With Docker running:

```bash
make up      # Postgres, the validator, Redis, two game servers and the web UI behind nginx: play at http://127.0.0.1:8080
make smoke   # three bots play a full game through it
make down    # removes it all
```

What runs and how: [compose/README.md](compose/README.md).

## Contributing

Read [CLAUDE.md](CLAUDE.md) first. It holds the rules every contributor follows, the architecture and the documentation map. Every change goes through a pull request. Run `make check` before every commit. Changes to platform paths (CI and the runner policy, infrastructure, GitOps including per-environment values, the `plat` CLI and policies, ADRs, quality gates, tool and scanner config, agent rules and the service catalog) request a review from their code owners ([CODEOWNERS](.github/CODEOWNERS)). Decisions are recorded as ADRs in `docs/adr/`.

## License

[MIT](LICENSE)
