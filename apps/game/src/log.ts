// JSON logs on stdout. Room and round go in as fields (room_id, round), never player answers.
import { pino, type Logger } from "pino";

export type { Logger };

export function createLogger(level: string, version: string, destination?: pino.DestinationStream): Logger {
  return pino(
    {
      level,
      base: { service: "game", version },
      timestamp: pino.stdTimeFunctions.isoTime,
      formatters: { level: (label) => ({ level: label }) },
    },
    destination,
  );
}
