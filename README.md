# Rarebit

A real-time multiplayer word game in the style of Eretz Ir (ארץ עיר), played from phones, and the internal developer platform it runs on.

Each round shows a Hebrew letter and a category, and every player has 20 seconds to answer. The rarer your valid answer, the more points it scores. Players join a private room with a code, or use public quick play.

## Status

Early setup: nothing runs yet. This first commit holds the contributor rules and the shared tooling for agents and reviewers. The game services, the CI golden path, the Kubernetes platform and the infrastructure arrive in small pull requests.

## What it will include

- **Game services:** a React web UI (Hebrew, RTL), a Node.js + Socket.IO game server that keeps all room state in Redis, a Go validator backed by a C++ Hebrew normalization library, and simulated players for load and end-to-end tests.
- **A platform around them:** golden-path templates, one shared Helm chart, reusable GitHub Actions workflows, GitOps with Argo CD, a preview environment per pull request, policy guardrails, observability with SLOs, and cost controls.
- **Built for many parallel contributors, human or AI agent:** CI scoped to what changed, a merge queue, isolated previews and least-privilege identities.

## Contributing

Read [CLAUDE.md](CLAUDE.md) first. It holds the rules every contributor follows, the architecture and the documentation map. Every change goes through a pull request.

## License

[MIT](LICENSE)
