// The countdown: one notebook square per second, crossed out in pencil as time passes, and the
// seconds beside it. Rendered from the server's deadline, so it can't drift. The last 5 seconds
// change shape and size, not only color (and keep still with reduced motion).
import { useEffect, useState, type CSSProperties } from "react";
import { remainingMs, squares } from "./clock";
import { T } from "./copy";

/** Re-renders every `ms` while mounted. */
export function useNow(ms = 200): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

/**
 * `small`: a countdown between phases (to the next round, to the start): smaller, and without the
 * last-seconds alarm, which belongs to the moment players are racing.
 */
export function Timer(props: { deadline: number; phaseMs: number; offset: number; small?: boolean }) {
  const now = useNow();
  const left = remainingMs(props.deadline, props.offset, now);
  const s = { ...squares(props.phaseMs, left) };
  if (props.small) s.urgent = false;
  return (
    <div className={props.small ? "timer timer-small" : "timer"} role="timer" aria-label={T.secondsLeft(s.seconds)}>
      <div className="squares" style={{ "--n": s.total } as CSSProperties} aria-hidden="true">
        {Array.from({ length: s.total }, (_, i) => (
          <span key={i} className={i < s.crossed ? "sq sq-crossed" : s.urgent ? "sq sq-urgent" : "sq"} />
        ))}
      </div>
      <span className={s.urgent ? "seconds seconds-urgent" : "seconds"} aria-hidden="true">
        {s.seconds}
      </span>
      {/* Spoken once, near the end, rather than every second. */}
      <span className="sr-only" aria-live="polite">
        {s.seconds === 5 ? T.secondsLeft(5) : ""}
      </span>
    </div>
  );
}
