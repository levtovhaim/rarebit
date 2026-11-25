import { describe, expect, it } from "vitest";
import { ConfigError, loadConfig } from "../src/config.js";

const base = { REDIS_URL: "redis://localhost:6379", VALIDATOR_URL: "http://validator:8080" };

describe("loadConfig", () => {
  it("fills in the defaults", () => {
    const c = loadConfig(base);
    expect(c).toMatchObject({ GAME_PORT: 8080, ROUND_SECONDS: 20, VOTE_SECONDS: 5, MAX_ROUNDS: 10, MAX_STRIKES: 3 });
    expect(c).toMatchObject({ QUICKPLAY_MIN_PLAYERS: 3, QUICKPLAY_COUNTDOWN_SECONDS: 15, ROOM_TTL_SECONDS: 7200 });
    expect(c.allowedOrigins).toEqual([]);
  });

  it("splits the allowed origins", () => {
    expect(loadConfig({ ...base, ALLOWED_ORIGINS: "https://a.example, https://b.example" }).allowedOrigins).toEqual([
      "https://a.example",
      "https://b.example",
    ]);
  });

  it.each([
    { name: "no Redis URL", env: { VALIDATOR_URL: base.VALIDATOR_URL }, mentions: "REDIS_URL" },
    { name: "a Redis URL with the wrong scheme", env: { ...base, REDIS_URL: "http://redis:6379" }, mentions: "REDIS_URL" },
    { name: "a round too short", env: { ...base, ROUND_SECONDS: "1" }, mentions: "ROUND_SECONDS" },
    { name: "not a number", env: { ...base, MAX_ROUNDS: "lots" }, mentions: "MAX_ROUNDS" },
    { name: "a bad log level", env: { ...base, LOG_LEVEL: "loud" }, mentions: "LOG_LEVEL" },
    { name: "a bad socket path", env: { ...base, SOCKET_PATH: "socket.io" }, mentions: "SOCKET_PATH" },
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
      for (const name of ["REDIS_URL", "VALIDATOR_URL", "ROUND_SECONDS"]) expect(message).toContain(name);
      expect(message).not.toContain("s3cret-pw");
    }
  });
});
