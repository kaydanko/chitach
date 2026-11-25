import { defineConfig } from "vite";
import { epubServer } from "./epubServer.ts";

export default defineConfig({
  plugins: [epubServer("public/sample.epub")],
  // Tauri віддає зібрані файли з диска, а не з кореня сервера, тому шляхи
  // мають бути відносні.
  base: "./",
  build: {
    target: "es2022",
    outDir: "dist",
  },
  server: {
    port: 5273,
    strictPort: true,
  },
});
