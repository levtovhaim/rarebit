// The repo's word lists, as the bots load them by default.
import { loadConfig } from "../src/config.js";

export const config = loadConfig(["synthetic", "--url", "http://127.0.0.1:1"], {});
