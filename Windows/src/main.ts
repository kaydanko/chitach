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
  pageCSS,
  shouldUseTwoColumns,
  textInsets,
} from "./appearance.ts";

const reader = document.getElementById("reader") as HTMLElement;
const startPanel = document.getElementById("start") as HTMLElement;
const errorBox = document.getElementById("error") as HTMLElement;

/** Чи працюємо всередині оболонки Tauri, чи просто у браузері. */
const inTauri = "__TAURI_INTERNALS__" in window;

let navigator_: EpubNavigator | null = null;
let twoColumns = false;
let grainDataURI: string | undefined;

/**
 * Зерно як data-URI, а не як посилання на файл.
 *
 * Стиль потрапляє в документ окремим blob, і відносні адреси в ньому
 * розв'язувалися б від самого blob, а не від книги. Абсолютна адреса
 * залежала б від того, звідки запущено застосунок, — у збірці Tauri це вже
 * інша схема. Data-URI не залежить ні від чого.
 */
async function loadGrain(): Promise<string | undefined> {
  try {
    const response = await fetch("./grain.png");
    const blob = await response.blob();
    return await new Promise<string>((resolve, reject) => {
      const file = new FileReader();
      file.onload = () => resolve(file.result as string);
      file.onerror = () => reject(file.error);
      file.readAsDataURL(blob);
    });
  } catch {
    return undefined;
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

/** Звуження області читання під бічні поля — див. `textInsets`. */
function layoutReader(): void {
  const view = textInsets(twoColumns).view;
  reader.style.left = `${view.left}px`;
  reader.style.right = `${view.right}px`;
}

function stylesheet(): Blob {
  return new Blob([pageCSS(twoColumns, grainDataURI)], { type: "text/css" });
}

function showStart(): void {
  startPanel.style.display = "flex";
}

function hideStart(): void {
  startPanel.style.display = "none";
}

function hideError(): void {
  errorBox.style.display = "none";
}

/**
 * Книга, яку не вдалося відкрити, більше не вважається останньою: інакше
 * застосунок відкривався б тією самою помилкою щоразу.
 */
function showError(error: unknown, path?: string): void {
  if (path) forgetBook(path);
  showStart();
  errorBox.style.display = "grid";
  errorBox.textContent =
    "Не вдалося відкрити книгу\n\n" +
    (error instanceof Error ? error.message : String(error));
}

/**
 * Байти книги та адреса, від якої розв'язуються посилання всередині
 * розділів.
 *
 * У збірці архів тримає Rust і віддає його схемою `epub`; у розробці те
 * саме робить middleware Vite. Для решти коду різниці немає.
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

/**
 * Умовний ключ вкладеного зразка.
 *
 * Справжній шлях до нього залежить від того, куди встановлено застосунок,
 * а памʼять про місце читання має пережити оновлення.
 */
const SAMPLE = "__sample__";

/** Відкриває зразок, вкладений у збірку. */
async function openSample(): Promise<void> {
  if (inTauri) await invoke("open_sample");
  await render(SAMPLE);
}

async function render(path: string): Promise<void> {
  hideError();

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

  twoColumns = shouldUseTwoColumns(window.innerWidth);
  layoutReader();
  grainDataURI = await loadGrain();

  await navigator_?.destroy();
  reader.replaceChildren();

  navigator_ = new EpubNavigator(
    reader,
    publication,
    {
      frameLoaded: () => {},
      positionChanged: (locator) => saveLocator(path, locator),
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
    positions,
    savedLocator(path) ?? positions[0],
    {
      preferences: {
        columnCount: twoColumns ? 2 : 1,
        fontSize: appearance.fontSize,
        hyphens: true,
        // Справжні поля задає стиль нижче; це запасне значення на випадок,
        // якщо він колись не доїде.
        pageGutter: appearance.defaultSideMargin,
        paragraphIndent: 1.0,
        scroll: false,
        textAlign: TextAlignment.justify,
        textColor: appearance.inkColor,
        // Знімаємо стелю довжини рядка, інакше колонки не заповнюють ширину.
        maximalLineLength: appearance.maximumLineLength,
      },
      defaults: {},
      injectables: {
        // Стиль іде в кінець `head` кожного розділу — так само, як user
        // script на iOS і вставка через JS на Android.
        rules: [{ resources: [/.*/], append: [
          { as: "link", rel: "stylesheet", blob: stylesheet() },
        ] }],
        // Кадр отримує сувору CSP, у якій дозволені лише перелічені
        // походження. Без адреси книги не завантажились би ні її стилі,
        // ні картинки: вони приходять з іншого походження, ніж сторінка.
        allowedDomains: [cspSource(location.href), cspSource(baseURL)],
      },
    },
  );

  await navigator_.load();
  hideStart();
}

// MARK: — Гортання

function turn(forward: boolean): void {
  if (!navigator_) return;
  if (forward) navigator_.goForward(true, () => {});
  else navigator_.goBackward(true, () => {});
}

window.addEventListener("keydown", (event) => {
  if (event.key === "ArrowRight" || event.key === "PageDown" || event.key === " ") {
    turn(true);
  } else if (event.key === "ArrowLeft" || event.key === "PageUp") {
    turn(false);
  }
});

reader.addEventListener("click", (event) => {
  turn(event.clientX > window.innerWidth / 2);
});

// MARK: — Запуск

/**
 * Вибір книги веде Rust, а не вебвʼю.
 *
 * Діалог міг би жити й тут, але тоді шлях до файлу повертався б у вебвʼю
 * й ішов назад командою — а вебвʼю показує чужий вміст: розділи книги
 * малюються в iframe зі скриптами й спільним походженням. Команда, що
 * приймає довільний шлях, дала б книзі прочитати будь-який файл.
 */
document.getElementById("open-book")?.addEventListener("click", async () => {
  try {
    const path = await invoke<string | null>("pick_book");
    if (path !== null) await render(path);
  } catch (error) {
    showError(error);
  }
});

document.getElementById("open-sample")?.addEventListener("click", () => {
  openSample().catch(showError);
});

/**
 * Книга, відкрита з Провідника, поки застосунок уже працює.
 *
 * На Windows подвійне клацання запускає новий процес; плагін єдиного
 * примірника перехоплює його, відкриває книгу на боці Rust і лише
 * сповіщає вікно, що показувати тепер іншу.
 */
if (inTauri) {
  listen<string>("book-opened", (event) => {
    render(event.payload).catch((error) => showError(error, event.payload));
  });
}

async function start(): Promise<void> {
  if (!inTauri) {
    await render(SAMPLE);
    return;
  }

  // Подвійне клацання на книзі в Провіднику передає шлях аргументом;
  // інакше повертаємося до тієї, на якій зупинилися.
  try {
    const path =
      (await invoke<string | null>("open_startup_book")) ??
      (await invoke<string | null>("open_last_book"));

    if (path === null) {
      showStart();
      return;
    }
    await render(path);
  } catch (error) {
    showError(error);
  }
}

start().catch(showError);
