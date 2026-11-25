import { Locator } from "@readium/shared";

/**
 * Пам'ять про місце читання в кожній книзі.
 *
 * Саму книгу памʼятає Rust: шлях до файлу не має ходити через вебвʼю,
 * якому книга підсовує свої скрипти. Тут лишається тільки локатор —
 * він нешкідливий, бо адресує місце всередині вже відкритої книги.
 */

const LOCATOR = "chytach.locator:";

function storage(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    // Приватне вікно або заборонені дані сайту — читалка має працювати й так.
    return null;
  }
}

export function forgetBook(path: string): void {
  try {
    storage()?.removeItem(LOCATOR + path);
  } catch {
    // Те саме: мовчазна невдача краще за зламаний запуск.
  }
}

export function savedLocator(path: string): Locator | undefined {
  try {
    const stored = storage()?.getItem(LOCATOR + path);
    if (!stored) return undefined;
    return Locator.deserialize(JSON.parse(stored));
  } catch {
    return undefined;
  }
}

export function saveLocator(path: string, locator: Locator): void {
  try {
    storage()?.setItem(LOCATOR + path, JSON.stringify(locator.serialize()));
  } catch {
    // Те саме.
  }
}
