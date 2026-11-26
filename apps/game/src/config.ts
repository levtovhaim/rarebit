// Settings come only from environment variables, checked once at startup: a bad value stops the
// process with every problem listed, instead of failing on first use.
import { z } from "zod";

const int = (def: number, min: number, max: number) => z.coerce.number().int().min(min).max(max).default(def);

/** "*", or a comma-separated list of origins exactly as browsers send them (scheme://host[:port]). */
const origins = z
  .string({ error: 'required: "*" or a comma-separated list of origins' })
  .min(1, 'must be "*" or a comma-separated list of origins')
  .refine(
    (v) =>
      v.trim() === "*" ||
      v.split(",").every((o) => {
        const s = o.trim();
        try {
          return s !== "" && new URL(s).origin === s;
        } catch {
          return false;
        }
      }),
    'each entry must be an origin like https://example.com, with no path or trailing slash; or "*" alone',
  );

const schema = z.object({
  GAME_PORT: int(8080, 1, 65535),
  REDIS_URL: z.url({ protocol: /^rediss?$/, error: "must be a redis:// or rediss:// URL" }),
  VALIDATOR_URL: z.url({ protocol: /^https?$/, error: "must be an http:// or https:// URL" }),
  SOCKET_PATH: z.string().regex(/^\/[A-Za-z0-9/._-]*$/, "must be a path like /socket.io").default("/socket.io"),
  // Which web origins may open a WebSocket. Required, so an unset value can't open it to any site.
  ALLOWED_ORIGINS: origins,
  ROUND_SECONDS: int(20, 3, 120),
  VOTE_SECONDS: int(5, 2, 60),
  RESULTS_SECONDS: int(5, 1, 60),
  MAX_ROUNDS: int(10, 1, 30),
  MAX_STRIKES: int(3, 1, 10),
  QUICKPLAY_MIN_PLAYERS: int(3, 2, 8),
  QUICKPLAY_COUNTDOWN_SECONDS: int(15, 0, 120),
  ROOM_TTL_SECONDS: int(7200, 300, 86400),
  LOBBY_TTL_SECONDS: int(600, 60, 86400),
  MAX_CONNECTIONS_PER_IP: int(20, 1, 10000),
  // How many proxies in front of the pod append to X-Forwarded-For (the ALB: 1). 0 = use the peer
  // address. Required: a wrong default behind a load balancer would count every player as the
  // load balancer's address, and the per-address cap would refuse them all past a few dozen.
  TRUSTED_PROXY_HOPS: z.coerce
    .number({ error: "required: how many proxies append to X-Forwarded-For (0 = none; behind the ALB, 1)" })
    .int()
    .min(0)
    .max(5),
  DRAIN_DELAY_SECONDS: int(15, 0, 60),
  SHUTDOWN_TIMEOUT_SECONDS: int(10, 1, 300),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  GIT_SHA: z.string().regex(/^[0-9a-f]{7}(-dirty)?$|^unknown$/).default("unknown"),
});

export type Config = z.infer<typeof schema> & {
  /** null when any origin is allowed ("*"). */
  allowedOrigins: string[] | null;
};

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
  const raw = parsed.data.ALLOWED_ORIGINS.trim();
  const allowedOrigins = raw === "*" ? null : raw.split(",").map((o) => o.trim());
  return { ...parsed.data, allowedOrigins };
}
