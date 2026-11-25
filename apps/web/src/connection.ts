// The browser's connection to the game, behaving as ADR 0020 requires of every client:
//   - WebSocket only, to this page's origin, at this page's path prefix;
//   - after a dropped connection or server:draining: a random 0–2 s wait, then reconnect and
//     room:resume with the newest token (each resume returns a new one);
//   - room:sync when a deadline has passed by 1.5 s with no new state (a lost push).
// A phone that wakes up reconnects at once. Only idempotent actions (answers, votes) are resent.
import { io, type Socket } from "socket.io-client";
import type { Reply, RoomSnapshot } from "./protocol";
import type { Action, Seat } from "./store";

const ACK_TIMEOUT_MS = 6000;
const WATCHDOG_LATE_MS = 1500;
const WATCHDOG_REPEAT_MS = 3000;

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export interface ConnectionOptions {
  /** The game's Socket.IO path, e.g. /socket.io or /pr-12/socket.io. */
  path: string;
  dispatch: (action: Action) => void;
  /** Called whenever the seat changes (to keep it in storage), null when it's gone. */
  onSeat: (seat: Seat | null) => void;
}

export class GameConnection {
  private socket: Socket | null = null;
  private seat: Seat | null = null;
  private room: RoomSnapshot | null = null;
  private offset = 0;
  private closed = false;
  private reconnecting: Promise<void> | null = null;
  private wakeUp: (() => void) | null = null;
  private lastSyncAt = 0;
  private readonly watchdog: ReturnType<typeof setInterval>;
  private readonly onVisible = () => {
    if (document.visibilityState === "visible") this.wakeUp?.();
  };

  constructor(private readonly o: ConnectionOptions) {
    this.watchdog = setInterval(() => void this.checkWatchdog(), 500);
    document.addEventListener("visibilitychange", this.onVisible);
  }

  /** Connects; with a saved seat, goes straight back into its room. */
  async start(seat: Seat | null): Promise<void> {
    this.seat = seat;
    this.o.dispatch({ type: "connecting" });
    await this.reconnect(seat ? "dropped" : null, false);
  }

  close(): void {
    this.closed = true;
    clearInterval(this.watchdog);
    document.removeEventListener("visibilitychange", this.onVisible);
    this.drop();
  }

  async create(nickname: string): Promise<void> {
    await this.takeSeat(await this.call("room:create", { nickname }, false), nickname);
  }

  async join(roomCode: string, nickname: string): Promise<void> {
    await this.takeSeat(await this.call("room:join", { roomCode, nickname }, false), nickname);
  }

  async quickplay(nickname: string): Promise<void> {
    await this.takeSeat(await this.call("quickplay:join", { nickname }, false), nickname);
  }

  async startGame(): Promise<void> {
    const reply = await this.call("game:start", {}, false);
    if (!reply.ok) this.o.dispatch({ type: "error", code: String(reply.error) });
  }

  async answer(round: number, text: string): Promise<boolean> {
    const reply = await this.call("answer:submit", { round, answer: text }, true);
    if (reply.ok) this.o.dispatch({ type: "answered", round, text });
    else this.o.dispatch({ type: "error", code: String(reply.error) });
    return reply.ok;
  }

  async vote(round: number, owner: string, accept: boolean): Promise<void> {
    const reply = await this.call("vote:cast", { round, playerId: owner, accept }, true);
    if (reply.ok) this.o.dispatch({ type: "voted", round, owner, accept });
    else this.o.dispatch({ type: "error", code: String(reply.error) });
  }

  /** Leaves the room (or forgets a room we can't get back to). */
  async leave(): Promise<void> {
    if (this.seat && this.socket?.connected) await this.call("room:leave", {}, false);
    this.setSeat(null);
    this.room = null;
    this.o.dispatch({ type: "left" });
  }

  // ---- internals ---------------------------------------------------------------------------

  private setSeat(seat: Seat | null): void {
    this.seat = seat;
    this.o.onSeat(seat);
  }

  private async takeSeat(reply: Reply, nickname: string): Promise<void> {
    if (!reply.ok) {
      this.o.dispatch({ type: "error", code: String(reply.error) });
      return;
    }
    const seat: Seat = { roomCode: String(reply.roomCode), playerId: String(reply.playerId), token: String(reply.token), nickname };
    this.setSeat(seat);
    this.onState(reply.state as RoomSnapshot, true, seat);
  }

  private onState(room: RoomSnapshot, seated = false, seat = this.seat): void {
    this.room = room;
    this.offset = room.serverNow - Date.now();
    if (seated && seat) this.o.dispatch({ type: "seated", seat, room, receivedAt: Date.now() });
    else this.o.dispatch({ type: "state", room, receivedAt: Date.now() });
  }

  private open(): Promise<Socket> {
    return new Promise((resolve, reject) => {
      const socket = io({ path: this.o.path, transports: ["websocket"], reconnection: false, timeout: 8000 });
      socket.once("connect_error", (err) => {
        socket.removeAllListeners();
        socket.disconnect();
        reject(err);
      });
      socket.once("connect", () => {
        socket.removeAllListeners("connect_error");
        socket.on("room:state", (room: RoomSnapshot) => this.onState(room));
        socket.on("server:draining", () => void this.reconnect("draining", true));
        socket.on("disconnect", () => {
          if (this.socket === socket && !this.closed) void this.reconnect("dropped", true);
        });
        resolve(socket);
      });
    });
  }

  private drop(): void {
    const s = this.socket;
    this.socket = null;
    s?.removeAllListeners();
    s?.disconnect();
  }

  /** Reconnects (once at a time), with the jitter, and resumes the seat if there is one. */
  private reconnect(reason: "dropped" | "draining" | null, jitter: boolean): Promise<void> {
    this.reconnecting ??= this.doReconnect(reason, jitter).finally(() => {
      this.reconnecting = null;
    });
    return this.reconnecting;
  }

  private async doReconnect(reason: "dropped" | "draining" | null, jitter: boolean): Promise<void> {
    this.drop();
    if (reason) this.o.dispatch({ type: "reconnecting", reason });
    if (jitter) await this.wait(Math.random() * 2000);
    for (let attempt = 1; !this.closed; attempt++) {
      try {
        this.socket = await this.open();
        if (this.closed) {
          this.drop(); // closed while connecting
          return;
        }
        if (!this.seat) break;
        const seat = this.seat;
        const reply = await this.emit("room:resume", { roomCode: seat.roomCode, playerId: seat.playerId, token: seat.token });
        if (reply.ok) {
          const next = { ...seat, token: String(reply.token) };
          this.setSeat(next);
          this.o.dispatch({ type: "token", token: next.token });
          this.onState(reply.state as RoomSnapshot);
          break;
        }
        if (reply.error === "bad_token" || reply.error === "not_found") {
          this.setSeat(null);
          this.o.dispatch({ type: "lost" });
          break;
        }
      } catch {
        // no connection yet: try again
      }
      this.drop();
      await this.wait(Math.min(500 * 2 ** attempt, 5000));
    }
    if (!this.closed && this.socket) this.o.dispatch({ type: "online" });
  }

  /** Sleeps, unless the phone wakes up first. */
  private wait(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const t = setTimeout(done, ms);
      function done() {
        clearTimeout(t);
        resolve();
      }
      this.wakeUp = () => {
        this.wakeUp = null;
        done();
      };
    });
  }

  private async emit(event: string, payload: object): Promise<Reply> {
    const socket = this.socket;
    if (!socket?.connected) throw new Error("not connected");
    return (await socket.timeout(ACK_TIMEOUT_MS).emitWithAck(event, payload)) as Reply;
  }

  /** An action; `resend`: if the reply doesn't come (the connection died), send it once more after the reconnect. */
  private async call(event: string, payload: object, resend: boolean): Promise<Reply> {
    for (let attempt = 1; ; attempt++) {
      if (this.reconnecting) await this.reconnecting;
      try {
        return await this.emit(event, payload);
      } catch {
        if (!resend || attempt >= 2 || this.closed) return { ok: false, error: this.socket?.connected ? "unavailable" : "connect_failed" };
        await sleep(300);
      }
    }
  }

  private async checkWatchdog(): Promise<void> {
    const room = this.room;
    if (!room || room.deadline === null || this.reconnecting || !this.socket?.connected) return;
    const late = Date.now() + this.offset - room.deadline;
    if (late < WATCHDOG_LATE_MS || Date.now() - this.lastSyncAt < WATCHDOG_REPEAT_MS) return;
    this.lastSyncAt = Date.now();
    try {
      const reply = await this.emit("room:sync", {});
      if (reply.ok) this.onState(reply.state as RoomSnapshot);
    } catch {
      // the disconnect handler deals with a dead connection
    }
  }
}
