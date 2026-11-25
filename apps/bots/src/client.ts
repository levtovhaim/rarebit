// One bot's connection to the game, behaving as ADR 0020 requires of every client:
//   - WebSocket only; after a dropped connection or server:draining, wait a random 0–2 s, then
//     connect to the next server URL (with one URL, the load balancer picks the pod);
//   - room:resume after every reconnect, keeping the new token it returns;
//   - room:sync when a deadline has passed by 1.5 s with no new state (a lost push);
//   - deadlines on the server's clock (serverNow), never the local one.
// Events the game flow resends after a reconnect (answers, votes, sync) are idempotent on the
// server; joining is not, so it is never resent.
import { EventEmitter } from "node:events";
import { io, type Socket } from "socket.io-client";
import type { Logger } from "./log.js";
import type { Reply, RoomSnapshot } from "./protocol.js";
import type { Rng } from "./rng.js";
import type { Stats } from "./stats.js";

export interface ClientOptions {
  /** Server base URLs; reconnects move on to the next one. */
  urls: string[];
  /** Which URL to try first: bots spread across servers by their index. */
  startAt: number;
  socketPath: string;
  /** The Origin header to send (the server checks it against ALLOWED_ORIGINS). */
  origin: string | undefined;
  log: Logger;
  stats: Stats;
  rng: Rng;
  ackTimeoutMs: number;
  /** Give up reconnecting after this long, and fail. */
  reconnectGiveUpMs: number;
}

const SERVER_EVENTS = ["round:start", "vote:start", "round:results", "game:end"] as const;
const WATCHDOG_MS = 500;
const WATCHDOG_LATE_MS = 1500;
const WATCHDOG_REPEAT_MS = 3000;

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export interface Seat {
  roomCode: string;
  playerId: string;
  token: string;
}

/**
 * Emits "state" (RoomSnapshot), the server's "round:start", "vote:start", "round:results" and
 * "game:end", "resumed", and "fatal" (reason) when the bot can't continue.
 */
export class BotClient extends EventEmitter {
  state: RoomSnapshot | null = null;
  seat: Seat | null = null;
  fatal: string | null = null;
  reconnects = 0;
  resumes = 0;

  private socket: Socket | null = null;
  private urlIndex: number;
  private closed = false;
  private reconnecting: Promise<void> | null = null;
  private clockOffset = 0; // server clock minus ours
  private lastSyncAt = 0;
  private watchdog: NodeJS.Timeout | null = null;

  constructor(private readonly o: ClientOptions) {
    super();
    this.urlIndex = o.startAt % o.urls.length;
  }

  /** Now, on the server's clock, as last learned from serverNow. */
  serverNow(): number {
    return Date.now() + this.clockOffset;
  }

  get url(): string {
    return this.o.urls[this.urlIndex]!;
  }

  async connect(): Promise<void> {
    this.socket = await this.open(this.url);
    this.watchdog = setInterval(() => void this.checkWatchdog(), WATCHDOG_MS);
  }

  async create(nickname: string): Promise<Reply> {
    return this.takeSeat(await this.send("room:create", { nickname }));
  }

  async join(roomCode: string, nickname: string): Promise<Reply> {
    return this.takeSeat(await this.send("room:join", { roomCode, nickname }));
  }

  async quickplay(nickname: string): Promise<Reply> {
    return this.takeSeat(await this.send("quickplay:join", { nickname }));
  }

  /**
   * A game action. Waits while the bot reconnects; if the acknowledgement doesn't come (the
   * connection died under it), sends it once more after the reconnect.
   */
  async call(event: string, payload: object): Promise<Reply> {
    for (let attempt = 1; ; attempt++) {
      await this.ready();
      try {
        return await this.send(event, payload);
      } catch (err) {
        if (attempt >= 2 || this.closed || this.fatal) throw err;
        this.o.stats.count(`resent.${event}`);
      }
    }
  }

  close(): void {
    this.closed = true;
    if (this.watchdog) clearInterval(this.watchdog);
    const s = this.socket;
    this.socket = null;
    if (s) {
      s.removeAllListeners();
      s.disconnect();
    }
  }

  private open(url: string): Promise<Socket> {
    return new Promise((resolve, reject) => {
      const socket = io(url, {
        path: this.o.socketPath,
        transports: ["websocket"],
        reconnection: false,
        forceNew: true,
        timeout: 5000,
        ...(this.o.origin ? { extraHeaders: { origin: this.o.origin } } : {}),
      });
      socket.once("connect_error", (err) => {
        socket.removeAllListeners();
        socket.disconnect();
        reject(err);
      });
      socket.once("connect", () => {
        socket.removeAllListeners("connect_error");
        this.attach(socket);
        resolve(socket);
      });
    });
  }

  private attach(socket: Socket): void {
    socket.on("room:state", (s: RoomSnapshot) => this.setState(s));
    for (const event of SERVER_EVENTS) {
      socket.on(event, (payload: { serverNow?: number }) => {
        if (typeof payload?.serverNow === "number") this.clockOffset = payload.serverNow - Date.now();
        this.emit(event, payload);
      });
    }
    socket.on("server:draining", () => {
      this.o.stats.count("draining_notices");
      this.o.log.info("server draining: moving to another", { url: this.url });
      void this.reconnect("server draining");
    });
    socket.on("disconnect", (reason: string) => {
      if (this.socket !== socket || this.closed) return; // ours to close, or already replaced
      void this.reconnect(reason);
    });
  }

  private setState(s: RoomSnapshot): void {
    this.state = s;
    this.clockOffset = s.serverNow - Date.now();
    this.emit("state", s);
  }

  private takeSeat(reply: Reply): Reply {
    if (reply.ok) {
      this.seat = { roomCode: String(reply.roomCode), playerId: String(reply.playerId), token: String(reply.token) };
      this.setState(reply.state as RoomSnapshot);
    }
    return reply;
  }

  private async send(event: string, payload: object): Promise<Reply> {
    const socket = this.socket;
    if (!socket?.connected) throw new Error("not connected");
    const started = performance.now();
    const reply = (await socket.timeout(this.o.ackTimeoutMs).emitWithAck(event, payload)) as Reply;
    this.o.stats.observe(event, performance.now() - started);
    if (!reply.ok) this.o.stats.count(`error.${event}.${reply.error}`);
    return reply;
  }

  private async ready(): Promise<void> {
    if (this.reconnecting) await this.reconnecting;
    if (this.fatal) throw new Error(this.fatal);
    if (this.closed) throw new Error("closed");
    if (!this.socket?.connected) await this.reconnect("not connected");
    if (this.fatal) throw new Error(this.fatal);
  }

  private reconnect(reason: string): Promise<void> {
    if (this.closed || this.fatal) return Promise.resolve();
    this.reconnecting ??= this.doReconnect(reason).finally(() => {
      this.reconnecting = null;
    });
    return this.reconnecting;
  }

  private async doReconnect(reason: string): Promise<void> {
    const old = this.socket;
    this.socket = null;
    if (old) {
      old.removeAllListeners();
      old.disconnect();
    }
    this.reconnects++;
    this.o.stats.count("reconnects");
    this.o.log.info("reconnecting", { reason, from: this.url });
    const started = Date.now();
    await sleep(this.o.rng() * 2000); // jitter, so a pod's players don't all arrive at once
    for (let attempt = 1; !this.closed; attempt++) {
      this.urlIndex = (this.urlIndex + 1) % this.o.urls.length;
      let error: string;
      try {
        this.socket = await this.open(this.url);
        if (!this.seat) break;
        const reply = await this.send("room:resume", { roomCode: this.seat.roomCode, playerId: this.seat.playerId, token: this.seat.token });
        if (reply.ok) {
          this.seat.token = String(reply.token);
          this.setState(reply.state as RoomSnapshot);
          this.resumes++;
          this.o.stats.count("resumes");
          this.emit("resumed");
          break;
        }
        if (reply.error === "bad_token" || reply.error === "not_found") {
          this.fail(`resume refused: ${reply.error}`);
          return;
        }
        error = `resume: ${reply.error}`; // unavailable, busy, draining: try again
      } catch (err) {
        error = err instanceof Error ? err.message : String(err);
      }
      const s = this.socket as Socket | null;
      this.socket = null;
      s?.removeAllListeners();
      s?.disconnect();
      if (Date.now() - started > this.o.reconnectGiveUpMs) {
        this.fail(`couldn't reconnect within ${this.o.reconnectGiveUpMs} ms (last: ${error})`);
        return;
      }
      await sleep(Math.min(250 * 2 ** attempt, 2000));
    }
    this.o.stats.observe("reconnect", Date.now() - started);
  }

  private fail(reason: string): void {
    if (this.fatal) return;
    this.fatal = reason;
    this.o.log.warn("bot can't continue", { reason });
    this.emit("fatal", reason);
  }

  /** The watchdog: a deadline 1.5 s past with no new state means a push was lost; ask. */
  private async checkWatchdog(): Promise<void> {
    const s = this.state;
    if (!s || s.deadline === null || this.reconnecting || !this.socket?.connected) return;
    const late = this.serverNow() - s.deadline;
    // The newest state still carries a deadline 1.5 s gone: the next state never arrived.
    if (late < WATCHDOG_LATE_MS || Date.now() - this.lastSyncAt < WATCHDOG_REPEAT_MS) return;
    this.lastSyncAt = Date.now();
    this.o.stats.count("watchdog_syncs");
    try {
      const reply = await this.send("room:sync", {});
      if (reply.ok) this.setState(reply.state as RoomSnapshot);
    } catch {
      // the disconnect handler deals with a dead connection
    }
  }
}
