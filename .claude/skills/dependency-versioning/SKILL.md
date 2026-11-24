---
name: dependency-versioning
description: >-
  Use this skill whenever adding a dependency or changing the version of one in this repo: npm
  packages (apps/web, apps/game, apps/bots), Go modules (apps/validator), Python packages
  (platform/cli, uv), Terraform providers and modules, Helm charts, container base images, or
  GitHub Actions. Also for "are we up to date", "is it safe to add/upgrade X", "bump the deps",
  "why is this pinned", or reviewing a Dependabot/Renovate PR. It encodes the 7-day publish-age
  rule and its security exception, how to choose the newest safe version, how each ecosystem is
  pinned, the transitive-cascade trap, and the verification steps. Do NOT use for
  non-dependency work.
---

# Dependency Versioning

The one rule:

> **Use the NEWEST version that is BOTH (a) published at least 7 days ago AND (b) inside the
> compatibility envelope.** Never a release younger than 7 days; never "hold at current" when a
> newer safe version exists. The only override is the **security exception**: a known,
> already-disclosed advisory that the newer version fixes outranks the 7-day floor.

The floor guards against *undiscovered* risk: a brand-new release hasn't had time for a
supply-chain compromise or a regression to surface. A *known, already-fixed* CVE is the opposite
kind of risk, so it wins.

Two rules from `CLAUDE.md` apply on top: **pin everything** (Actions by full commit SHA, images by
digest, Terraform providers and modules and Helm charts by exact version), and **no dead
dependencies** (an unused dependency is pure supply-chain surface).

---

## Step 1: Choose the target version (newest safe, in the envelope)

Compute the cutoff (`today − 7 days`); don't eyeball it.

| Ecosystem | Where | Publish dates | Pin form |
|---|---|---|---|
| npm | `apps/web`, `apps/game`, `apps/bots` | `npm view <pkg> time --json` | exact version in `package.json`; `package-lock.json` committed |
| Go modules | `apps/validator` | `go list -m -json <module>@<version>` (the `Time` field); `go list -m -versions <module>` | `go.mod` + `go.sum` |
| Python (uv) | `platform/cli` | `https://pypi.org/pypi/<pkg>/json` (`upload_time_iso_8601`) | `uv.lock` committed |
| Terraform providers, modules | `infra/` | `gh release view <tag> --repo <owner>/<repo> --json publishedAt` | exact `version` in `versions.tf` and module blocks; `.terraform.lock.hcl` committed |
| Helm charts | `deploy/` | the `created` field of each version in the chart repo's `index.yaml`, or the GitHub release date | exact chart version / `targetRevision` |
| Container base images | `apps/*/Dockerfile` | the upstream release date of the tag | `image:tag@sha256:<digest>`; get the digest with `docker buildx imagetools inspect <image>:<tag>` |
| C++ (CMake `FetchContent`) | `native/cmake/*.cmake` | `gh release view <tag> --repo <owner>/<repo> --json publishedAt` | `URL` of an **uploaded release asset** (not GitHub's generated archive, whose bytes can change) plus `URL_HASH SHA256=…` from `sha256sum` of that file; a `# vX.Y.Z, published <date>` comment |
| GitHub Actions | `.github/workflows/` | `gh release view <tag> --repo <owner>/<action> --json publishedAt` | `uses: <owner>/<action>@<full-sha> # vX.Y.Z`; get the SHA with `git ls-remote --tags https://github.com/<owner>/<action> '<tag>*'` (for an annotated tag, the `^{}` line is the commit) |

The `# vX.Y.Z` comment after an Actions SHA is what lets Dependabot or Renovate keep bumping it.

Two failure modes to avoid:
- ❌ taking the newest release when it's under 7 days old;
- ❌ holding at the installed version when a newer **safe** one exists. "Up to date" means newest
  safe, not status quo.

### The compatibility envelope

| Class | Envelope | How to check |
|---|---|---|
| **Runtimes** (Node LTS, Go, Python) | The versions pinned in `.mise.toml`. Local tooling, Dockerfile base images and CI setup steps move together in one PR. | the three places agree |
| **Socket.IO** (`socket.io`, `socket.io-client`, `@socket.io/redis-adapter`) | Same major in `apps/game` and `apps/bots`; the adapter's peer range covers the server version | `npm view <pkg>@<version> peerDependencies` |
| **Terraform providers vs community modules** | A module (e.g. `terraform-aws-modules/eks`) declares the provider range it supports; the provider stays inside it | the module's `versions.tf` at that version |
| **Kubernetes addons** (charts) | Each chart supports a range of Kubernetes versions; the cluster's EKS version stays inside it | the chart's `kubeVersion` and release notes |
| **Everything else** | Newest within the current **major**. A new major only with its migration notes read and Step 4 green. | changelog + Step 4 |

---

## Step 2: Security exception (only when the newest version is under 7 days old)

Before holding at the older safe version, check whether the newer version fixes a **known advisory
that is open in the version you'd otherwise pick**:

```bash
trivy fs --scanners vuln .     # every lockfile in the repo (npm, Go, Python)
npm audit                      # in the app directory
govulncheck ./...              # in apps/validator; reports only vulnerable code paths you call
# plus the GitHub Advisory Database (https://github.com/advisories) for the package
```

- Take the under-7-day version **only** for a real, already-disclosed security fix, and **record
  the GHSA/CVE id** in the commit message and the PR.
- A routine patch batch is **not** a security exception, however large. Check each package.

---

## Step 3: Install, then check the transitive cascade (the trap)

**The trap:** bumping a hub package re-resolves its tree and can pull transitive dependencies up to
*their* newest release, which right after a batch release may be under 7 days old. Nothing you
named is young, but the lockfile is.

So after **every** bump, check what actually changed in the lockfile:

- **npm:** run from the repo root, with the app's lockfile:

  ```bash
  node .claude/skills/dependency-versioning/scripts/age-scan.cjs HEAD apps/<app>/package-lock.json
  ```

  For each `<7 DAYS` hit, pin the transitive to newest safe with `overrides` in `package.json`, or
  drop the hub bump. Re-run until it reports **0 violations**.
- **Go:** `git diff go.sum`, then check the `Time` of each changed module with `go list -m -json`.
- **Python:** `uv lock --exclude-newer <cutoff-timestamp>` keeps the whole resolution under the
  cutoff.
- **Terraform:** `terraform init -upgrade` rewrites `.terraform.lock.hcl`; check that only the
  providers you meant to bump changed.

---

## Step 4: Verify compatibility

```bash
make check     # lint + unit tests for what changed
```

Then, for the ecosystem you touched:

| Ecosystem | Also run |
|---|---|
| npm | `node .claude/skills/dependency-versioning/scripts/peer-check.cjs apps/<app>` (declared peers, whole tree), then `npm run build` in that app |
| Go | `go build ./... && go vet ./... && go test ./...` in `apps/validator` |
| Terraform | `terraform init -upgrade && terraform validate && tflint` in the module's `examples/basic`; the PR's plan must show no unexpected changes |
| Helm | `helm template` with each environment's values (the chart's `values.schema.json` validates them) |
| Images | `docker build`, `make smoke`, `trivy image <ref>` |
| Actions | `actionlint` and `zizmor`; the workflow run on the PR is the real test |

A green run means "compatible across these layers". Undeclared incompatibilities and untested
runtime paths are still the preview environment's to catch. Say so honestly.

**Audit triage:** separate shipped dependencies from dev, build and test tooling by tracing each
advisory's dependency path. Only a shipped-dependency advisory blocks a release.

---

## Step 5: Record

- The commit message (e.g. `chore(deps): bump <pkg> from <old> to <new>`) carries the old and new
  versions, the new version's publish date, a one-line reason, and the GHSA/CVE id when the
  security exception was used.
- Anything **held** below the newest release because of the 7-day rule gets a revisit date
  (about today + 7) in the PR, and its `overrides` pin is removed when it's bumped later.
- A dependency change ships in its own commit, separate from the code that uses it. The manifest
  and its lockfile move together, always.

## Automation

Dependabot or Renovate opens the routine bump PRs; an ADR records which one. Either can enforce the
7-day floor (Renovate: `minimumReleaseAge`; Dependabot: a `cooldown` block). Check the option names
and syntax against the tool's current docs when writing the config. A bot's PR still goes through
Steps 3 and 4.

## Quick reference

```bash
npm view <pkg> time --json                                    # newest safe target (npm)
go list -m -json <module>@<version>                           # publish time (Go)
docker buildx imagetools inspect <image>:<tag>                # digest to pin
git ls-remote --tags https://github.com/<owner>/<action> '<tag>*'   # SHA to pin
node .claude/skills/dependency-versioning/scripts/age-scan.cjs HEAD apps/<app>/package-lock.json   # 0 violations
make check
```
