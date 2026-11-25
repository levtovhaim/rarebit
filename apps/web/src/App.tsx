// The app: one connection for the page's lifetime, one reducer, and the screen for the room's phase.
import { useEffect, useReducer, useRef, useState } from "react";
import { GameConnection } from "./connection";
import { basePath, roomFromSearch, socketPath } from "./location";
import { End, Home, Lobby, Lost, Reconnecting, Results, Round, Vote } from "./screens";
import { loadSeat, saveSeat } from "./session";
import { initialState, reducer } from "./store";

export function App() {
  const [state, dispatch] = useReducer(reducer, initialState);
  const conn = useRef<GameConnection | null>(null);
  // A join link (?room=CODE) fills in the code once; then the address is cleaned.
  const [prefillCode] = useState(() => roomFromSearch(location.search));

  useEffect(() => {
    if (prefillCode) history.replaceState(null, "", location.pathname);
    const c = new GameConnection({ path: socketPath(basePath(location.pathname)), dispatch, onSeat: saveSeat });
    conn.current = c;
    void c.start(loadSeat());
    return () => c.close();
  }, [prefillCode]);

  const c = conn.current;
  if (!c) return null;
  const props = { state, conn: c };
  const room = state.room;

  let screen;
  if (state.lost) screen = <Lost {...props} />;
  else if (!state.seat || !room) screen = <Home {...props} prefillCode={prefillCode} />;
  else if (room.phase === "lobby" || room.phase === "countdown") screen = <Lobby {...props} />;
  // A new round is a new screen: the answer being typed starts empty.
  else if (room.phase === "round") screen = <Round key={room.round} {...props} />;
  else if (room.phase === "voting") screen = <Vote {...props} />;
  else if (room.phase === "results") screen = <Results {...props} />;
  else screen = <End {...props} />;

  return (
    <>
      {state.connection === "reconnecting" && state.seat ? <Reconnecting {...props} /> : null}
      {screen}
    </>
  );
}
