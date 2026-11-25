// The validator's HTTP API (apps/validator/README.md): one answer per POST /v1/validate, and the
// playable categories from GET /v1/categories, cached.
import type { Logger } from "./log.js";
import type { Metrics } from "./metrics.js";
import type { CategoryInfo } from "./rules.js";

export type Check =
  | { result: "valid" | "invalid" | "unknown"; key: string }
  /** The validator failed or didn't answer, even after one retry: the room votes on it. */
  | { result: "unavailable"; key: string };

export interface ValidatorClient {
  validate(category: string, letter: string, answer: string): Promise<Check>;
  categories(): Promise<CategoryInfo[]>;
}

const REQUEST_TIMEOUT_MS = 3500; // the validator gives up on Postgres after 3 s
const CATEGORIES_TTL_MS = 60_000;

export function createValidatorClient(baseUrl: string, log: Logger, metrics: Metrics): ValidatorClient {
  const base = baseUrl.replace(/\/+$/, "");
  let cached: { at: number; list: CategoryInfo[] } | null = null;

  async function post(body: unknown): Promise<Response> {
    return fetch(`${base}/v1/validate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  }

  return {
    async validate(category, letter, answer) {
      const end = metrics.validationSeconds.startTimer();
      try {
        for (let attempt = 1; attempt <= 2; attempt++) {
          let res: Response;
          try {
            res = await post({ category, letter, answer });
          } catch (err) {
            // A connection error or a timeout: the call is read-only, so one retry is safe.
            if (attempt === 2) {
              log.warn({ err: String(err), category }, "validator unreachable");
              return { result: "unavailable", key: "" };
            }
            continue;
          }
          if (res.status === 503 && attempt === 1) continue;
          if (!res.ok) {
            log.warn({ status: res.status, category }, "validator refused the answer");
            return { result: "unavailable", key: "" };
          }
          const out = (await res.json()) as { result?: string; key?: string };
          if (out.result === "valid" || out.result === "invalid" || out.result === "unknown") {
            return { result: out.result, key: out.key ?? "" };
          }
          return { result: "unavailable", key: "" };
        }
        return { result: "unavailable", key: "" };
      } finally {
        end();
      }
    },

    async categories() {
      if (cached && Date.now() - cached.at < CATEGORIES_TTL_MS) return cached.list;
      try {
        const res = await fetch(`${base}/v1/categories`, { signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
        if (!res.ok) throw new Error(`status ${res.status}`);
        const body = (await res.json()) as { categories?: CategoryInfo[] };
        const list = (body.categories ?? []).map((c) => ({ id: c.id, name: c.name, letters: c.letters ?? [] }));
        cached = { at: Date.now(), list };
        return list;
      } catch (err) {
        // A stale list beats no game: categories change only with a content load.
        if (cached) {
          log.warn({ err: String(err) }, "categories unavailable, using the cached list");
          return cached.list;
        }
        throw err;
      }
    },
  };
}
