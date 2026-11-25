/**
 * Мова інтерфейсу.
 *
 * Та сама пара, що на macOS та Android: українська або англійська, вибір
 * діє одразу й не залежить від мови системи.
 *
 * Переклад живе тут, а не в розмітці: елементи позначені `data-i18n`, і
 * одна функція проходить по них усіх. Так новий рядок не можна забути
 * перекласти — він просто не зʼявиться в переліку.
 */

export type Language = "uk" | "en";

const UK: Record<string, string> = {
  "app.tagline": "Читалка електронних книг",
  "start.open": "Відкрити книгу",
  "start.sample": "Показати зразок",
  "start.languageUk": "Українська",
  "start.languageEn": "English",

  "tool.close": "Закрити книгу",
  "tool.library": "Бібліотека",
  "tool.open": "Відкрити файл",
  "tool.contents": "Зміст",
  "tool.support": "Підтримати проєкт",
  "tool.appearance": "Оформлення",
  "tool.back": "Назад",
  "tool.forward": "Далі",
  "tool.jumpStart": "На початок книги",
  "tool.jumpEnd": "У кінець книги",

  "appearance.title": "Оформлення",
  "appearance.sample": "Зразок",
  "appearance.sampleText":
    "Аркуш паперу, на якому видно, що саме ви міняєте: колір тла, колір тексту й розмір кегля.",
  "appearance.themes": "Готові теми",
  "appearance.ownColors": "Власні кольори",
  "appearance.paper": "Тло сторінки",
  "appearance.ink": "Колір тексту",
  "appearance.textSize": "Розмір тексту",
  "appearance.fontSize": "Кегль",
  "appearance.margins": "Поля сторінки",
  "appearance.left": "Ліве поле",
  "appearance.right": "Праве поле",
  "appearance.gap": "Проміжок між колонками",
  "appearance.reset": "Повернути початкові",

  "theme.sand": "Пісочна",
  "theme.cream": "Кремова",
  "theme.sepia": "Сепія",
  "theme.grey": "Сіра",
  "theme.night": "Нічна",
  "theme.black": "Чорна",

  "contents.title": "Зміст",
  "contents.empty": "У цій книзі змісту немає.",
  "library.title": "Бібліотека",
  "library.empty": "Поки порожньо. Додайте книгу — вона лишиться тут.",
  "library.add": "Додати книгу",
  "library.read": "прочитано {0}%",

  "donate.title": "Подобається читати тут?",
  "donate.body":
    "Chytach робить одна людина у вільний час. Без реклами, без підписок і " +
    "без збору даних. Якщо застосунок став вам у пригоді, можна пригостити " +
    "розробника кавою. Внески йдуть на час для нових функцій.",
  "donate.voluntary":
    "Це повністю добровільно. Читалка лишиться такою ж і без внеску.",
  "donate.jar": "Банка monobank",
  "donate.customAmount": "Інша сума, ₴",
  "donate.go": "Задонатити через monobank",
  "donate.jarNote":
    "Відкриється банка monobank — у застосунку банку або в браузері. " +
    "Платити можна карткою будь-якого банку; сума в гривнях.",
  "donate.card": "Або переказ на картку",
  "donate.cardNumber": "Номер картки",
  "donate.copy": "Скопіювати",
  "donate.copied": "Скопійовано!",
  "donate.currencyNote":
    "Картка гривнева (UAH). Якщо ви платите карткою в іншій валюті, ваш " +
    "банк сконвертує суму за своїм курсом і може взяти комісію — варто " +
    "глянути, скільки спишеться.",
  "donate.notNow": "Не зараз",
  "donate.backToReading": "Повернутися до читання",

  "common.done": "Готово",
  "error.openFailed": "Не вдалося відкрити книгу",
};

const EN: Record<string, string> = {
  "app.tagline": "An e-book reader",
  "start.open": "Open a book",
  "start.sample": "Show the sample",
  "start.languageUk": "Українська",
  "start.languageEn": "English",

  "tool.close": "Close the book",
  "tool.library": "Library",
  "tool.open": "Open a file",
  "tool.contents": "Contents",
  "tool.support": "Support the project",
  "tool.appearance": "Appearance",
  "tool.back": "Back",
  "tool.forward": "Forward",
  "tool.jumpStart": "Go to the beginning",
  "tool.jumpEnd": "Go to the end",

  "appearance.title": "Appearance",
  "appearance.sample": "Sample",
  "appearance.sampleText":
    "A sheet of paper showing exactly what you are changing: background colour, text colour and size.",
  "appearance.themes": "Themes",
  "appearance.ownColors": "Custom colours",
  "appearance.paper": "Page background",
  "appearance.ink": "Text colour",
  "appearance.textSize": "Text size",
  "appearance.fontSize": "Size",
  "appearance.margins": "Page margins",
  "appearance.left": "Left margin",
  "appearance.right": "Right margin",
  "appearance.gap": "Gap between columns",
  "appearance.reset": "Restore defaults",

  "theme.sand": "Sand",
  "theme.cream": "Cream",
  "theme.sepia": "Sepia",
  "theme.grey": "Grey",
  "theme.night": "Night",
  "theme.black": "Black",

  "contents.title": "Contents",
  "contents.empty": "This book has no table of contents.",
  "library.title": "Library",
  "library.empty": "Empty so far. Add a book and it stays here.",
  "library.add": "Add a book",
  "library.read": "{0}% read",

  "donate.title": "Enjoying reading here?",
  "donate.body":
    "Chytach is made by one person in their spare time. No ads, no " +
    "subscriptions, no data collection. If the app has been useful, you can " +
    "buy the developer a coffee. Contributions go towards time for new features.",
  "donate.voluntary":
    "This is entirely voluntary. The reader stays the same without it.",
  "donate.jar": "monobank jar",
  "donate.customAmount": "Another amount, ₴",
  "donate.go": "Donate via monobank",
  "donate.jarNote":
    "The monobank jar opens, in the bank app or in a browser. Any bank's " +
    "card works; the amount is in hryvnia.",
  "donate.card": "Or a card transfer",
  "donate.cardNumber": "Card number",
  "donate.copy": "Copy",
  "donate.copied": "Copied!",
  "donate.currencyNote":
    "The card is in hryvnia (UAH). If you pay with a card in another " +
    "currency, your bank converts at its own rate and may charge a fee — " +
    "worth checking what gets debited.",
  "donate.notNow": "Not now",
  "donate.backToReading": "Back to reading",

  "common.done": "Done",
  "error.openFailed": "Could not open the book",
};

const STORED = "chytach.language";

let current: Language = "uk";

/** Переклад за ключем; `{0}` заміняється першим аргументом. */
export function t(key: string, ...values: Array<string | number>): string {
  const table = current === "en" ? EN : UK;
  let text = table[key] ?? UK[key] ?? key;
  values.forEach((value, index) => {
    text = text.replace(`{${index}}`, String(value));
  });
  return text;
}

export function language(): Language {
  return current;
}

/** Мова системи, якщо вона англійська; інакше українська. */
function detect(): Language {
  try {
    const stored = window.localStorage.getItem(STORED);
    if (stored === "uk" || stored === "en") return stored;
  } catch {
    // Сховище може бути недоступне — тоді дивимося на мову системи.
  }
  return window.navigator.language.startsWith("uk") ? "uk" : "en";
}

export function loadLanguage(): void {
  current = detect();
}

export function setLanguage(value: Language): void {
  current = value;
  try {
    window.localStorage.setItem(STORED, value);
  } catch {
    // Вибір не переживе перезапуск, але зараз подіє.
  }
  applyLanguage();
}

/**
 * Проставляє переклад усім позначеним елементам.
 *
 * `data-i18n` — текст, `data-i18n-title` — підказка, `data-i18n-placeholder`
 * — підказка в полі.
 */
export function applyLanguage(): void {
  document.documentElement.lang = current;

  for (const element of document.querySelectorAll<HTMLElement>("[data-i18n]")) {
    element.textContent = t(element.dataset.i18n ?? "");
  }
  for (const element of document.querySelectorAll<HTMLElement>("[data-i18n-title]")) {
    element.title = t(element.dataset.i18nTitle ?? "");
  }
  for (const element of document.querySelectorAll<HTMLInputElement>(
    "[data-i18n-placeholder]",
  )) {
    element.placeholder = t(element.dataset.i18nPlaceholder ?? "");
  }
}
