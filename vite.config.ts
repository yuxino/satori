import { defineConfig } from "vite";

// Tauri expects a fixed dev port and the frontend to be built to ../dist.
export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      ignored: ["**/src-tauri/**"],
    },
  },
  envPrefix: ["VITE_", "TAURI_"],
  build: {
    target: "es2021",
    outDir: "dist",
    // Production assets are embedded in the desktop binary. Source maps add
    // package weight and expose sources without helping the supported dev app.
    sourcemap: false,
  },
});
