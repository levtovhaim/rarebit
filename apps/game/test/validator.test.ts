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

type Reply = { status: number; body?: unknown; raw?: string; delayMs?: number } | "hang";

/** A fake validator: replies[i] answers the i-th request (the last one repeats). */
async function fake(replies: Reply[]): Promise<{ url: string; calls: () => number }> {
  let calls = 0;
  server = createServer((req, res) => {
    const reply = replies[Math.min(calls, replies.length - 1)]!;
    calls++;
    req.resume();
    if (reply === "hang") return; // never answers
    setTimeout(() => {
      res.writeHead(reply.status, { "content-type": "application/json" });
      res.end(reply.raw ?? JSON.stringify(reply.body ?? {}));
    }, reply.delayMs ?? 0);
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
    { name: "a body that isn't JSON", replies: [{ status: 200, raw: "<html>bad gateway" }], want: { result: "unavailable", key: "" }, calls: 1 },
    { name: "an unknown result", replies: [{ status: 200, body: { result: "maybe" } }], want: { result: "unavailable", key: "" }, calls: 1 },
  ])("$name", async ({ replies, want, calls }: { replies: Reply[]; want: unknown; calls: number }) => {
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

  describe("categories", () => {
    const list = [{ id: "country", name: "ארץ", kind: "regular", letters: ["א"] }];
    const want = [{ id: "country", name: "ארץ", letters: ["א"] }];

    /** A clock the test moves by hand. */
    function clock() {
      let t = 1_000_000;
      return { now: () => t, advance: (ms: number) => void (t += ms) };
    }

    it("caches the list for a minute", async () => {
      const v = await fake([{ status: 200, body: { categories: list } }]);
      const c = clock();
      const client = createValidatorClient(v.url, log, metrics, c.now);
      expect(await client.categories()).toEqual(want);
      c.advance(59_000);
      expect(await client.categories()).toEqual(want);
      expect(v.calls()).toBe(1);
      c.advance(2_000);
      await client.categories();
      expect(v.calls()).toBe(2);
    });

    it("falls back to the cached list when the validator fails", async () => {
      const v = await fake([{ status: 200, body: { categories: list } }, { status: 503 }]);
      const c = clock();
      const client = createValidatorClient(v.url, log, metrics, c.now);
      await client.categories();
      c.advance(61_000);
      expect(await client.categories()).toEqual(want);
      expect(v.calls()).toBe(2); // it did ask, and got a 503
    });

    it("treats an empty list as a failure and keeps the last good one", async () => {
      const v = await fake([{ status: 200, body: { categories: list } }, { status: 200, body: { categories: [] } }]);
      const c = clock();
      const client = createValidatorClient(v.url, log, metrics, c.now);
      await client.categories();
      c.advance(61_000);
      expect(await client.categories()).toEqual(want);
    });

    it("fails when the list was never fetched, without asking again for 5 s", async () => {
      const v = await fake([{ status: 503 }, { status: 200, body: { categories: [] } }, { status: 200, body: { categories: list } }]);
      const c = clock();
      const client = createValidatorClient(v.url, log, metrics, c.now);
      await expect(client.categories()).rejects.toThrow("status 503");
      await expect(client.categories()).rejects.toThrow("status 503");
      expect(v.calls()).toBe(1);
      c.advance(5_001);
      await expect(client.categories()).rejects.toThrow("no categories"); // an empty list isn't cached
      c.advance(5_001);
      expect(await client.categories()).toEqual(want);
      expect(v.calls()).toBe(3);
    });

    it("sends one request for many rooms asking at once", async () => {
      const v = await fake([{ status: 200, body: { categories: list }, delayMs: 100 }]);
      const client = createValidatorClient(v.url, log, metrics);
      const lists = await Promise.all(Array.from({ length: 10 }, () => client.categories()));
      expect(lists.every((l) => l.length === 1)).toBe(true);
      expect(v.calls()).toBe(1);
    });
  });
});
