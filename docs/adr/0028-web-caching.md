# 0028. Cache the web UI's hashed assets for a year, and revalidate the page on every load

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

Players load the UI on phones, often on weak connections, and come back to it. After a deploy they must get the new version on their next load, not a mix of old and new files. Vite names every built asset after its content hash (`index-DBkDR3S9.js`). Only `index.html` keeps its name, and it names the assets of its own build. The web image serves the files (ADR 0027).

## Decision

- **Hashed assets:** `Cache-Control: public, max-age=31536000, immutable`. A file with that name never changes, so a phone keeps it for a year and doesn't revalidate it, even on reload.
  - Sent without `always`, so a 404 isn't cached. That 404 is an old page asking for a file a newer build dropped.
- **`index.html`:** `Cache-Control: no-cache`. The phone keeps it but asks nginx every time; unchanged, it's a 304 with no body (ETag). After a deploy, the next load gets the new page, which names the new assets.
- **Assets are files, never inlined:** `build.assetsInlineLimit: 0`, so every font subset is cached once across builds. It also keeps the Content-Security-Policy strict (ADR 0029).
- **The security headers** stay on the responses that set Cache-Control: `add_header_inherit merge` (ADR 0029).

## Alternatives considered

| Option | Why not |
|---|---|
| Short `max-age` on everything (an hour, say) | After a deploy, a phone may keep an old `index.html` for up to an hour, or mix old and new files. And unchanged assets get downloaded again for no reason. |
| `no-store` on `index.html` | The page downloads in full on every load. `no-cache` with an ETag costs one small 304. |
| `expires` instead of `add_header Cache-Control` (it doesn't trigger nginx's add_header inheritance rule) | It can't say `immutable`, so every reload revalidates every asset. |

## Consequences

- **Good:**
  - a phone sees a deploy on its next load;
  - a repeat visit costs one 304 plus whatever the build changed.
- **Bad / risks:**
  - **Mixed versions during a rollout.** The load balancer sends each request to any pod. While old and new pods run side by side, a phone can get the new `index.html` from a new pod and then ask an old pod for a new asset, or the other way round. The result is a 404 and a blank page, until a reload. Because 404s aren't cached, the reload recovers.
  - The chart must close this gap, with one of:
    - stickiness on the web target group only (the game's WebSockets don't need it);
    - the previous release's assets kept in each new image (the hashed names can't collide).

    It's decided in the chart PR.
  - Something in between that ignores `no-cache` on the page (a CDN or a proxy) serves an old page after a deploy.

## How we'll know it was right

No "old page after deploy" or blank-page-during-rollout reports, and repeat loads that transfer almost nothing.
