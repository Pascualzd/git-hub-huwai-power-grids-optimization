import { defineConfig } from "vite";

// Relative base so the built site works when opened from a file path or served from a
// subdirectory (e.g. GitHub Pages) without extra configuration.
export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
