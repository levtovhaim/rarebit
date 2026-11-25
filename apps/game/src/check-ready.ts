// A readiness check from inside the container, for health checks that run a command (docker
// compose): the image has no shell or curl. Kubernetes probes /readyz over HTTP instead.
//
//   /nodejs/bin/node /app/dist/check-ready.js
//
// Exit 0 when the server on GAME_PORT (default 8080) answers /readyz with 200 within 2 s, else 1.
const port = process.env.GAME_PORT || "8080";
try {
  const res = await fetch(`http://127.0.0.1:${port}/readyz`, { signal: AbortSignal.timeout(2000) });
  await res.body?.cancel();
  process.exit(res.ok ? 0 : 1);
} catch {
  process.exit(1);
}
