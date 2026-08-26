import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// Inlines all JS, CSS, and data into one self-contained HTML file that opens by double-click
// (works over file://, unlike the module-based default build) and can be shared as a single
// attachment or dropped onto any static host.
export default defineConfig({
  plugins: [viteSingleFile()],
  build: {
    outDir: "standalone",
    emptyOutDir: true,
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    reportCompressedSize: false,
  },
});
