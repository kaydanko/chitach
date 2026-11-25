import type { Plugin } from "vite";
import { readFileSync } from "node:fs";
import { unzipSync } from "fflate";
import { resolve } from "node:path";

/**
 * Віддає вміст книги по HTTP під час розробки.
 *
 * Потрібен не для самого тексту розділу — його навігатор бере з фетчера, —
 * а для того, що всередині: стилів, шрифтів і картинок. Їх браузер тягне за
 * адресою з `<base>`, тобто звичайним запитом. У збірці те саме робить
 * обробник власної схеми в Tauri.
 */
const TYPES: Record<string, string> = {
  xhtml: "application/xhtml+xml",
  html: "text/html",
  css: "text/css",
  js: "text/javascript",
  xml: "application/xml",
  ncx: "application/x-dtbncx+xml",
  opf: "application/oebps-package+xml",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  gif: "image/gif",
  svg: "image/svg+xml",
  webp: "image/webp",
  ttf: "font/ttf",
  otf: "font/otf",
  woff: "font/woff",
  woff2: "font/woff2",
};

export function epubServer(bookPath: string): Plugin {
  let entries: Record<string, Uint8Array> | null = null;

  const load = () => {
    if (!entries) {
      entries = unzipSync(new Uint8Array(readFileSync(resolve(bookPath))));
    }
    return entries;
  };

  return {
    name: "chytach-epub-server",
    configureServer(server) {
      server.middlewares.use("/epub/", (req, res, next) => {
        const url = (req.url ?? "").split(/[?#]/)[0];
        const path = decodeURIComponent(url.replace(/^\//, ""));
        const bytes = load()[path];
        if (!bytes) return next();

        const extension = path.split(".").pop()?.toLowerCase() ?? "";
        res.setHeader("Content-Type", TYPES[extension] ?? "application/octet-stream");
        res.end(Buffer.from(bytes));
      });
    },
  };
}
