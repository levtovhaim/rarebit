import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { createLogger } from "../src/log.js";
import { createMetrics } from "../src/metrics.js";
import { createValidatorClient } from "../src/validator.js";

const log = createLogger("error", "test");
const metrics = createMetrics({
  roomsActive: async () => ({ private: 0, public: 0 }),
  queueLength: async () => 0,
  playersConnected: () => 0,
  draining: () => false,
});

let server: Server | null = null;
afterEach(() => new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve())));

/** A fake validator: replies[i] answers the i-th request. */
async function fake(replies: Array<{ status: number; body?: unknown } | "hang">): Promise<{ url: string; calls: () => number }> {
  let calls = 0;
  server = createServer((req, res) => {
    const reply = replies[Math.min(calls, replies.length - 1)]!;
    calls++;
    req.resume();
    if (reply === "hang") return; // never answers
    res.writeHead(reply.status, { "content-type": "application/json" });
    res.end(JSON.stringify(reply.body ?? {}));
  });
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${(server!.address() as AddressInfo).port}`, calls: () => calls };
}

describe("validator client", () => {
  it.each([
    { name: "valid", replies: [{ status: 200, body: { result: "valid", key: "ישראל" } }], want: { result: "valid", key: "ישראל" }, calls: 1 },
    { name: "unknown", replies: [{ status: 200, body: { result: "unknown", key: "גונדור" } }], want: { result: "unknown", key: "גונדור" }, calls: 1 },
    {
      name: "a 503 is retried once",
      replies: [{ status: 503 }, { status: 200, body: { result: "invalid", key: "x" } }],
      want: { result: "invalid", key: "x" },
      calls: 2,
    },
    { name: "503 twice: unavailable", replies: [{ status: 503 }, { status: 503 }], want: { result: "unavailable", key: "" }, calls: 2 },
    { name: "a 400 is not retried", replies: [{ status: 400, body: { error: "bad_letter" } }], want: { result: "unavailable", key: "" }, calls: 1 },
  ])("$name", async ({ replies, want, calls }) => {
    const v = await fake(replies);
    const client = createValidatorClient(v.url, log, metrics);
    expect(await client.validate("country", "י", "ישראל")).toEqual(want);
    expect(v.calls()).toBe(calls);
  });

  it("gives up on a validator that doesn't answer", { timeout: 15_000 }, async () => {
    const v = await fake(["hang"]);
    const client = createValidatorClient(v.url, log, metrics);
    const started = Date.now();
    expect(await client.validate("country", "י", "ישראל")).toEqual({ result: "unavailable", key: "" });
    expect(Date.now() - started).toBeLessThan(9000); // two attempts of 3.5 s
  });

  it("caches the categories and falls back to the cache when the validator fails", async () => {
    const list = [{ id: "country", name: "ארץ", kind: "regular", letters: ["א"] }];
    const v = await fake([{ status: 200, body: { categories: list } }, { status: 503 }]);
    const client = createValidatorClient(v.url, log, metrics);
    expect(await client.categories()).toEqual([{ id: "country", name: "ארץ", letters: ["א"] }]);
    expect(await client.categories()).toHaveLength(1);
    expect(v.calls()).toBe(1); // the second call came from the cache
  });

  it("fails when the categories were never fetched", async () => {
    const v = await fake([{ status: 503 }]);
    await expect(createValidatorClient(v.url, log, metrics).categories()).rejects.toThrow();
  });
});
