import { unzipSync } from "fflate";

/** Вміст EPUB: шлях усередині архіву → байти. */
export type ZipEntries = Map<string, Uint8Array>;

/**
 * Розпаковує EPUB цілком у пам'ять.
 *
 * Потоково було б ощадніше, але книга рідко більша за кілька мегабайтів, а
 * навігатор однаково звертається до розділів у довільному порядку й по
 * кілька разів — тримати архів розпакованим виходить і простіше, і швидше.
 */
export function readZip(data: Uint8Array): ZipEntries {
  const files = unzipSync(data);
  const entries: ZipEntries = new Map();
  for (const [path, bytes] of Object.entries(files)) {
    // Теки fflate теж віддає, але з порожнім вмістом.
    if (path.endsWith("/")) continue;
    entries.set(path, bytes);
  }
  return entries;
}

export function entryAsText(entries: ZipEntries, path: string): string {
  const bytes = entries.get(path);
  if (!bytes) throw new Error(`У книзі немає файлу ${path}`);
  return new TextDecoder("utf-8").decode(bytes);
}
