# 0017. Build the validator image in two stages and link glibc and libstdc++ dynamically, on distroless cc

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The validator is a Go binary built with cgo. It links `native/hebrew-normalize`, a C++ library shipped as a static archive behind a C API (ADR 0010, whose follow-up was this image), so it also needs the C++ runtime (libstdc++, libgcc) and the C library. The image runs both `serve` (a Deployment) and `migrate` (a Job). Kubernetes runs it as a non-root user with a read-only root filesystem and sends SIGTERM to PID 1 (CLAUDE.md → Rules, rule 7). Images are pinned by digest (rule 4).

A binary built the way `make validator` builds it fails in an image without a C library: the kernel can't find its ELF interpreter (`/lib64/ld-linux-x86-64.so.2`) and reports `exec /validator: no such file or directory`. So the build needs either a runtime image that ships glibc and libstdc++, or a binary that doesn't need them.

## Decision

- **Two stages.** A builder on `golang:1.27.4-trixie` installs CMake and Ninja, builds the library into a prefix, and builds the binary with `-trimpath -ldflags "-s -w -X main.version=<sha>"`. The steps that build the library and the binary have no network access. The runtime stage copies only the binary and the word lists (why the lists are in the image: ADR 0018).
- **Build tools in the builder:** Debian 13's CMake 3.31.6 and Ninja 1.12.1, from apt, pinned to those versions. That's an exception to ADR 0009, which builds with the `.mise.toml` versions (CMake 4.5, Ninja 1.13) in development and CI. Both satisfy the library's `cmake_minimum_required(VERSION 3.28)`, and Debian's packages need no extra download or checksum handling in the image.
- **Linking:** the C++ library is linked statically (it's an archive). glibc, libstdc++ and libgcc are linked dynamically.
- **Runtime base:** `gcr.io/distroless/cc-debian13:nonroot`. It has glibc and libstdc++, which the binary loads, and also OpenSSL, zlib, zstd, libgomp, tzdata and CA certificates, which it doesn't. It has no shell and no package manager. The builder and the runtime are both Debian 13, so the library versions the binary was linked against are the ones it finds.
- **Runtime settings:**
  - uid 65532, numeric for `runAsNonRoot`;
  - `/validator` as the exec-form entrypoint, with `serve` as the default argument; the Job passes `migrate`;
  - `GODEBUG=netdns=go`, so hostnames always go through Go's own resolver, which honors connect deadlines.
- **Base images pinned by digest**, each at least 7 days old as an artifact (dependency-versioning skill): the digest's push time, not only the upstream release of the tag, since official images are rebuilt between releases.
- **`make validator-image-smoke` checks the contract**, by hand today and in CI once the image build moves there:
  - a numeric non-root user, no shell, no world-writable, setuid or setgid files, at most 45 MB unpacked;
  - the version matches the revision label;
  - `migrate` twice, `serve`, one validation, `check-ready`, and a clean SIGTERM drain;
  - all of it with `--read-only` and no capabilities.

## Alternatives considered

| Option | Why not |
|---|---|
| Fully static binary on `distroless/static` (0.9 MB compressed, 2.4 MB unpacked) | Smallest image, and no libc for scanners to flag. But glibc doesn't support static linking well. A static glibc binary still links `getaddrinfo`, and Go falls back to it when the system's resolver settings ask for something its own resolver doesn't implement (or with `netdns=cgo`). Then it needs glibc's shared NSS modules at runtime, and glibc warns about this at link time. It's safe only with the `netgo` and `osusergo` build tags, and every glibc fix needs a rebuild of the binary. |
| Static libstdc++ only, on `distroless/base` (glibc and OpenSSL; 9.5 MB compressed, 24 MB unpacked) | Saves about 1 MB compressed and decouples the C++ runtime version from the base image, at the cost of non-default linker flags. Not worth it while builder and runtime share a Debian release. |
| musl (Alpine builder and runtime) | Static linking works well with musl, but the library is tested with glibc and GCC, musl's DNS resolver behaves differently, and Alpine images bring a shell and a package manager. |
| A single stage on `golang` | About 1 GB, with compilers, Go and a shell in production. |
| The `.mise.toml` CMake and Ninja in the builder, downloaded from their releases | One version everywhere, but the Dockerfile would download and checksum two archives per architecture, for a library that builds the same with Debian's versions. |

## Consequences

- **Good:**
  - the standard glibc toolchain, with no static-linking caveats;
  - the runtime image has no shell, no package manager and no compilers;
  - a library CVE is fixed by bumping the base image digest and rebuilding;
  - 42 MB unpacked (about 16 MB compressed), checked by the smoke test.
- **Bad / risks:**
  - scanners report CVEs in everything the base ships, including OpenSSL, zlib and zstd, which the binary never loads, and the base digest needs regular bumps (Dependabot or Renovate);
  - the builder and runtime Debian releases must move together: a newer builder can produce a binary that needs a newer libstdc++ than the runtime has (`GLIBCXX_… not found` at start);
  - two CMake versions build the same library (mise's in development and CI, Debian's in the image): raising `cmake_minimum_required` above 3.31 needs the builder changed too;
  - the image has only `/validator`, so chart hooks and probes can't use `exec` (`httpGet` probes; the README lists the chart settings).
- **Follow-ups:**
  - build, scan (Trivy) and push the image in CI with the `pr-<n>-<sha7>` and `main-<sha7>` tags, and run the smoke test there;
  - the Deployment and the migrate Job in the shared chart;
  - automated digest bumps for both base images.

## How we'll know it was right

The smoke test passes on every image CI builds, scans show no fixable HIGH or CRITICAL findings at release, and no rollout fails on a missing library. If the CVE noise from libraries the binary doesn't load becomes a burden, revisit the fully static build.
