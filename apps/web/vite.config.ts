import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  // Relative asset URLs: the same build works at / and under a path prefix (a path-based preview).
  base: "./",
  plugins: [react()],
  build: { target: "es2022", sourcemap: true },
  server: {
    // `npm run dev` plays against the local stack (make up) through its nginx.
    proxy: { "/socket.io": { target: "http://127.0.0.1:8080", ws: true } },
    // A checkout on a Windows drive under WSL (/mnt/...) sends no file-change events into WSL:
    // poll, or edits never reach the page.
    watch: process.cwd().startsWith("/mnt/") ? { usePolling: true, interval: 300 } : undefined,
  },
  test: { environment: "node", include: ["test/**/*.test.ts"] },
});
