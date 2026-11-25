# 0029. Send a strict Content-Security-Policy and security headers on every web response

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

The web UI loads nothing from other origins: its scripts, styles and fonts are built into the image (ADRs 0026 and 0027), and its WebSocket goes to the same origin. The page's URL carries the room code (`?room=`). nginx serves every response, including errors and redirects, and some locations set headers of their own (the caching rules, ADR 0028).

## Decision

- **On every response from the UI's port** (`always`, so errors and redirects too):
  - a **Content-Security-Policy** with `default-src 'none'`:
    - scripts, styles, fonts and connections from the page's own origin only (`'self'` covers `ws:` and `wss:` there);
    - `data:` images, for the favicon;
    - `base-uri 'none'`, `form-action 'none'` and `frame-ancestors 'none'`;
  - `X-Content-Type-Options: nosniff`;
  - `Referrer-Policy: no-referrer`, because page URLs carry the room code;
  - a **Permissions-Policy** that turns off camera, microphone, geolocation, payment and USB;
  - `Cross-Origin-Opener-Policy: same-origin`.
- **`add_header_inherit merge`** (nginx 1.29.3 and later) at the server level.
  - By default, nginx drops every server-level `add_header` in a location that sets its own, and the caching rules are such locations.
  - With `merge`, the location's headers are added to the server's.
  - On an older nginx, the build's `nginx -t` fails instead of serving pages without the headers.
- **No inlined assets** (`build.assetsInlineLimit: 0`). Vite would inline the smallest font subsets into the CSS as `data:` URLs, which `font-src 'self'` blocks. The smoke test checks the CSS for them.
- **HSTS belongs where TLS ends:** the load balancer, not this server (tracked for the ingress).

## Alternatives considered

| Option | Why not |
|---|---|
| The security headers repeated in each location, or in an included snippet | Works on any nginx, but it's easy to miss in the next location someone adds. `merge` covers every location, and an nginx without it fails the build. |
| `font-src 'self' data:` | Loosens the policy for files the build can just as well ship as files. |
| A CSP with `'unsafe-inline'` styles | Not needed: React sets styles through the DOM's style object, which the CSP allows. |
| HSTS from nginx | nginx sees plain HTTP behind the load balancer, and locally there's no TLS at all. |

## Consequences

- **Good:** an injected script or a third-party resource has nowhere to load from, and a room code doesn't leak through the Referer header.
- **Bad / risks:**
  - **A CSP violation fails quietly:** a blocked font falls back to another font without an error on the page. The smoke test checks the CSS for inlined fonts. Anything else the CSP blocks shows only in a browser console, until the browser tests exist; they'll fail on console CSP errors.
  - **Anything new the UI loads needs a CSP change here,** such as an analytics script or an image from a CDN.
  - **The merge depends on nginx 1.29.3 or later,** which the pinned 1.31.7 has.

## How we'll know it was right

No CSP violations in the browser tests, and the headers present on every response the smoke test checks: the page, an asset, `/version`, a redirect, and the 404s.
