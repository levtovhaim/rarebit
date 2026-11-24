# 0017. Build the validator image in two stages and link glibc and libstdc++ dynamically, on distroless cc

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The validator is a Go binary built with cgo: it links `native/hebrew-normalize`, a C++ static archive, so it also needs the C++ runtime (libstdc++, libgcc) and the C library. The image runs both `serve` (a Deployment) and `migrate` (a Job). Kubernetes runs it as a non-root user with a read-only root filesystem and sends SIGTERM to PID 1 (CLAUDE.md → Rules, rule 7). Images are pinned by digest (rule 4).

A binary built the way `make validator` builds it fails in an image without a C library: the kernel can't find its ELF interpreter (`/lib64/ld-linux-x86-64.so.2`) and reports `exec /validator: no such file or directory`. So the build needs either a runtime image that ships glibc and libstdc++, or a binary that doesn't need them.

## Decision

- **Two stages.** A builder on `golang:1.27.4-trixie` installs CMake and Ninja, builds the library into a prefix, and builds the binary with `-trimpath -ldflags "-s -w -X main.version=<sha>"`. The runtime stage copies only the binary and the word lists.
- **Linking:** the C++ library is linked statically (it's an archive). glibc, libstdc++ and libgcc are linked dynamically.
- **Runtime base:** `gcr.io/distroless/cc-debian13:nonroot`. It ships exactly those libraries, plus CA certificates, and has no shell or package manager. The builder and the runtime are both Debian 13, so the library versions the binary was linked against are the ones it finds.
- The image runs as uid 65532 (numeric, for `runAsNonRoot`), with `/validator` as the exec-form entrypoint and `serve` as the default command. The Job passes `migrate` as its argument. The word lists ship in the image at `/data/categories`, read-only, with fixed permissions.
- `make validator-image-smoke` checks the contract on every build: non-root, no shell, no world-writable files, at most 45 MB unpacked, a real version, `migrate` twice, `serve`, one validation and a clean SIGTERM drain, all with `--read-only` and no capabilities.

## Alternatives considered

| Option | Why not |
|---|---|
| Fully static binary on `distroless/static` (0.9 MB base) | Smallest image, and no libc for scanners to flag. But glibc doesn't support static linking well: with cgo on, Go resolves hostnames through glibc's `getaddrinfo`, which in a static binary still needs glibc's shared NSS libraries at runtime, and the database host is a DNS name in Kubernetes. It works only with the `netgo` and `osusergo` build tags, and every glibc fix then needs a rebuild of the binary. |
| Static libstdc++ only, on `distroless/base` (glibc, 9.5 MB) | Saves about 1 MB and decouples the C++ runtime version from the base image, at the cost of non-default linker flags. Not worth it while builder and runtime share a Debian release. |
| musl (Alpine builder and runtime) | Static linking works well with musl, but the library is tested with glibc and GCC, musl's DNS resolver behaves differently, and Alpine images bring a shell and a package manager. |
| A single stage on `golang` | About 1 GB, with compilers, Go and a shell in production. |
| Word lists mounted from a ConfigMap instead of shipped in the image | Content and code would be versioned separately, and ConfigMaps are capped at 1 MiB. Shipping them in the image ties a content load to an image tag. |

## Consequences

- **Good:**
  - the standard glibc toolchain, with no static-linking caveats;
  - the runtime image has no shell, no package manager and no compilers;
  - a library CVE is fixed by bumping the base image digest and rebuilding;
  - 41 MB unpacked (about 16 MB compressed), checked on every build.
- **Bad / risks:**
  - glibc and libstdc++ are in the image, so scanners report their CVEs, and the base digest needs regular bumps (Dependabot or Renovate);
  - the builder and runtime Debian releases must move together: a newer builder can produce a binary that needs a newer libstdc++ than the runtime has;
  - a content change means a new image.
- **Follow-ups:**
  - build, scan (Trivy) and push the image in CI with the `pr-<n>-<sha7>` and `main-<sha7>` tags;
  - the Deployment and the migrate Job in the shared chart;
  - automated digest bumps for both base images.

## How we'll know it was right

The image passes its smoke test on every build, scans show no fixable HIGH or CRITICAL findings at release, and no rollout fails on a missing library. If the CVE noise from glibc or libstdc++ becomes a burden, revisit the fully static build.
