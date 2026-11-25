# 0028. Cache hashed assets for a year, revalidate the page, and send a strict CSP

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

Players load the UI on phones, often on weak connections, and come back to it. After a deploy they must get the new version on their next load, not a mix of old and new files. Vite names every built asset after its content hash (`index-DBkDR3S9.js`); only `index.html` keeps its name, and it names the assets of its own build. The page's URL carries the room code (`?room=`). The page loads nothing from other origins: fonts are self-hosted (ADR 0026), and the WebSocket goes to the same origin.

## Decision

- **Hashed assets:** `Cache-Control: public, max-age=31536000, immutable`. A file with that name never changes, so a phone keeps it for a year and doesn't revalidate it, even on reload.
  - Sent without `always`, so a 404 isn't cached. That 404 is an old page asking for a file a newer build dropped.
- **`index.html`:** `Cache-Control: no-cache`. The phone keeps it but asks nginx every time; unchanged, it's a 304 with no body (ETag). After a deploy, the next load gets the new page, which names the new assets.
- **Security headers on every response:**
  - a Content-Security-Policy that allows only the page's own origin for scripts, styles, fonts and connections (`'self'` covers `ws:` and `wss:` there), plus `data:` images for the favicon, with `default-src 'none'`, `base-uri 'none'`, `form-action 'none'` and `frame-ancestors 'none'`;
  - `X-Content-Type-Options: nosniff`;
  - `Referrer-Policy: no-referrer`, because the URL carries the room code;
  - a Permissions-Policy that turns off camera, microphone, geolocation, payment and USB;
  - `Cross-Origin-Opener-Policy: same-origin`.
- **`add_header_inherit merge`** (nginx 1.29.3 and later) at the server level. By default, nginx drops every server-level `add_header` in a location that sets its own, and the caching rules are such locations. With `merge`, the location's headers are added to the server's. On an older nginx, the build's `nginx -t` fails instead of serving pages without the headers.
- **No inlined assets:** `build.assetsInlineLimit: 0`. Vite would inline the smallest font subsets into the CSS as `data:` URLs, which `font-src 'self'` blocks. As files, they're also cached once across builds.
- HSTS belongs where TLS ends: the load balancer, not this server.

## Alternatives considered

| Option | Why not |
|---|---|
| Short `max-age` on everything (an hour, say) | After a deploy, a phone may keep an old `index.html` for up to an hour, or mix old and new files. And unchanged assets get downloaded again for no reason. |
| `no-store` on `index.html` | The page downloads in full on every load. `no-cache` with an ETag costs one small 304. |
| `expires` instead of `add_header Cache-Control` (it doesn't trigger the inheritance rule) | It can't say `immutable`, so every reload revalidates every asset. |
| The security headers repeated in each location, or in an included snippet | Works on any nginx, but it's easy to miss in the next location someone adds. `merge` covers every location, and an nginx without it fails the build. |
| `font-src 'self' data:` | Loosens the policy for files the build can just as well ship as files. |
| A CSP with `'unsafe-inline'` styles | Not needed: React sets styles through the DOM's style object, which the CSP allows. |

## Consequences

- **Good:**
  - a deploy shows up on the next load, with no stale mix of files;
  - a repeat visit costs one 304 plus whatever the build changed;
  - an injected script or a third-party resource has nowhere to load from.
- **Bad / risks:**
  - a CSP violation doesn't break the page loudly: a blocked font falls back silently. The smoke test checks the CSS for inlined fonts. Anything else the CSP blocks shows only in a browser console, until the browser tests exist;
  - anything new the UI loads, such as an analytics script or an image from a CDN, needs a CSP change here;
  - the merge depends on nginx 1.29.3 or later, which the pinned 1.31.7 has.

## How we'll know it was right

No CSP violations in the browser tests, no "old page after deploy" reports, and repeat loads that transfer almost nothing.
