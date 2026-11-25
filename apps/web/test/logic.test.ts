import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { clockOffset, remainingMs, squares } from "../src/clock";
import { ERRORS, T, errorText, verdictText } from "../src/copy";
import { basePath, joinLink, normalizeCode, roomFromSearch, socketPath } from "../src/location";
import type { RoomSnapshot } from "../src/protocol";
import { initialState, me, reducer, type Seat } from "../src/store";

describe("where the app lives", () => {
  it.each([
    ["/", "/"],
    ["/index.html", "/"],
    ["/pr-12/", "/pr-12/"],
    ["/pr-12/index.html", "/pr-12/"],
    ["", "/"],
  ])("serves %s from %s", (path, base) => {
    expect(basePath(path)).toBe(base);
  });

  it("puts the game's socket and the join link behind the same prefix", () => {
    expect(socketPath("/")).toBe("/socket.io");
    expect(socketPath("/pr-12/")).toBe("/pr-12/socket.io");
    expect(joinLink("https://rarebit.example", "/pr-12/", "K7Q2MX")).toBe("https://rarebit.example/pr-12/?room=K7Q2MX");
  });

  it.each([
    ["?room=K7Q2MX", "K7Q2MX"],
    ["?room=k7q2mx", "K7Q2MX"],
    ["?room=K7Q2M0", null], // 0 is never in a code
    ["?room=K7Q2", null],
    ["", null],
  ])("reads the room from %s", (search, code) => {
    expect(roomFromSearch(search)).toBe(code);
  });

  it("cleans a typed code", () => {
    expect(normalizeCode("k7q 2-mx")).toBe("K7Q2MX");
    expect(normalizeCode("K7Q2MXZZ")).toBe("K7Q2MX");
  });
});

describe("the server's clock", () => {
  it("measures the offset and the time left from it", () => {
    const offset = clockOffset(10_000, 9_000); // the server is 1 s ahead
    expect(offset).toBe(1000);
    expect(remainingMs(25_000, offset, 9_000)).toBe(15_000);
    expect(remainingMs(25_000, offset, 30_000)).toBe(0);
  });

  it.each([
    { phase: 20_000, left: 20_000, want: { total: 20, crossed: 0, seconds: 20, urgent: false } },
    { phase: 20_000, left: 14_200, want: { total: 20, crossed: 5, seconds: 15, urgent: false } },
    { phase: 20_000, left: 5_000, want: { total: 20, crossed: 15, seconds: 5, urgent: true } },
    { phase: 20_000, left: 400, want: { total: 20, crossed: 19, seconds: 1, urgent: true } },
    { phase: 20_000, left: 0, want: { total: 20, crossed: 20, seconds: 0, urgent: false } },
    // a long phase: at most 30 squares, each worth more than a second
    { phase: 120_000, left: 60_000, want: { total: 30, crossed: 15, seconds: 60, urgent: false } },
    // joined mid-phase: the phase is at least what's left
    { phase: 0, left: 8_000, want: { total: 8, crossed: 0, seconds: 8, urgent: false } },
  ])("draws $want.total squares, $want.crossed crossed, with $left ms left of $phase", ({ phase, left, want }) => {
    expect(squares(phase, left)).toEqual(want);
  });
});

const seat: Seat = { roomCode: "K7Q2MX", playerId: "p1", token: "t1", nickname: "נועה" };
function room(over: Partial<RoomSnapshot> = {}): RoomSnapshot {
  return {
    code: "K7Q2MX",
    type: "private",
    phase: "round",
    hostId: "p1",
    players: [
      { id: "p1", nickname: "נועה", score: 10, strikes: 0, eliminated: false, left: false, connected: true },
      { id: "p2", nickname: "דני", score: 5, strikes: 1, eliminated: false, left: false, connected: true },
    ],
    round: 1,
    maxRounds: 3,
    letter: "ב",
    category: { id: "animal", name: "חי" },
    deadline: 120_000,
    serverNow: 100_000,
    voting: null,
    lastResults: null,
    winners: null,
    notice: null,
    ...over,
  };
}

describe("the state reducer", () => {
  it("seats the player and measures the phase once", () => {
    let s = reducer(initialState, { type: "seated", seat, room: room(), receivedAt: 99_000 });
    expect(s.seat).toEqual(seat);
    expect(s.offset).toBe(1000);
    expect(s.phase).toEqual({ deadline: 120_000, ms: 20_000 });
    expect(me(s)?.nickname).toBe("נועה");
    // the same deadline later: the phase length stays what it was
    s = reducer(s, { type: "state", room: room({ serverNow: 110_000 }), receivedAt: 109_000 });
    expect(s.phase).toEqual({ deadline: 120_000, ms: 20_000 });
  });

  it("forgets the sent answer and the votes when a new round begins", () => {
    let s = reducer(initialState, { type: "seated", seat, room: room(), receivedAt: 0 });
    s = reducer(s, { type: "answered", round: 1, text: "ברווז" });
    s = reducer(s, { type: "voted", round: 1, owner: "p2", accept: true });
    expect(s.sent).toEqual({ round: 1, text: "ברווז" });
    expect(s.votes.byOwner).toEqual({ p2: true });
    s = reducer(s, { type: "state", room: room({ phase: "results", deadline: 130_000 }), receivedAt: 0 });
    expect(s.sent?.text).toBe("ברווז"); // the same round
    s = reducer(s, { type: "state", room: room({ round: 2, deadline: 160_000 }), receivedAt: 0 });
    expect(s.sent).toBeNull();
    expect(s.votes).toEqual({ round: 2, byOwner: {} });
    expect(s.phase).toEqual({ deadline: 160_000, ms: 60_000 });
  });

  it("ignores a late snapshot of another room", () => {
    const s = reducer(initialState, { type: "seated", seat, room: room(), receivedAt: 0 });
    expect(reducer(s, { type: "state", room: room({ code: "ABCDEF" }), receivedAt: 0 })).toBe(s);
  });

  it("keeps the rotated token, and drops the seat when the room is lost", () => {
    let s = reducer(initialState, { type: "seated", seat, room: room(), receivedAt: 0 });
    s = reducer(s, { type: "token", token: "t2" });
    expect(s.seat?.token).toBe("t2");
    s = reducer(s, { type: "lost" });
    expect(s).toMatchObject({ lost: true, seat: null, room: null });
  });

  it("tracks the connection", () => {
    let s = reducer(initialState, { type: "reconnecting", reason: "draining" });
    expect(s).toMatchObject({ connection: "reconnecting", reconnectReason: "draining" });
    s = reducer(s, { type: "online" });
    expect(s).toMatchObject({ connection: "online", reconnectReason: null });
  });
});

describe("the copy", () => {
  it("has a message for every error code the game sends", () => {
    // The game README's list of error codes is the source.
    const readme = readFileSync(fileURLToPath(new URL("../../game/README.md", import.meta.url)), "utf8");
    const section = readme.slice(readme.indexOf("Error codes:"), readme.indexOf("## Runtime endpoints"));
    // Codes are words like `not_found`; the section also quotes the nickname's characters (`_`).
    const codes = [...section.matchAll(/`([a-z][a-z_]+)`/g)].map((m) => m[1]!);
    expect(codes.length).toBeGreaterThan(15);
    for (const code of codes) expect(ERRORS[code], code).toBeTruthy();
    expect(errorText("something_new")).toBe(ERRORS.unavailable);
  });

  it("never shows a verdict by color alone", () => {
    for (const verdict of ["valid", "invalid", "unknown", "empty", "blocked"] as const) {
      for (const final of ["valid", "invalid"] as const) {
        const v = verdictText({ verdict, final });
        expect(v.mark.length).toBeGreaterThan(0);
        expect(v.word.length).toBeGreaterThan(0);
      }
    }
  });

  it("is Hebrew", () => {
    expect(T.createRoom).toMatch(/[א-ת]/);
    expect(T.answerLabel("חי", "ב")).toBe("חי ב־ב׳");
  });
});
