import { describe, expect, it } from "vitest";
import { ConfigError, loadConfig } from "../src/config.js";

const base = {
  REDIS_URL: "redis://localhost:6379",
  VALIDATOR_URL: "http://validator:8080",
  ALLOWED_ORIGINS: "https://rarebit.example",
  TRUSTED_PROXY_HOPS: "1",
};

describe("loadConfig", () => {
  it("fills in the defaults", () => {
    const c = loadConfig(base);
    expect(c).toMatchObject({ GAME_PORT: 8080, ROUND_SECONDS: 20, VOTE_SECONDS: 5, MAX_ROUNDS: 10, MAX_STRIKES: 3 });
    expect(c).toMatchObject({ QUICKPLAY_MIN_PLAYERS: 3, QUICKPLAY_COUNTDOWN_SECONDS: 15, ROOM_TTL_SECONDS: 7200, LOBBY_TTL_SECONDS: 600 });
    expect(c).toMatchObject({ MAX_CONNECTIONS_PER_IP: 20, TRUSTED_PROXY_HOPS: 1, DRAIN_DELAY_SECONDS: 15, SHUTDOWN_TIMEOUT_SECONDS: 10 });
    expect(c.allowedOrigins).toEqual(["https://rarebit.example"]);
  });

  // The default isn't checked by the schema, so set it explicitly too.
  it.each(["/socket.io", "/pr-12/socket.io", "/rarebit_game/ws"])("takes SOCKET_PATH=%s", (path) => {
    expect(loadConfig({ ...base, SOCKET_PATH: path }).SOCKET_PATH).toBe(path);
  });

  it.each([
    { value: "https://a.example, https://b.example:8443", want: ["https://a.example", "https://b.example:8443"] },
    { value: "*", want: null },
    { value: " * ", want: null },
    { value: "http://localhost:5173", want: ["http://localhost:5173"] },
  ])("reads ALLOWED_ORIGINS=$value", ({ value, want }) => {
    expect(loadConfig({ ...base, ALLOWED_ORIGINS: value }).allowedOrigins).toEqual(want);
  });

  it.each([
    { name: "no Redis URL", env: { VALIDATOR_URL: base.VALIDATOR_URL, ALLOWED_ORIGINS: "*" }, mentions: "REDIS_URL" },
    { name: "a Redis URL with the wrong scheme", env: { ...base, REDIS_URL: "http://redis:6379" }, mentions: "REDIS_URL" },
    { name: "no allowed origins", env: { REDIS_URL: base.REDIS_URL, VALIDATOR_URL: base.VALIDATOR_URL }, mentions: "ALLOWED_ORIGINS: required" },
    { name: "an origin with a trailing slash", env: { ...base, ALLOWED_ORIGINS: "https://rarebit.example/" }, mentions: "ALLOWED_ORIGINS" },
    { name: "an origin with a path", env: { ...base, ALLOWED_ORIGINS: "https://rarebit.example/play" }, mentions: "ALLOWED_ORIGINS" },
    { name: "a host without a scheme", env: { ...base, ALLOWED_ORIGINS: "rarebit.example" }, mentions: "ALLOWED_ORIGINS" },
    { name: "* inside a list", env: { ...base, ALLOWED_ORIGINS: "https://rarebit.example,*" }, mentions: "ALLOWED_ORIGINS" },
    { name: "an empty entry", env: { ...base, ALLOWED_ORIGINS: "https://rarebit.example,," }, mentions: "ALLOWED_ORIGINS" },
    { name: "a round too short", env: { ...base, ROUND_SECONDS: "1" }, mentions: "ROUND_SECONDS" },
    { name: "not a number", env: { ...base, MAX_ROUNDS: "lots" }, mentions: "MAX_ROUNDS" },
    { name: "a bad log level", env: { ...base, LOG_LEVEL: "loud" }, mentions: "LOG_LEVEL" },
    { name: "a bad socket path", env: { ...base, SOCKET_PATH: "socket.io" }, mentions: "SOCKET_PATH" },
    { name: "too many proxy hops", env: { ...base, TRUSTED_PROXY_HOPS: "9" }, mentions: "TRUSTED_PROXY_HOPS" },
    // No default: behind a load balancer, a wrong one counts every player as the load balancer.
    { name: "no proxy hops", env: { ...base, TRUSTED_PROXY_HOPS: undefined }, mentions: "TRUSTED_PROXY_HOPS: required" },
    { name: "proxy hops that aren't a number", env: { ...base, TRUSTED_PROXY_HOPS: "alb" }, mentions: "TRUSTED_PROXY_HOPS" },
  ])("rejects $name", ({ env, mentions }) => {
    expect(() => loadConfig(env)).toThrow(ConfigError);
    expect(() => loadConfig(env)).toThrow(mentions);
  });

  it("lists every problem at once, and never the values", () => {
    try {
      loadConfig({ REDIS_URL: "http://user:s3cret-pw@redis", ROUND_SECONDS: "0" });
      expect.unreachable();
    } catch (err) {
      const message = (err as Error).message;
      for (const name of ["REDIS_URL", "VALIDATOR_URL", "ALLOWED_ORIGINS", "ROUND_SECONDS"]) expect(message).toContain(name);
      expect(message).not.toContain("s3cret-pw");
    }
  });
});
