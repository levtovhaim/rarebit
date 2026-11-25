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
/** After a failed fetch with nothing cached, callers get the failure without a new request for this long. */
const CATEGORIES_RETRY_MS = 5_000;

const UNAVAILABLE: Check = { result: "unavailable", key: "" };

export function createValidatorClient(
  baseUrl: string,
  log: Logger,
  metrics: Metrics,
  now: () => number = Date.now,
): ValidatorClient {
  const base = baseUrl.replace(/\/+$/, "");
  let cached: { at: number; list: CategoryInfo[] } | null = null;
  let failedAt = -Infinity;
  let lastError: unknown = null;
  let fetching: Promise<CategoryInfo[]> | null = null;

  async function post(body: unknown): Promise<Response> {
    return fetch(`${base}/v1/validate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  }

  async function fetchCategories(): Promise<CategoryInfo[]> {
    const res = await fetch(`${base}/v1/categories`, { signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(`status ${res.status}`);
    }
    const body = (await res.json()) as { categories?: CategoryInfo[] };
    const list = (body.categories ?? []).map((c) => ({ id: c.id, name: c.name, letters: c.letters ?? [] }));
    // An empty list means a broken content load, not "no game": keep the last good one.
    if (list.length === 0) throw new Error("the validator returned no categories");
    return list;
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
              return UNAVAILABLE;
            }
            continue;
          }
          if (res.status === 503 && attempt === 1) {
            await res.body?.cancel();
            continue;
          }
          if (!res.ok) {
            await res.body?.cancel();
            log.warn({ status: res.status, category }, "validator refused the answer");
            return UNAVAILABLE;
          }
          let out: { result?: string; key?: string };
          try {
            out = (await res.json()) as { result?: string; key?: string };
          } catch (err) {
            // A body cut off or not JSON (a proxy's error page): no verdict, so the room votes.
            log.warn({ err: String(err), category }, "validator sent an unreadable answer");
            return UNAVAILABLE;
          }
          if (out.result === "valid" || out.result === "invalid" || out.result === "unknown") {
            return { result: out.result, key: out.key ?? "" };
          }
          return UNAVAILABLE;
        }
        return UNAVAILABLE;
      } finally {
        end();
      }
    },

    async categories() {
      const t = now();
      if (cached && t - cached.at < CATEGORIES_TTL_MS) return cached.list;
      if (!cached && t - failedAt < CATEGORIES_RETRY_MS) throw lastError;
      // One request at a time: every room starting a round at once shares it.
      fetching ??= fetchCategories()
        .then((list) => {
          cached = { at: now(), list };
          return list;
        })
        .finally(() => {
          fetching = null;
        });
      try {
        return await fetching;
      } catch (err) {
        // A stale list beats no game: categories change only with a content load.
        if (cached) {
          log.warn({ err: String(err) }, "categories unavailable, using the cached list");
          return cached.list;
        }
        failedAt = now();
        lastError = err;
        throw err;
      }
    },
  };
}
