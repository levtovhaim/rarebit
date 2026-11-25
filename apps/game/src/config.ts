// Settings come only from environment variables, checked once at startup: a bad value stops the
// process with every problem listed, instead of failing on first use.
import { z } from "zod";

const int = (def: number, min: number, max: number) => z.coerce.number().int().min(min).max(max).default(def);

const schema = z.object({
  GAME_PORT: int(8080, 1, 65535),
  REDIS_URL: z.url({ protocol: /^rediss?$/, error: "must be a redis:// or rediss:// URL" }),
  VALIDATOR_URL: z.url({ protocol: /^https?$/, error: "must be an http:// or https:// URL" }),
  SOCKET_PATH: z.string().regex(/^\/[A-Za-z0-9/_-]*$/, "must be a path like /socket.io").default("/socket.io"),
  // Comma-separated origins allowed to open a WebSocket; empty allows any (local development).
  ALLOWED_ORIGINS: z.string().default(""),
  ROUND_SECONDS: int(20, 3, 120),
  VOTE_SECONDS: int(5, 2, 60),
  RESULTS_SECONDS: int(5, 1, 60),
  MAX_ROUNDS: int(10, 1, 30),
  MAX_STRIKES: int(3, 1, 10),
  QUICKPLAY_MIN_PLAYERS: int(3, 2, 8),
  QUICKPLAY_COUNTDOWN_SECONDS: int(15, 0, 120),
  ROOM_TTL_SECONDS: int(7200, 300, 86400),
  DRAIN_DELAY_SECONDS: int(5, 0, 60),
  SHUTDOWN_TIMEOUT_SECONDS: int(20, 1, 300),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  GIT_SHA: z.string().regex(/^[0-9a-f]{7}(-dirty)?$|^unknown$/).default("unknown"),
});

export type Config = z.infer<typeof schema> & { allowedOrigins: string[] };

/** Thrown with a message that lists every invalid setting (never their values: URLs can hold passwords). */
export class ConfigError extends Error {}

export function loadConfig(env: Record<string, string | undefined>): Config {
  const parsed = schema.safeParse(
    Object.fromEntries(Object.entries(env).filter(([, v]) => v !== undefined && v !== "")),
  );
  if (!parsed.success) {
    const problems = parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`);
    throw new ConfigError(problems.join("; "));
  }
  const allowedOrigins = parsed.data.ALLOWED_ORIGINS.split(",")
    .map((o) => o.trim())
    .filter(Boolean);
  return { ...parsed.data, allowedOrigins };
}
