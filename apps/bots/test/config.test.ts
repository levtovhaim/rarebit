import { describe, expect, it } from "vitest";
import { ConfigError, loadConfig } from "../src/config.js";

const url = ["--url", "http://game:8080"];

describe("loadConfig", () => {
  it("fills in the defaults", () => {
    const c = loadConfig(["synthetic", ...url], {});
    expect(c).toMatchObject({ mode: "synthetic", urls: ["http://game:8080"], socketPath: "/socket.io", gameMode: "private", players: 3 });
    expect(c).toMatchObject({ rooms: 1, games: 1, durationS: 300, timeoutS: 900, stallGraceS: 30, maxFailed: 0, strategy: "scripted" });
    expect(c.wordsDir.replace(/\\/g, "/")).toMatch(/data\/categories$/);
  });

  it("takes several URLs, and options from the environment", () => {
    const c = loadConfig(["load"], { BOTS_URL: "http://a:8080, http://b:8080", BOTS_ROOMS: "12", BOTS_ORIGIN: "https://rarebit.example" });
    expect(c.urls).toEqual(["http://a:8080", "http://b:8080"]);
    expect(c.rooms).toBe(12);
    expect(c.origin).toBe("https://rarebit.example");
  });

  it("takes a path-based socket path", () => {
    expect(loadConfig(["synthetic", ...url, "--socket-path", "/pr-12/socket.io"], {}).socketPath).toBe("/pr-12/socket.io");
    expect(() => loadConfig(["synthetic", ...url, "--socket-path", "socket.io"], {})).toThrow("--socket-path");
  });

  it("prefers the command line to the environment", () => {
    expect(loadConfig(["load", ...url, "--rooms", "3"], { BOTS_ROOMS: "12" }).rooms).toBe(3);
  });

  it.each([
    { name: "no mode", argv: [...url], mentions: "the mode" },
    { name: "an unknown mode", argv: ["attack", ...url], mentions: "the mode" },
    { name: "no URL", argv: ["synthetic"], mentions: "--url: required" },
    { name: "a URL that isn't http", argv: ["synthetic", "--url", "ws://game"], mentions: "--url" },
    { name: "too many players", argv: ["synthetic", ...url, "--players", "9"], mentions: "--players" },
    { name: "a fraction", argv: ["load", ...url, "--rooms", "1.5"], mentions: "--rooms" },
    { name: "an origin with a path", argv: ["synthetic", ...url, "--origin", "https://x.example/play"], mentions: "--origin" },
    { name: "quick play under load", argv: ["load", ...url, "--game-mode", "quickplay"], mentions: "quickplay" },
    { name: "an unknown strategy", argv: ["synthetic", ...url, "--strategy", "cheater"], mentions: "--strategy" },
    { name: "an unknown option", argv: ["synthetic", ...url, "--turbo", "1"], mentions: "turbo" },
    { name: "extra arguments", argv: ["synthetic", "load", ...url], mentions: "unexpected arguments" },
  ])("rejects $name", ({ argv, mentions }) => {
    expect(() => loadConfig(argv, {})).toThrow(ConfigError);
    expect(() => loadConfig(argv, {})).toThrow(mentions);
  });

  it("lists every problem at once", () => {
    try {
      loadConfig(["nope", "--players", "1", "--rooms", "0"], {});
      expect.unreachable();
    } catch (err) {
      for (const part of ["the mode", "--url", "--players", "--rooms"]) expect((err as Error).message).toContain(part);
    }
  });
});
