import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  // Relative asset URLs: the same build works at / and under a path prefix (a path-based preview).
  base: "./",
  plugins: [react()],
  // assetsInlineLimit 0: every asset is a file, never a data: URL inlined into the CSS. The page's
  // Content-Security-Policy allows fonts from its own origin only (apps/web/nginx.conf), and Vite
  // would inline the smallest font subsets; as files they're also cached once across builds.
  build: { target: "es2022", sourcemap: true, assetsInlineLimit: 0 },
  server: {
    // `npm run dev` plays against the local stack (make up) through its nginx.
    proxy: { "/socket.io": { target: "http://127.0.0.1:8080", ws: true } },
    // A checkout on a Windows drive under WSL (/mnt/...) sends no file-change events into WSL:
    // poll, or edits never reach the page.
    watch: process.cwd().startsWith("/mnt/") ? { usePolling: true, interval: 300 } : undefined,
  },
  test: { environment: "node", include: ["test/**/*.test.ts"] },
});
