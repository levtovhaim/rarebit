// One game action against a running server, for the image smoke test: connect over WebSocket,
// create a room, read it back. Run with Node directly (it strips the types):
//
//   node test/smoke-client.ts http://127.0.0.1:<port>
//
// Exit 0 and one line of JSON on success; exit 1 with the reason otherwise.
import { io } from "socket.io-client";

const url = process.argv[2];
if (!url) {
  console.error("usage: node test/smoke-client.ts <server url>");
  process.exit(1);
}

const socket = io(url, { transports: ["websocket"], reconnection: false, timeout: 5000 });
const fail = (why: string) => {
  console.error(`smoke client: ${why}`);
  socket.disconnect();
  process.exit(1);
};
const timer = setTimeout(() => fail("no answer within 10 s"), 10_000);

socket.on("connect_error", (err) => fail(`connect failed: ${err.message}`));
socket.on("connect", async () => {
  const created = await socket.timeout(5000).emitWithAck("room:create", { nickname: "בדיקה" });
  if (!created?.ok || typeof created.roomCode !== "string") return fail(`room:create: ${JSON.stringify(created)}`);
  const synced = await socket.timeout(5000).emitWithAck("room:sync", {});
  if (!synced?.ok || synced.state?.code !== created.roomCode || synced.state?.phase !== "lobby") {
    return fail(`room:sync: ${JSON.stringify(synced)}`);
  }
  clearTimeout(timer);
  console.log(JSON.stringify({ roomCode: created.roomCode, phase: synced.state.phase, players: synced.state.players.length }));
  socket.disconnect();
});
