import { entryAsText, type ZipEntries } from "./zip.ts";

/**
 * Збирає з EPUB маніфест Readium Web Publication.
 *
 * Це та частина, якої в TypeScript-тулкіті немає: `@readium/shared` уміє
 * лише `HttpFetcher` і чекає готовий маніфест із сервера. У Swift і Kotlin
 * ту саму роботу робить Streamer, тут доводиться своїми руками — зате вона
 * невелика й цілком передбачувана.
 */

const CONTAINER = "META-INF/container.xml";
const OPF_NS = "http://www.idpf.org/2007/opf";
const DC_NS = "http://purl.org/dc/elements/1.1/";
const XHTML_NS = "http://www.w3.org/1999/xhtml";
const EPUB_NS = "http://www.idpf.org/2007/ops";
const NCX_NS = "http://www.daisy.org/z3986/2005/ncx/";

export interface TocEntry {
  href: string;
  title: string;
  children?: TocEntry[];
}

export interface EpubManifest {
  json: Record<string, unknown>;
  /** Шляхи розділів у порядку читання — ними ж користується фетчер. */
  readingOrder: string[];
}

function parseXML(text: string, type: DOMParserSupportedType): Document {
  const doc = new DOMParser().parseFromString(text, type);
  const error = doc.querySelector("parsererror");
  if (error) throw new Error(`Не вдалося розібрати XML: ${error.textContent}`);
  return doc;
}

/** Шлях відносно файлу в архіві → шлях від кореня архіву. */
function resolvePath(base: string, href: string): string {
  const baseDir = base.includes("/") ? base.slice(0, base.lastIndexOf("/") + 1) : "";
  const resolved = new URL(href, `chytach:///${baseDir}`);
  return decodeURIComponent(resolved.pathname.slice(1));
}

function findOpfPath(entries: ZipEntries): string {
  const doc = parseXML(entryAsText(entries, CONTAINER), "application/xml");
  const rootfile = doc.querySelector("rootfile");
  const path = rootfile?.getAttribute("full-path");
  if (!path) throw new Error("У container.xml немає rootfile");
  return path;
}

function textOf(parent: Element | Document, ns: string, name: string): string | undefined {
  const node = parent.getElementsByTagNameNS(ns, name)[0];
  const value = node?.textContent?.trim();
  return value ? value : undefined;
}

/** Усі значення тегу, а не лише перше: авторів у книзі буває кілька. */
function allTextOf(parent: Element, ns: string, name: string): string[] {
  return Array.from(parent.getElementsByTagNameNS(ns, name))
    .map((node) => node.textContent?.trim() ?? "")
    .filter((value) => value.length > 0);
}

function tocFromNavDocument(entries: ZipEntries, navPath: string): TocEntry[] {
  const doc = parseXML(entryAsText(entries, navPath), "application/xhtml+xml");

  const navs = Array.from(doc.getElementsByTagNameNS(XHTML_NS, "nav"));
  const toc =
    navs.find((nav) => nav.getAttributeNS(EPUB_NS, "type") === "toc") ?? navs[0];
  if (!toc) return [];

  const readList = (list: Element): TocEntry[] => {
    const items: TocEntry[] = [];
    for (const li of Array.from(list.children)) {
      if (li.localName !== "li") continue;
      const anchor = Array.from(li.children).find((c) => c.localName === "a");
      const nested = Array.from(li.children).find((c) => c.localName === "ol");
      const href = anchor?.getAttribute("href");
      if (!href) continue;
      const entry: TocEntry = {
        href: resolvePath(navPath, href),
        title: anchor?.textContent?.trim() ?? "",
      };
      if (nested) {
        const children = readList(nested);
        if (children.length > 0) entry.children = children;
      }
      items.push(entry);
    }
    return items;
  };

  const list = Array.from(toc.children).find((c) => c.localName === "ol");
  return list ? readList(list) : [];
}

function tocFromNcx(entries: ZipEntries, ncxPath: string): TocEntry[] {
  const doc = parseXML(entryAsText(entries, ncxPath), "application/xml");
  const navMap = doc.getElementsByTagNameNS(NCX_NS, "navMap")[0];
  if (!navMap) return [];

  const readPoints = (parent: Element): TocEntry[] => {
    const items: TocEntry[] = [];
    for (const point of Array.from(parent.children)) {
      if (point.localName !== "navPoint") continue;
      const content = point.getElementsByTagNameNS(NCX_NS, "content")[0];
      const href = content?.getAttribute("src");
      if (!href) continue;
      const label = point.getElementsByTagNameNS(NCX_NS, "text")[0];
      const entry: TocEntry = {
        href: resolvePath(ncxPath, href),
        title: label?.textContent?.trim() ?? "",
      };
      const children = readPoints(point);
      if (children.length > 0) entry.children = children;
      items.push(entry);
    }
    return items;
  };

  return readPoints(navMap);
}

function tocToLinks(toc: TocEntry[]): Record<string, unknown>[] {
  return toc.map((entry) => {
    const link: Record<string, unknown> = { href: entry.href, title: entry.title };
    if (entry.children) link.children = tocToLinks(entry.children);
    return link;
  });
}

/**
 * @param baseURL адреса, з якої віддаються ресурси книги; саме відносно неї
 *   навігатор розв'язує посилання всередині розділів.
 */
export function buildManifest(entries: ZipEntries, baseURL: string): EpubManifest {
  const opfPath = findOpfPath(entries);
  const opf = parseXML(entryAsText(entries, opfPath), "application/xml");

  const metadataNode = opf.getElementsByTagNameNS(OPF_NS, "metadata")[0];
  const title = metadataNode ? textOf(metadataNode, DC_NS, "title") : undefined;
  const authors = metadataNode ? allTextOf(metadataNode, DC_NS, "creator") : [];
  const language = metadataNode ? textOf(metadataNode, DC_NS, "language") : undefined;
  const identifier = metadataNode ? textOf(metadataNode, DC_NS, "identifier") : undefined;

  interface Item {
    href: string;
    type: string;
    properties: string[];
  }
  const items = new Map<string, Item>();
  for (const node of Array.from(opf.getElementsByTagNameNS(OPF_NS, "item"))) {
    const id = node.getAttribute("id");
    const href = node.getAttribute("href");
    if (!id || !href) continue;
    items.set(id, {
      href: resolvePath(opfPath, href),
      type: node.getAttribute("media-type") ?? "application/octet-stream",
      properties: (node.getAttribute("properties") ?? "").split(/\s+/).filter(Boolean),
    });
  }

  const spine = opf.getElementsByTagNameNS(OPF_NS, "spine")[0];
  const readingOrder: string[] = [];
  const readingOrderLinks: Record<string, unknown>[] = [];
  for (const ref of Array.from(opf.getElementsByTagNameNS(OPF_NS, "itemref"))) {
    // linear="no" — додатки на кшталт приміток: у порядок читання не йдуть.
    if (ref.getAttribute("linear") === "no") continue;
    const item = items.get(ref.getAttribute("idref") ?? "");
    if (!item) continue;
    readingOrder.push(item.href);
    readingOrderLinks.push({ href: item.href, type: item.type });
  }
  if (readingOrderLinks.length === 0) {
    throw new Error("У книзі порожній порядок читання");
  }

  const inSpine = new Set(readingOrder);
  const resources = Array.from(items.values())
    .filter((item) => !inSpine.has(item.href))
    .map((item) => ({ href: item.href, type: item.type }));

  const navItem = Array.from(items.values()).find((i) => i.properties.includes("nav"));
  const ncxId = spine?.getAttribute("toc");
  const ncxItem = ncxId ? items.get(ncxId) : undefined;

  let toc: TocEntry[] = [];
  try {
    if (navItem) toc = tocFromNavDocument(entries, navItem.href);
    else if (ncxItem) toc = tocFromNcx(entries, ncxItem.href);
  } catch {
    // Зміст — не причина не відкрити книгу.
    toc = [];
  }

  const metadata: Record<string, unknown> = {
    "@type": "http://schema.org/Book",
    title: title ?? "Без назви",
  };
  if (authors.length > 0) metadata.author = authors;
  if (language) metadata.language = language;
  if (identifier) metadata.identifier = identifier;

  const json: Record<string, unknown> = {
    "@context": "https://readium.org/webpub-manifest/context.jsonld",
    metadata,
    // Посилання `self` визначає базову адресу публікації: саме від неї
    // навігатор рахує шляхи до розділів і їхніх ресурсів.
    links: [
      {
        href: `${baseURL}manifest.json`,
        rel: "self",
        type: "application/webpub+json",
      },
    ],
    readingOrder: readingOrderLinks,
    resources,
  };
  if (toc.length > 0) json.toc = tocToLinks(toc);

  return { json, readingOrder };
}
