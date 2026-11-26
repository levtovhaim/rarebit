# 0031. Build the web image on the slim nginx-unprivileged base, with pinned Alpine security updates

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner
- **Supersedes:** the base-image part of ADR 0027 (the full `1.31.7-alpine3.24` image)

## Context

Phase 1's audit scanned the images with Trivy. The web image's base, `nginxinc/nginx-unprivileged:1.31.7-alpine3.24`, had 1 fixable CRITICAL and 13 fixable HIGH vulnerabilities in Alpine packages: brotli, curl, expat, libxml2, libxslt, musl and zlib. Upstream hadn't rebuilt the image since 2026-10-19, so no newer digest existed to pin. Most of those packages serve things this image never uses: curl, and nginx's optional modules (XSLT, image filter, GeoIP, njs).

## Decision

- **The slim variant:** `1.31.7-alpine3.24-slim`, the same nginx build without curl and without the optional modules or the libraries they need. It still has what the image uses: `gzip_static`, `stub_status`, uid 101, SIGQUIT as the stop signal, and BusyBox `wget` for the compose healthcheck. The local stack's entry nginx uses the same digest.
- **Pinned Alpine security updates** for what the slim base still carries: `musl` and `musl-utils` `1.2.6-r3` (CVE-2026-107891) and `zlib` `1.4-r0` (CVE-2026-85091). They're installed by one `apk add` with exact versions, the stage's only step with network access.
  - When Alpine replaces those versions, the build fails at that step, and the pins move.
  - Once upstream rebuilds the base with them, the step goes.

## Alternatives considered

| Option | Why not |
|---|---|
| Stay on the full image and waive | 14 fixable findings, one critical, in a public-facing image, for packages it doesn't use. |
| `apk upgrade` without versions | Always current, but the image's content would change between two builds of the same commit, and a scan of one build wouldn't describe the next. |
| The slim base, waiving musl and zlib until upstream rebuilds | Simpler, but it leaves 3 fixable HIGH in the image for an open-ended time. |
| A different base (distroless with a small static server, another vendor's hardened nginx) | ADR 0027 covers it: nginx-unprivileged is the one CLAUDE.md names. |

## Consequences

- **Good:**
  - Trivy finds no HIGH or CRITICAL vulnerability in the web image;
  - it shrank from 56.9 to **15.3 MB** unpacked (10.0 MB as `docker save` writes it). The base is 12.8 MB and the UI's files 2.5 MB;
  - the smoke test's size limit is now 24 MB.
- **Bad / risks:**
  - **Pins expire:** an Alpine update to musl or zlib breaks the build until someone moves the pins. CI's scheduled builds will show it first.
  - **The patched packages come from Alpine's repository at build time,** not from the pinned base digest. Their exact versions are pinned, but not their digests.
  - **The slim base has no curl.** Debugging inside a running container uses BusyBox's `wget` and `nc`.

## How we'll know it was right

Weekly scans (Phase 2 CI) stay at zero fixable HIGH/CRITICAL for the web image, and the pins come out when upstream rebuilds.
