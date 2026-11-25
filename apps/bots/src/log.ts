// JSON lines on stdout: one object per line, with level, time, service and version. No library:
// the bots log little, and a report line is just another line.
export type Level = "debug" | "info" | "warn" | "error";
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export interface Logger {
  debug(msg: string, fields?: Record<string, unknown>): void;
  info(msg: string, fields?: Record<string, unknown>): void;
  warn(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
  child(fields: Record<string, unknown>): Logger;
}

export function createLogger(
  level: Level,
  base: Record<string, unknown> = {},
  write: (line: string) => void = (line) => process.stdout.write(line + "\n"),
): Logger {
  const min = ORDER[level];
  const emit = (l: Level, msg: string, fields?: Record<string, unknown>) => {
    if (ORDER[l] < min) return;
    write(JSON.stringify({ level: l, time: new Date().toISOString(), service: "bots", ...base, ...fields, msg }));
  };
  return {
    debug: (m, f) => emit("debug", m, f),
    info: (m, f) => emit("info", m, f),
    warn: (m, f) => emit("warn", m, f),
    error: (m, f) => emit("error", m, f),
    child: (fields) => createLogger(level, { ...base, ...fields }, write),
  };
}

/** A logger that drops everything: for tests. */
export const silent: Logger = createLogger("error", {}, () => {});
