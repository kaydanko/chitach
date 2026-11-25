import { Locator, Manifest, Publication } from "@readium/shared";
import { EpubNavigator, TextAlignment } from "@readium/navigator";
import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { readZip } from "./epub/zip.ts";
import { buildManifest } from "./epub/manifest.ts";
import { ZipFetcher } from "./epub/ZipFetcher.ts";
import { forgetBook, saveLocator, savedLocator } from "./library.ts";
import {
  appearance,
  clampFontSize,
  loadAppearance,
  pageCSS,
  saveAppearance,
  shouldUseTwoColumns,
  textInsets,
} from "./appearance.ts";
import * as ui from "./ui.ts";

const reader = document.getElementById("reader") as HTMLElement;

/** Чи працюємо всередині оболонки Tauri, чи просто у браузері. */
const inTauri = "__TAURI_INTERNALS__" in window;

/**
 * Умовний ключ вкладеного зразка.
 *
 * Справжній шлях до нього залежить від того, куди встановлено застосунок,
 * а памʼять про місце читання має пережити оновлення.
 */
const SAMPLE = "__sample__";

/** Відкрита книга з усім, що потрібно, щоб перемалювати її без читання з диска. */
interface OpenBook {
  /**
   * Стійкий ідентифікатор від Rust, а не шлях до файлу.
   *
   * Вебвʼю не знає, де книга лежить: розділи малюються в iframe зі
   * скриптами, тож шлях у ньому означав би, що книга вичитує будову
   * диска. Для памʼяті про місце читання ідентифікатора досить.
   */
  id: string;
  publication: Publication;
  baseURL: string;
  positions: Locator[];
}

let book: OpenBook | null = null;
let navigator_: EpubNavigator | null = null;
let twoColumns = false;
let grainDataURI: string | undefined;

// MARK: — Зерно

/**
 * Зерно як data-URI, а не як посилання на файл.
 *
 * Стиль потрапляє в документ окремим blob, і відносні адреси в ньому
 * розв'язувалися б від самого blob, а не від книги. Абсолютна адреса
 * залежала б від того, звідки запущено застосунок, — у збірці Tauri це вже
 * інша схема. Data-URI не залежить ні від чого.
 */
async function loadGrain(): Promise<void> {
  if (grainDataURI !== undefined) return;
  try {
    const response = await fetch("./grain.png");
    const blob = await response.blob();
    grainDataURI = await new Promise<string>((resolve, reject) => {
      const file = new FileReader();
      file.onload = () => resolve(file.result as string);
      file.onerror = () => reject(file.error);
      file.readAsDataURL(blob);
    });
  } catch {
    grainDataURI = undefined;
  }
}

/**
 * Походження адреси у вигляді, придатному для CSP.
 *
 * `URL.origin` для власних схем повертає рядок `"null"`: за стандартом у
 * них непрозоре походження. На macOS книга віддається схемою `epub:`, і в
 * політику кадру потрапляв би цей `"null"`, а на Windows — звичайне
 * `http://epub.localhost`. Різниця тиха: WebKit дивиться на таке крізь
 * пальці, Chromium у WebView2 — ні, і книга лишилася б без своїх стилів
 * саме на Windows.
 */
function cspSource(url: string): string {
  const parsed = new URL(url);
  // Для власних схем лишається сама схема: вузла в непрозорому
  // походженні немає, і CSP приймає тут рівно форму `epub:`.
  return parsed.origin !== "null" ? parsed.origin : parsed.protocol;
}

// MARK: — Джерело книги

/**
 * Байти книги та адреса, від якої розв'язуються посилання всередині
 * розділів.
 *
 * У збірці архів тримає Rust і віддає його схемою `epub`; у розробці те
 * саме робить middleware Vite.
 */
async function bookBytes(): Promise<{ bytes: Uint8Array; baseURL: string }> {
  if (inTauri) {
    const baseURL = convertFileSrc("", "epub");
    const response = await fetch(`${baseURL}__raw__`);
    if (!response.ok) throw new Error(`__raw__: ${response.status}`);
    return { bytes: new Uint8Array(await response.arrayBuffer()), baseURL };
  }

  const response = await fetch("./sample.epub");
  if (!response.ok) throw new Error(`sample.epub: ${response.status}`);
  return {
    bytes: new Uint8Array(await response.arrayBuffer()),
    baseURL: new URL("/epub/", location.href).href,
  };
}

// MARK: — Відкриття

/** Розбирає книгу, яку Rust уже тримає розпакованою, і малює її. */
async function render(id: string): Promise<void> {
  ui.hideError();

  const { bytes, baseURL } = await bookBytes();
  const entries = readZip(bytes);
  const { json } = buildManifest(entries, baseURL);

  const manifest = Manifest.deserialize(json);
  if (!manifest) throw new Error("Маніфест книги не зібрався");

  const publication = new Publication({
    manifest,
    fetcher: new ZipFetcher(entries),
  });

  // Перелік позицій навігатор бере з маніфесту, а там його немає: у Swift
  // і Kotlin цей список будує Streamer. Робимо найгрубший варіант — по
  // позиції на розділ.
  const items = publication.readingOrder.items;
  const positions = items
    .map((link, index) =>
      Locator.deserialize({
        href: link.href,
        type: link.type,
        locations: {
          position: index + 1,
          progression: 0,
          totalProgression: items.length > 0 ? index / items.length : 0,
        },
      }),
    )
    .filter((locator): locator is Locator => locator !== undefined);

  book = { id, publication, baseURL, positions };

  await loadGrain();
  await mount(savedLocator(id) ?? positions[0]);

  ui.setStartVisible(false);
  ui.setChromeVisible(true);
  reportMetadata();
}

/** Створює навігатор на поточному оформленні й веде його на `at`. */
async function mount(at: Locator | undefined): Promise<void> {
  if (!book) return;

  twoColumns = shouldUseTwoColumns(reader.clientWidth || window.innerWidth);
  layoutReader();

  await navigator_?.destroy();
  navigator_ = null;
  reader.replaceChildren();

  const stylesheet = new Blob([pageCSS(twoColumns, grainDataURI)], {
    type: "text/css",
  });

  navigator_ = new EpubNavigator(
    reader,
    book.publication,
    {
      frameLoaded: () => {},
      positionChanged: (locator) => {
        if (!book) return;
        saveLocator(book.id, locator);
        updateProgress(locator);
      },
      viewportChanged: () => {},
      timelineItemChanged: () => {},
      tap: () => false,
      click: () => false,
      zoom: () => {},
      miscPointer: () => {},
      scroll: () => {},
      customEvent: () => {},
      handleLocator: () => false,
      textSelected: () => {},
      contentProtection: () => {},
      contextMenu: () => {},
      peripheral: () => {},
    },
    book.positions,
    at ?? book.positions[0],
    {
      preferences: preferences(),
      defaults: {},
      injectables: {
        // Стиль іде в кінець `head` кожного розділу — так само, як user
        // script на iOS і вставка через JS на Android.
        rules: [
          {
            resources: [/.*/],
            append: [{ as: "link", rel: "stylesheet", blob: stylesheet }],
          },
        ],
        // Кадр отримує сувору CSP, у якій дозволені лише перелічені
        // походження. Без адреси книги не завантажились би ні її стилі,
        // ні картинки: вони приходять з іншого походження, ніж сторінка.
        allowedDomains: [cspSource(location.href), cspSource(book.baseURL)],
      },
    },
  );

  await navigator_.load();
}

function preferences() {
  return {
    columnCount: twoColumns ? 2 : 1,
    fontSize: appearance.fontSize,
    hyphens: true,
    // Справжні поля задає стиль; це запасне значення на випадок, якщо він
    // колись не доїде.
    pageGutter: appearance.defaultSideMargin,
    paragraphIndent: 1.0,
    scroll: false,
    textAlign: TextAlignment.justify,
    textColor: appearance.inkColor,
    // Знімаємо стелю довжини рядка, інакше колонки не заповнюють ширину.
    maximalLineLength: appearance.maximumLineLength,
  };
}

/**
 * Звуження області читання під бічні поля.
 *
 * Усередині документа проміжок між колонками дорівнює сумі бічних полів —
 * властивість сітки колонок, яку не обійти. Тому проміжок лишається
 * документу, а бічні поля доміряються звуженням самої області читання: з
 * краю лишається смуга, де видно папір із зерном.
 */
function layoutReader(): void {
  const view = textInsets(twoColumns).view;
  reader.style.left = `${view.left}px`;
  reader.style.right = `${view.right}px`;
}

// MARK: — Поступ і зміст

/**
 * Поступ по книзі з точністю до сторінки, а не до розділу.
 *
 * `totalProgression` рахується з переліку позицій, а той у нас грубий —
 * по позиції на розділ. У книзі з трьох файлів повзунок мав би три
 * положення, а кінець книги показував би 67%. Тому рахуємо самі: номер
 * розділу плюс те, скільки пройдено всередині нього.
 */
function fractionOf(locator: Locator): number {
  if (!book) return 0;
  const items = book.publication.readingOrder.items;
  if (items.length === 0) return 0;

  const resource = locator.href.split("#")[0];
  const index = items.findIndex((item) => item.href.split("#")[0] === resource);
  if (index < 0) return 0;

  const inside = locator.locations.progression ?? 0;
  return Math.min(1, (index + inside) / items.length);
}

function updateProgress(locator: Locator): void {
  const fraction = fractionOf(locator);
  ui.setProgress(fraction, `${Math.round(fraction * 100)}%`);
}

function contentsEntries(): ui.ContentsEntry[] {
  const entries: ui.ContentsEntry[] = [];
  const walk = (links: readonly unknown[], depth: number): void => {
    for (const raw of links) {
      const link = raw as {
        href: string;
        title?: string;
        children?: { items?: readonly unknown[] };
      };
      entries.push({ href: link.href, title: link.title ?? "", depth });
      const children = link.children?.items;
      if (children && children.length > 0) walk(children, depth + 1);
    }
  };
  walk(book?.publication.toc?.items ?? [], 0);
  return entries;
}

function reportMetadata(): void {
  if (!inTauri || !book) return;
  const metadata = book.publication.metadata;
  const locator = navigator_?.currentLocator;

  // Назва й імена авторів у тулкіті — локалізовані рядки, а не рядки:
  // `String()` з них робить «[object Object]».
  const authors = metadata.authors?.items ?? [];

  invoke("record_metadata", {
    title: metadata.title?.getTranslation() ?? "",
    author: authors
      .map((person) => person.name?.getTranslation() ?? "")
      .filter((name) => name.length > 0)
      .join(", "),
    progress: locator ? fractionOf(locator) : 0,
  }).catch(() => {
    // Запис у бібліотеку не вартий того, щоб через нього падала книга.
  });
}

// MARK: — Дії

function turn(forward: boolean): void {
  if (!navigator_) return;
  if (forward) navigator_.goForward(true, () => {});
  else navigator_.goBackward(true, () => {});
}

function goTo(locator: Locator | undefined): void {
  if (!navigator_ || !locator) return;
  navigator_.go(locator, true, () => {});
}

function goToFraction(fraction: number): void {
  if (!book) return;
  const items = book.publication.readingOrder.items;
  if (items.length === 0) return;

  const exact = Math.min(0.9999, Math.max(0, fraction)) * items.length;
  const index = Math.floor(exact);
  const inside = exact - index;

  goTo(
    Locator.deserialize({
      href: items[index].href,
      type: items[index].type,
      locations: { progression: inside },
    }),
  );
}

function closeBook(): void {
  book = null;
  navigator_?.destroy();
  navigator_ = null;
  reader.replaceChildren();
  ui.setChromeVisible(false);
  ui.setStartVisible(true);
}

async function openFile(): Promise<void> {
  if (!inTauri) return;
  try {
    const id = await invoke<string | null>("pick_book");
    if (id !== null) await render(id);
  } catch (error) {
    fail(error);
  }
}

async function openSample(): Promise<void> {
  if (inTauri) await invoke("open_sample");
  await render(SAMPLE);
}

async function openLibrary(): Promise<void> {
  if (!inTauri) {
    ui.fillLibrary([], undefined, () => {});
    ui.showPanel("library");
    return;
  }

  const books = await invoke<
    Array<{ id: string; title: string; author: string; progress: number }>
  >("list_books");

  ui.fillLibrary(
    books.map((b) => ({
      id: b.id,
      title: b.title,
      author: b.author || undefined,
      progress: b.progress,
    })),
    book?.id,
    (id) => {
      const index = books.findIndex((b) => b.id === id);
      if (index < 0) return;
      ui.hidePanels();
      invoke<string | null>("open_library_book", { index })
        .then((opened) => (opened === null ? undefined : render(opened)))
        .catch(fail);
    },
  );
  ui.showPanel("library");
}

/**
 * Книга, яку не вдалося відкрити, більше не вважається останньою: інакше
 * застосунок відкривався б тією самою помилкою щоразу.
 */
function fail(error: unknown, id?: string): void {
  if (id) forgetBook(id);
  ui.setChromeVisible(false);
  ui.setStartVisible(true);
  ui.showError(
    "Не вдалося відкрити книгу\n\n" +
      (error instanceof Error ? error.message : String(error)),
  );
}

// MARK: — Хром

ui.setupChrome({
  closeBook,
  openLibrary: () => void openLibrary().catch(fail),
  openFile: () => void openFile(),
  openContents: () => {
    ui.fillContents(contentsEntries(), navigator_?.currentLocator.href, (href) => {
      ui.hidePanels();
      // Якір Readium чекає не в адресі, а окремо: у локаторі з самим
      // `href` із решіткою перехід мовчки лишається на початку розділу.
      const [resource, fragment] = href.split("#");
      goTo(
        Locator.deserialize({
          href: resource,
          type: "application/xhtml+xml",
          locations: {
            progression: 0,
            fragments: fragment ? [fragment] : [],
          },
        }),
      );
    });
    ui.showPanel("contents");
  },
  turn,
  goToStart: () => goToFraction(0),
  goToEnd: () => goToFraction(1),
  goToFraction,
  appearanceChanged: (fast) => {
    layoutReader();
    if (fast) {
      navigator_?.submitPreferences(preferences() as never).catch(() => {});
      return;
    }
    // Колір, зерно й поля живуть у вставленому стилі, а він потрапляє в
    // кадр під час створення. Тому перемальовуємо навігатор на місці, де
    // людина стоїть.
    const at = navigator_?.currentLocator;
    void mount(at).catch(fail);
  },
});

// MARK: — Клавіші

window.addEventListener("keydown", (event) => {
  const command = event.metaKey || event.ctrlKey;

  if (event.key === "Escape") {
    ui.hidePanels();
    return;
  }
  if (ui.panelOpen()) return;

  if (command && (event.key === "=" || event.key === "+")) {
    event.preventDefault();
    appearance.fontSize = clampFontSize(appearance.fontSize + appearance.fontSizeStep);
    saveAppearance();
    navigator_?.submitPreferences(preferences() as never).catch(() => {});
  } else if (command && event.key === "-") {
    event.preventDefault();
    appearance.fontSize = clampFontSize(appearance.fontSize - appearance.fontSizeStep);
    saveAppearance();
    navigator_?.submitPreferences(preferences() as never).catch(() => {});
  } else if (command && event.key === "ArrowUp") {
    event.preventDefault();
    goToFraction(0);
  } else if (command && event.key === "ArrowDown") {
    event.preventDefault();
    goToFraction(1);
  } else if (command && event.key.toLowerCase() === "o") {
    event.preventDefault();
    void openFile();
  } else if (event.key === "ArrowRight" || event.key === "PageDown" || event.key === " ") {
    turn(true);
  } else if (event.key === "ArrowLeft" || event.key === "PageUp") {
    turn(false);
  }
});

/** Кегль коліщатком із затиснутим Ctrl або Cmd — як на macOS. */
window.addEventListener(
  "wheel",
  (event) => {
    if (!(event.metaKey || event.ctrlKey) || !navigator_) return;
    event.preventDefault();
    const step = event.deltaY < 0 ? appearance.fontSizeStep : -appearance.fontSizeStep;
    appearance.fontSize = clampFontSize(appearance.fontSize + step);
    saveAppearance();
    navigator_?.submitPreferences(preferences() as never).catch(() => {});
  },
  { passive: false },
);

/** Поворот чи зміна розміру вікна може змінити кількість колонок. */
window.addEventListener("resize", () => {
  if (!book) return;
  const wide = shouldUseTwoColumns(reader.clientWidth || window.innerWidth);
  if (wide === twoColumns) {
    layoutReader();
    return;
  }
  void mount(navigator_?.currentLocator).catch(fail);
});

// MARK: — Запуск

document.getElementById("open-book")?.addEventListener("click", () => void openFile());
document
  .getElementById("open-sample")
  ?.addEventListener("click", () => void openSample().catch(fail));

/**
 * Книга, відкрита з Провідника, поки застосунок уже працює.
 *
 * На Windows подвійне клацання запускає новий процес; плагін єдиного
 * примірника перехоплює його, відкриває книгу на боці Rust і лише
 * сповіщає вікно, що показувати тепер іншу.
 */
if (inTauri) {
  listen<string>("book-opened", (event) => {
    render(event.payload).catch((error) => fail(error, event.payload));
  });
}

async function start(): Promise<void> {
  loadAppearance();
  ui.applyChromeColors();

  if (!inTauri) {
    await render(SAMPLE);
    return;
  }

  // Подвійне клацання на книзі в Провіднику передає шлях аргументом;
  // інакше повертаємося до тієї, на якій зупинилися.
  const id =
    (await invoke<string | null>("open_startup_book")) ??
    (await invoke<string | null>("open_last_book"));

  if (id === null) {
    ui.setStartVisible(true);
    return;
  }
  await render(id);
}

start().catch((error) => fail(error));
