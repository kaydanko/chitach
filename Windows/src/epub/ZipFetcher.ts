import { Link, Resource, NumberRange, type Fetcher } from "@readium/shared";
import type { ZipEntries } from "./zip.ts";

/** Адреса з маніфесту → шлях усередині архіву. */
function zipPath(href: string): string {
  const withoutFragment = href.split(/[?#]/)[0];
  const trimmed = withoutFragment.startsWith("/")
    ? withoutFragment.slice(1)
    : withoutFragment;
  try {
    return decodeURIComponent(trimmed);
  } catch {
    return trimmed;
  }
}

class ZipResource extends Resource {
  constructor(
    private readonly entries: ZipEntries,
    private readonly _link: Link,
  ) {
    super();
  }

  async link(): Promise<Link> {
    return this._link;
  }

  async length(): Promise<number | undefined> {
    return this.entries.get(zipPath(this._link.href))?.length;
  }

  async read(range?: NumberRange): Promise<Uint8Array | undefined> {
    const bytes = this.entries.get(zipPath(this._link.href));
    if (!bytes) return undefined;
    if (!range) return bytes;
    return bytes.slice(range.start, range.endInclusive + 1);
  }

  close(): void {
    // Архів тримається в пам'яті цілком, закривати нічого.
  }
}

/**
 * Доступ до вмісту книги прямо з розпакованого архіву.
 *
 * Навігатор бере цим фетчером сам документ розділу, а підресурси всередині
 * нього — картинки, стилі, шрифти — тягне вже за адресою з `<base>`, тобто
 * через той шар, що віддає байти по HTTP.
 */
export class ZipFetcher implements Fetcher {
  constructor(private readonly entries: ZipEntries) {}

  links(): Link[] {
    return Array.from(this.entries.keys()).map((href) => new Link({ href }));
  }

  get(link: Link): Resource {
    return new ZipResource(this.entries, link);
  }

  close(): void {
    this.entries.clear();
  }
}
