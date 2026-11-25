// The screens. Each renders from the room snapshot (and the few things the reducer adds); none
// keeps game state of its own beyond what's being typed.
import { useRef, useState, type FormEvent } from "react";
import { remainingMs } from "./clock";
import type { GameConnection } from "./connection";
import { T, errorText, verdictText } from "./copy";
import { basePath, joinLink, normalizeCode } from "./location";
import { MAX_PLAYERS, MIN_PRIVATE_PLAYERS, ROOM_CODE, type PublicPlayer, type RoomSnapshot } from "./protocol";
import { Qr } from "./Qr";
import { loadNickname, saveNickname } from "./session";
import { me, type State } from "./store";
import { Timer, useNow } from "./Timer";

interface ScreenProps {
  state: State;
  conn: GameConnection;
}

/** The nickname rule the game applies: 2–16 Hebrew or Latin letters, digits, spaces, - _ '. */
const NICKNAME = /^[א-תA-Za-z0-9 _'-]{2,16}$/;
const cleanNickname = (s: string) => s.trim().replace(/\s+/g, " ");

function ErrorNote(props: { code: string | null }) {
  return props.code ? (
    <p className="note note-error" role="alert">
      {errorText(props.code)}
    </p>
  ) : null;
}

function Head(props: { room: RoomSnapshot; state: State }) {
  const mine = me(props.state);
  return (
    <header className="sheet-head">
      <span>{props.room.round > 0 ? T.round(props.room.round, props.room.maxRounds) : props.room.type === "private" ? T.roomCode : T.quickplay}</span>
      {mine && props.room.round > 0 ? (
        <bdi className="mono">{T.points(mine.score)}</bdi>
      ) : null}
    </header>
  );
}

// ---- Home ---------------------------------------------------------------------------------

/** A row from the paper game, for the letter ב: what a round asks for, at a glance. */
const EXAMPLE: Array<[string, string]> = [
  ["ארץ", "בלגיה"],
  ["עיר", "באר שבע"],
  ["חי", "ברווז"],
  ["צומח", "בננה"],
  ["שם", "בני"],
  ["מקצוע", "בנאי"],
];

function Example() {
  return (
    <figure className="example" aria-label={T.exampleLabel}>
      <span className="example-letter" aria-hidden="true">
        ב
      </span>
      <dl>
        {EXAMPLE.map(([category, answer]) => (
          <div key={category}>
            <dt>{category}</dt>
            <dd>{answer}</dd>
          </div>
        ))}
      </dl>
    </figure>
  );
}

export function Home(props: ScreenProps & { prefillCode: string | null }) {
  const [nickname, setNickname] = useState(loadNickname);
  const [code, setCode] = useState(props.prefillCode ?? "");
  const [busy, setBusy] = useState(false);
  const [tried, setTried] = useState(false);
  const nicknameInput = useRef<HTMLInputElement>(null);
  const nick = cleanNickname(nickname);
  const nickOk = NICKNAME.test(nick);
  const online = props.state.connection === "online";
  // Enabled unless offline or a request is running: a tap with a bad nickname explains it.
  const can = online && !busy;
  const showRule = (tried || nickname !== "") && !nickOk;

  async function act(fn: () => Promise<void>) {
    if (!nickOk) {
      setTried(true);
      nicknameInput.current?.focus();
      return;
    }
    saveNickname(nick);
    setBusy(true);
    try {
      await fn();
    } finally {
      setBusy(false);
    }
  }
  function onJoin(e: FormEvent) {
    e.preventDefault();
    if (can && ROOM_CODE.test(code)) void act(() => props.conn.join(code, nick));
  }

  return (
    <main className="sheet">
      <header className="sheet-head">
        <span />
        <span aria-live="polite">{online ? "" : T.connecting}</span>
      </header>
      <div className="sheet-body">
        <h1 className="display wordmark">
          ארץ עיר
          <small dir="ltr" translate="no">
            RAREBIT
          </small>
        </h1>
        <p className="lead">{T.tagline}</p>
        <Example />
        <div className="field">
          <label htmlFor="nickname">{T.nicknameLabel}</label>
          <input
            id="nickname"
            ref={nicknameInput}
            name="nickname"
            className="input"
            value={nickname}
            onChange={(e) => setNickname(e.target.value)}
            placeholder={T.nicknamePlaceholder}
            maxLength={16}
            autoComplete="nickname"
            enterKeyHint="done"
            aria-invalid={showRule}
            aria-describedby="nickname-rule"
          />
          <small id="nickname-rule" className="verdict-bad" aria-live="polite">
            {showRule ? errorText("bad_nickname") : ""}
          </small>
        </div>
        <ErrorNote code={props.state.error} />
      </div>
      <div className="thumb">
        <button className="button button-ink choice" disabled={!can} onClick={() => void act(() => props.conn.create(nick))}>
          <span>{busy ? T.working : T.createRoom}</span>
          <small>{T.createRoomHint}</small>
        </button>
        <button className="button button-paper choice" disabled={!can} onClick={() => void act(() => props.conn.quickplay(nick))}>
          <span>{busy ? T.working : T.quickplay}</span>
          <small>{T.quickplayHint}</small>
        </button>
        <div className="rule">{T.joinTitle}</div>
        <form className="row" onSubmit={onJoin}>
          <label className="sr-only" htmlFor="code">
            {T.codeLabel}
          </label>
          <input
            id="code"
            name="room-code"
            translate="no"
            className="input input-code grow"
            dir="ltr"
            value={code}
            onChange={(e) => setCode(normalizeCode(e.target.value))}
            placeholder="ABC234"
            autoCapitalize="characters"
            autoComplete="off"
            spellCheck={false}
            enterKeyHint="go"
          />
          <button className="button button-paper" type="submit" disabled={!can || !ROOM_CODE.test(code)}>
            {busy ? T.working : T.join}
          </button>
        </form>
      </div>
    </main>
  );
}

// ---- The lobby ----------------------------------------------------------------------------

function PlayerList(props: { players: PublicPlayer[]; state: State; showScore?: boolean }) {
  const room = props.state.room!;
  return (
    <ul className="players">
      {props.players.map((p) => (
        <li key={p.id}>
          <span className="name">
            <bdi className={p.id === props.state.seat?.playerId ? "mine" : undefined}>{p.nickname}</bdi>
          </span>
          {p.id === props.state.seat?.playerId ? <span className="tag tag-ink">{T.you}</span> : null}
          {p.id === room.hostId ? <span className="tag">{T.host}</span> : null}
          {!p.connected && !p.left ? <span className="tag">{T.offline}</span> : null}
          {props.showScore ? <span className="score">{p.score}</span> : null}
        </li>
      ))}
    </ul>
  );
}

export function Lobby(props: ScreenProps) {
  const room = props.state.room!;
  const [copied, setCopied] = useState(false);
  const present = room.players.filter((p) => !p.left);
  const isHost = room.hostId === props.state.seat?.playerId;
  const link = joinLink(location.origin, basePath(location.pathname), room.code);

  async function share() {
    const text = `בואו לשחק ארץ עיר. קוד החדר: ${room.code}`;
    try {
      if (navigator.share) await navigator.share({ title: "Rarebit", text, url: link });
      else {
        await navigator.clipboard.writeText(link);
        setCopied(true);
      }
    } catch {
      // the player closed the share sheet
    }
  }

  return (
    <main className="sheet">
      <Head room={room} state={props.state} />
      <div className="sheet-body">
        {room.type === "private" ? (
          <>
            <h1 className="sr-only">{`${T.roomCode}: ${room.code.split("").join(" ")}`}</h1>
            <div className="code" translate="no" aria-hidden="true">
              {room.code.split("").map((c, i) => (
                <span key={i}>{c}</span>
              ))}
            </div>
            <Qr text={link} label={T.scanToJoin} />
            <p className="center lead">{T.scanToJoin}</p>
          </>
        ) : (
          <>
            <h1 className="display title">{room.phase === "countdown" ? T.startsIn : T.lookingForPlayers}</h1>
            {room.phase === "countdown" && room.deadline !== null && props.state.phase ? (
              <Timer deadline={room.deadline} phaseMs={props.state.phase.ms} offset={props.state.offset} small />
            ) : (
              <p className="note note-wait">{T.quickplayNeeds}</p>
            )}
          </>
        )}
        <h2 className="lead">{T.players(present.length, MAX_PLAYERS)}</h2>
        <PlayerList players={present} state={props.state} />
        <ErrorNote code={props.state.error} />
      </div>
      <div className="thumb">
        {room.type === "private" ? (
          <>
            <button className="button button-paper" onClick={() => void share()}>
              {copied ? T.linkCopied : T.shareLink}
            </button>
            {isHost ? (
              <button className="button button-ink" disabled={present.length < MIN_PRIVATE_PLAYERS || room.phase !== "lobby"} onClick={() => void props.conn.startGame()}>
                {present.length < MIN_PRIVATE_PLAYERS ? T.needTwo : T.startGame}
              </button>
            ) : (
              <p className="note note-wait center">{T.waitingForHost}</p>
            )}
          </>
        ) : null}
        <button className="button button-quiet" onClick={() => void props.conn.leave()}>
          {T.leave}
        </button>
      </div>
    </main>
  );
}

// ---- A round ------------------------------------------------------------------------------

export function Round(props: ScreenProps) {
  const room = props.state.room!;
  const mine = me(props.state);
  const [text, setText] = useState("");
  const now = useNow(500);
  const timeUp = room.deadline !== null && remainingMs(room.deadline, props.state.offset, now) === 0;
  const out = mine?.eliminated || mine?.left;
  const sent = props.state.sent?.round === room.round ? props.state.sent.text : null;

  function onSend(e: FormEvent) {
    e.preventDefault();
    const answer = text.trim();
    if (answer && !timeUp) void props.conn.answer(room.round, answer);
  }

  return (
    <main className="sheet">
      <Head room={room} state={props.state} />
      <div className="sheet-body">
        <h1 className="sr-only">{T.answerLabel(room.category?.name ?? "", room.letter ?? "")}</h1>
        <div className="prompt" aria-hidden="true">
          <div className="letter">
            <span>{room.letter}</span>
          </div>
          <div className="category">
            <small>{T.category}</small>
            <strong>{room.category?.name}</strong>
          </div>
        </div>
        {room.deadline !== null && props.state.phase ? <Timer deadline={room.deadline} phaseMs={props.state.phase.ms} offset={props.state.offset} /> : null}
        {room.notice === "waiting_for_categories" ? <p className="note note-wait">{T.waitingForCategories}</p> : null}
      </div>
      <div className="thumb">
        {out ? (
          <p className="note">{T.eliminated}</p>
        ) : (
          <form className="field" onSubmit={onSend}>
            <label htmlFor="answer">{T.answerLabel(room.category?.name ?? "", room.letter ?? "")}</label>
            <div className="row">
              {/* autoFocus on purpose: the round is a race and this is its only input. Phones
                  that need a tap to open the keyboard still get the field ready. Autocorrect
                  off: it would rewrite a Hebrew answer into another word. */}
              <input
                id="answer"
                name="answer"
                className="input grow"
                value={text}
                onChange={(e) => setText(e.target.value)}
                placeholder={T.answerPlaceholder}
                maxLength={64}
                autoComplete="off"
                autoCorrect="off"
                spellCheck={false}
                autoFocus
                enterKeyHint="send"
                disabled={timeUp}
              />
              <button className="button button-ink" type="submit" disabled={timeUp || text.trim() === ""}>
                {T.send}
              </button>
            </div>
            <p className="lead" aria-live="polite">
              {timeUp ? T.timeUp : sent ? `${T.sent(sent)} · ${T.canChange}` : ""}
            </p>
          </form>
        )}
        <ErrorNote code={props.state.error} />
      </div>
    </main>
  );
}

// ---- The room vote ------------------------------------------------------------------------

export function Vote(props: ScreenProps) {
  const room = props.state.room!;
  const myId = props.state.seat?.playerId;
  const items = room.voting ?? [];
  const mineVoted = items.some((i) => i.playerId === myId);
  const others = items.filter((i) => i.playerId !== myId);
  const cast = props.state.votes.round === room.round ? props.state.votes.byOwner : {};
  return (
    <main className="sheet">
      <Head room={room} state={props.state} />
      <div className="sheet-body">
        <h1 className="display title">{T.voteTitle}</h1>
        <p className="lead">{T.voteQuestion(room.category?.name ?? "", room.letter ?? "")}</p>
        {room.deadline !== null && props.state.phase ? <Timer deadline={room.deadline} phaseMs={props.state.phase.ms} offset={props.state.offset} small /> : null}
        {mineVoted ? <p className="note note-wait">{T.yourAnswerIsVoted}</p> : null}
        {others.length === 0 && !mineVoted ? <p className="note">{T.noOneToVote}</p> : null}
        {others.map((item) => (
          <div className="vote-item" key={item.playerId}>
            <span className="answer">
              <bdi>{item.answer}</bdi>
            </span>
            <span className="lead">
              <bdi>{item.nickname}</bdi>
            </span>
            <div className="row">
              <button className="button button-ink grow" aria-pressed={cast[item.playerId] === true} onClick={() => void props.conn.vote(room.round, item.playerId, true)}>
                ✓ {T.accept}
              </button>
              <button className="button button-paper grow" aria-pressed={cast[item.playerId] === false} onClick={() => void props.conn.vote(room.round, item.playerId, false)}>
                ✗ {T.reject}
              </button>
            </div>
            {item.playerId in cast ? <span className="lead">{T.voted(cast[item.playerId]!)}</span> : null}
          </div>
        ))}
        <ErrorNote code={props.state.error} />
      </div>
      <div className="thumb" />
    </main>
  );
}

// ---- Results and the end ------------------------------------------------------------------

function Standings(props: { state: State }) {
  const players = [...props.state.room!.players].filter((p) => !p.left).sort((a, b) => b.score - a.score || a.strikes - b.strikes);
  return (
    <ul className="players">
      {players.map((p) => (
        <li key={p.id}>
          <span className="name">
            <bdi className={p.id === props.state.seat?.playerId ? "mine" : undefined}>{p.nickname}</bdi>
          </span>
          {p.strikes > 0 ? (
            <span className="strikes" aria-label={`${p.strikes} ${T.strike}`}>
              {"✗".repeat(p.strikes)}
            </span>
          ) : null}
          {p.eliminated ? <span className="tag tag-red">נפסל/ה</span> : null}
          <span className="score">{p.score}</span>
        </li>
      ))}
    </ul>
  );
}

export function Results(props: ScreenProps) {
  const room = props.state.room!;
  const r = room.lastResults;
  return (
    <main className="sheet">
      <Head room={room} state={props.state} />
      <div className="sheet-body">
        <h1 className="display title">{T.resultsTitle(r?.round ?? room.round)}</h1>
        {r ? (
          <ul className="results">
            {r.answers.map((a) => {
              const v = verdictText(a);
              return (
                <li key={a.playerId}>
                  <span className="who">
                    <bdi className={a.playerId === props.state.seat?.playerId ? "mine" : undefined}>{a.nickname}</bdi>
                  </span>
                  <span className={a.answer ? "answer" : "answer answer-empty"}>
                    <bdi>{a.answer || "—"}</bdi>
                  </span>
                  <span className={a.final === "valid" ? "verdict" : "verdict verdict-bad"}>
                    {v.mark} {v.word}
                    {a.strike ? ` · ${T.strike}` : ""}
                  </span>
                  <span className={a.strike ? "points points-strike" : "points"}>{a.strike ? "✗" : `+${a.points}`}</span>
                </li>
              );
            })}
          </ul>
        ) : null}
        <h2 className="lead">{T.standings}</h2>
        <Standings state={props.state} />
      </div>
      <div className="thumb">
        {room.deadline !== null && props.state.phase ? (
          <>
            <span className="lead">{T.nextRoundIn}</span>
            <Timer deadline={room.deadline} phaseMs={props.state.phase.ms} offset={props.state.offset} small />
          </>
        ) : null}
      </div>
    </main>
  );
}

export function End(props: ScreenProps) {
  const room = props.state.room!;
  const winners = (room.winners ?? []).map((id) => room.players.find((p) => p.id === id)?.nickname ?? "");
  return (
    <main className="sheet">
      <Head room={room} state={props.state} />
      <div className="sheet-body">
        <h1 className="display title">{T.gameOver}</h1>
        <p className="lead">{winners.length > 1 ? T.tie : T.winner}</p>
        {winners.map((w) => (
          <span className="winner" key={w}>
            <bdi>{w}</bdi>
          </span>
        ))}
        <h2 className="lead">{T.standings}</h2>
        <Standings state={props.state} />
      </div>
      <div className="thumb">
        <button className="button button-ink" onClick={() => void props.conn.leave()}>
          {T.playAgain}
        </button>
      </div>
    </main>
  );
}

export function Lost(props: ScreenProps) {
  return (
    <main className="sheet">
      <span />
      <div className="sheet-body">
        <h1 className="display title">{T.lostTitle}</h1>
        <p className="lead">{T.lostBody}</p>
      </div>
      <div className="thumb">
        <button className="button button-ink" onClick={() => void props.conn.leave()}>
          {T.backHome}
        </button>
      </div>
    </main>
  );
}

export function Reconnecting(props: ScreenProps) {
  return (
    <div className="banner" role="status">
      <span>{props.state.reconnectReason === "draining" ? T.serverSwitching : T.reconnecting}</span>
      <button
        className="button button-quiet"
        onClick={() => {
          // Mid-game, leaving gives up the seat for good: ask first.
          const playing = props.state.room && props.state.room.phase !== "lobby" && props.state.room.phase !== "ended";
          if (!playing || confirm(T.leaveConfirm)) void props.conn.leave();
        }}
      >
        {T.backHome}
      </button>
    </div>
  );
}
