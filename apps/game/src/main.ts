// The game server process: config from the environment, one server, and the shutdown sequence on
// SIGTERM (a second signal ends the process at once).
import { createGameServer } from "./app.js";
import { ConfigError, loadConfig, type Config } from "./config.js";
import { createLogger } from "./log.js";

let config: Config;
try {
  config = loadConfig(process.env);
} catch (err) {
  const log = createLogger("info", process.env.GIT_SHA ?? "unknown");
  log.error({ err: err instanceof ConfigError ? err.message : String(err) }, "invalid configuration");
  process.exit(1);
}

const log = createLogger(config.LOG_LEVEL, config.GIT_SHA);
const server = createGameServer(config, log);

let stopping = false;
function shutdown(signal: string) {
  if (stopping) {
    log.warn({ signal }, "second signal: exiting now");
    process.exit(1);
  }
  stopping = true;
  const hardStop = setTimeout(() => {
    log.error({ timeout: config.SHUTDOWN_TIMEOUT_SECONDS }, "shutdown timed out");
    process.exit(1);
  }, (config.DRAIN_DELAY_SECONDS + config.SHUTDOWN_TIMEOUT_SECONDS) * 1000);
  hardStop.unref();
  server.drain().then(
    () => process.exit(0),
    (err: unknown) => {
      log.error({ err: String(err) }, "shutdown failed");
      process.exit(1);
    },
  );
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

server.start(config.GAME_PORT).catch((err: unknown) => {
  log.error({ err: String(err) }, "start failed");
  process.exit(1);
});
