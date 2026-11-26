// Prometheus metrics on a registry of the server's own. Counts that only Redis knows (active rooms,
// the quick-play queue) are read when Prometheus scrapes.
import client from "@prometheus-io/client";

export interface Gauges {
  roomsActive: () => Promise<{ private: number; public: number }>;
  queueLength: () => Promise<number>;
  playersConnected: () => number;
  draining: () => boolean;
}

export function createMetrics(gauges: Gauges) {
  const registry = new client.Registry();
  client.collectDefaultMetrics({ register: registry });

  const counter = (name: string, help: string, labelNames: string[] = []) =>
    new client.Counter({ name, help, labelNames, registers: [registry] });
  const histogram = (name: string, help: string, buckets: number[]) =>
    new client.Histogram({ name, help, buckets, registers: [registry] });

  const m = {
    registry,
    roundsTotal: counter("game_rounds_total", "Rounds finished."),
    answersTotal: counter("game_answers_total", "Answers scored, by result.", ["result"]),
    filterBlockedTotal: counter("game_filter_blocked_total", "Nicknames and answers the offensive-word filter blocked.", ["field"]),
    wsDisconnectsTotal: counter("game_ws_disconnects_total", "WebSocket disconnects, by reason.", ["reason"]),
    redisErrorsTotal: counter("game_redis_errors_total", "Redis client errors and failed Redis operations."),
    rateLimitedTotal: counter("game_rate_limited_total", "Client events refused by the per-socket rate limit."),
    connectionsRefusedTotal: counter(
      "game_connections_refused_total",
      "WebSocket connections refused, by reason: not_ready, origin, per_ip.",
      ["reason"],
    ),
    answerAckSeconds: histogram("game_answer_ack_seconds", "Time from receiving an answer to acknowledging it.", [
      0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1,
    ]),
    validationSeconds: histogram("game_validation_seconds", "Validator calls, including the retry.", [
      0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5,
    ]),
    matchmakingWaitSeconds: histogram("game_matchmaking_wait_seconds", "Quick play: from joining to the game starting.", [
      1, 2.5, 5, 10, 15, 30, 60, 120, 300,
    ]),
  };

  new client.Gauge({
    name: "game_rooms_active",
    help: "Rooms with activity within the room TTL, across all pods.",
    labelNames: ["type"],
    registers: [registry],
    async collect() {
      const counts = await gauges.roomsActive();
      this.set({ type: "private" }, counts.private);
      this.set({ type: "public" }, counts.public);
    },
  });
  new client.Gauge({
    name: "game_matchmaking_queue_length",
    help: "Players waiting in the open quick-play room, across all pods.",
    registers: [registry],
    async collect() {
      this.set(await gauges.queueLength());
    },
  });
  new client.Gauge({
    name: "game_players_connected",
    help: "Sockets connected to this pod.",
    registers: [registry],
    collect() {
      this.set(gauges.playersConnected());
    },
  });
  new client.Gauge({
    name: "game_draining",
    help: "1 while this pod is shutting down.",
    registers: [registry],
    collect() {
      this.set(gauges.draining() ? 1 : 0);
    },
  });
  return m;
}

export type Metrics = ReturnType<typeof createMetrics>;
