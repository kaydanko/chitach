import {
  appearance,
  clampFontSize,
  clampSideMargin,
  clampSpreadGap,
  resetAppearance,
  saveAppearance,
  THEMES,
} from "./appearance.ts";

/**
 * Хром читалки: шапка, підвал, смуги гортання й панелі.
 *
 * Розкладка живе в `index.html`, тут лише поведінка. Порядок кнопок і
 * їхній сенс ті самі, що у Swift-версії: закрити книгу, бібліотека,
 * відкрити файл, зміст — ліворуч, оформлення — праворуч.
 */

export interface Handlers {
  closeBook: () => void;
  openLibrary: () => void;
  openFile: () => void;
  openContents: () => void;
  turn: (forward: boolean) => void;
  goToStart: () => void;
  goToEnd: () => void;
  goToFraction: (fraction: number) => void;
  /** `fast` — для змін, яким досить нових налаштувань без перебудови. */
  appearanceChanged: (fast: boolean) => void;
}

const byId = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

let handlers: Handlers;

export function setupChrome(h: Handlers): void {
  handlers = h;

  byId("tool-close").onclick = () => h.closeBook();
  byId("tool-library").onclick = () => h.openLibrary();
  byId("tool-open").onclick = () => h.openFile();
  byId("tool-contents").onclick = () => h.openContents();
  byId("tool-appearance").onclick = () => showPanel("appearance");

  byId("turn-back").onclick = () => h.turn(false);
  byId("turn-forward").onclick = () => h.turn(true);
  byId("jump-start").onclick = () => h.goToStart();
  byId("jump-end").onclick = () => h.goToEnd();

  const progress = byId<HTMLInputElement>("progress");
  progress.oninput = () => h.goToFraction(Number(progress.value) / 1000);

  byId("appearance-done").onclick = () => hidePanels();
  byId("contents-done").onclick = () => hidePanels();
  byId("library-done").onclick = () => hidePanels();
  byId("library-add").onclick = () => {
    hidePanels();
    h.openFile();
  };

  // Клацання повз аркуш закриває панель — так само, як відпускає аркуш
  // на macOS.
  for (const panel of document.querySelectorAll<HTMLElement>(".panel")) {
    panel.onclick = (event) => {
      if (event.target === panel) hidePanels();
    };
  }

  buildAppearancePanel();
  applyChromeColors();
  setChromeVisible(false);
}

/** Шапка й підвал є лише тоді, коли відкрита книга. */
export function setChromeVisible(visible: boolean): void {
  byId("toolbar").classList.toggle("visible", visible);
  byId("footer").classList.toggle("visible", visible);
  byId("turn-back").style.display = visible ? "" : "none";
  byId("turn-forward").style.display = visible ? "" : "none";
}

// MARK: — Панелі

type PanelName = "appearance" | "contents" | "library";

export function showPanel(name: PanelName): void {
  hidePanels();
  byId(`panel-${name}`).classList.add("visible");
  if (name === "appearance") refreshAppearancePanel();
}

export function hidePanels(): void {
  for (const panel of document.querySelectorAll<HTMLElement>(".panel")) {
    panel.classList.remove("visible");
  }
}

export function panelOpen(): boolean {
  return document.querySelector(".panel.visible") !== null;
}

// MARK: — Поступ

export function setProgress(fraction: number, label: string): void {
  byId<HTMLInputElement>("progress").value = String(Math.round(fraction * 1000));
  byId("position").textContent = label;
}

// MARK: — Зміст

export interface ContentsEntry {
  href: string;
  title: string;
  depth: number;
}

export function fillContents(
  entries: ContentsEntry[],
  currentHref: string | undefined,
  onPick: (href: string) => void,
): void {
  const list = byId("contents-list");
  list.replaceChildren();

  if (entries.length === 0) {
    const empty = document.createElement("p");
    empty.textContent = "У цій книзі змісту немає.";
    empty.style.opacity = "0.5";
    list.append(empty);
    return;
  }

  for (const entry of entries) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = entry.title || entry.href;
    // Відступ за рівнем вкладеності — як у дереві змісту на macOS.
    button.style.paddingLeft = `${10 + entry.depth * 16}px`;
    if (currentHref && entry.href.split("#")[0] === currentHref.split("#")[0]) {
      button.classList.add("current");
    }
    button.onclick = () => onPick(entry.href);
    list.append(button);
  }
}

// MARK: — Бібліотека

export interface LibraryEntry {
  id: string;
  title: string;
  author?: string;
  progress?: number;
}

export function fillLibrary(
  books: LibraryEntry[],
  currentId: string | undefined,
  onPick: (id: string) => void,
): void {
  const list = byId("library-list");
  list.replaceChildren();

  if (books.length === 0) {
    const empty = document.createElement("p");
    empty.textContent = "Поки порожньо. Додайте книгу — вона лишиться тут.";
    empty.style.opacity = "0.5";
    list.append(empty);
    return;
  }

  for (const book of books) {
    const button = document.createElement("button");
    button.type = "button";
    if (book.id === currentId) button.classList.add("current");

    const title = document.createElement("span");
    title.textContent = book.title;
    button.append(title);

    const parts: string[] = [];
    if (book.author) parts.push(book.author);
    if (typeof book.progress === "number" && book.progress > 0) {
      parts.push(`прочитано ${Math.round(book.progress * 100)}%`);
    }
    if (parts.length > 0) {
      const meta = document.createElement("span");
      meta.className = "meta";
      meta.textContent = parts.join(" · ");
      button.append(meta);
    }

    button.onclick = () => onPick(book.id);
    list.append(button);
  }
}

// MARK: — Панель оформлення

interface Stepper {
  value: () => number;
  set: (value: number) => void;
  format: (value: number) => string;
  step: number;
  min: number;
  max: number;
  /** Чи досить навігатору нових налаштувань без перебудови. */
  fast: boolean;
}

const STEPPERS: Record<string, Stepper> = {
  "step-font": {
    value: () => appearance.fontSize,
    set: (v) => (appearance.fontSize = clampFontSize(v)),
    format: (v) => `${Math.round(v * 100)}%`,
    step: appearance.fontSizeStep,
    min: appearance.minimumFontSize,
    max: appearance.maximumFontSize,
    fast: true,
  },
  "step-left": {
    value: () => appearance.leftMargin,
    set: (v) => (appearance.leftMargin = clampSideMargin(v)),
    format: (v) => `${v} px`,
    step: appearance.sideMarginStep,
    min: appearance.minimumSideMargin,
    max: appearance.maximumSideMargin,
    fast: false,
  },
  "step-right": {
    value: () => appearance.rightMargin,
    set: (v) => (appearance.rightMargin = clampSideMargin(v)),
    format: (v) => `${v} px`,
    step: appearance.sideMarginStep,
    min: appearance.minimumSideMargin,
    max: appearance.maximumSideMargin,
    fast: false,
  },
  "step-gap": {
    value: () => appearance.spreadGap,
    set: (v) => (appearance.spreadGap = clampSpreadGap(v)),
    format: (v) => `${v} px`,
    step: appearance.sideMarginStep,
    min: appearance.minimumSpreadGap,
    max: appearance.maximumSpreadGap,
    fast: false,
  },
};

function buildAppearancePanel(): void {
  const themes = byId("themes");
  themes.replaceChildren();
  for (const theme of THEMES) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "theme";
    button.dataset.theme = theme.id;
    button.textContent = theme.name;
    button.style.background = theme.paper;
    button.style.color = theme.ink;
    button.onclick = () => {
      appearance.paperColor = theme.paper;
      appearance.inkColor = theme.ink;
      commit(false);
    };
    themes.append(button);
  }

  for (const [id, stepper] of Object.entries(STEPPERS)) {
    const host = byId(id);
    host.replaceChildren();

    const minus = document.createElement("button");
    minus.type = "button";
    minus.textContent = "−";
    const value = document.createElement("span");
    value.className = "value";
    const plus = document.createElement("button");
    plus.type = "button";
    plus.textContent = "+";

    minus.onclick = () => {
      stepper.set(stepper.value() - stepper.step);
      commit(stepper.fast);
    };
    plus.onclick = () => {
      stepper.set(stepper.value() + stepper.step);
      commit(stepper.fast);
    };

    host.append(minus, value, plus);
  }

  byId<HTMLInputElement>("color-paper").oninput = (event) => {
    appearance.paperColor = (event.target as HTMLInputElement).value.toUpperCase();
    commit(false);
  };
  byId<HTMLInputElement>("color-ink").oninput = (event) => {
    appearance.inkColor = (event.target as HTMLInputElement).value.toUpperCase();
    commit(false);
  };

  byId("appearance-reset").onclick = () => {
    resetAppearance();
    commit(false);
  };
}

/**
 * Колір паперу живе у двох місцях: усередині документа його задає наш
 * стиль, а в смузі з краю — підкладка під вебвʼю. Без цього рядка тема
 * міняла б лише половину екрана.
 */
export function applyChromeColors(): void {
  const root = document.documentElement.style;
  root.setProperty("--paper", appearance.paperColor);
  root.setProperty("--ink", appearance.inkColor);
}

/** Зберегти, оновити панель і сказати читалці перемалюватися. */
function commit(fast: boolean): void {
  saveAppearance();
  applyChromeColors();
  refreshAppearancePanel();
  handlers.appearanceChanged(fast);
}

export function refreshAppearancePanel(): void {
  byId<HTMLInputElement>("color-paper").value = appearance.paperColor;
  byId<HTMLInputElement>("color-ink").value = appearance.inkColor;

  for (const [id, stepper] of Object.entries(STEPPERS)) {
    const host = byId(id);
    const [minus, value, plus] = Array.from(host.children) as [
      HTMLButtonElement,
      HTMLElement,
      HTMLButtonElement,
    ];
    const current = stepper.value();
    value.textContent = stepper.format(current);
    minus.disabled = current <= stepper.min;
    plus.disabled = current >= stepper.max;
  }

  for (const chip of document.querySelectorAll<HTMLElement>(".theme")) {
    const theme = THEMES.find((t) => t.id === chip.dataset.theme);
    chip.classList.toggle(
      "current",
      theme?.paper === appearance.paperColor && theme.ink === appearance.inkColor,
    );
  }

  const preview = byId("preview");
  preview.style.background = appearance.paperColor;
  preview.style.color = appearance.inkColor;
  preview.style.fontSize = `${13 * appearance.fontSize}px`;
  preview.style.paddingLeft = `${clampSideMargin(appearance.leftMargin) / 3}px`;
  preview.style.paddingRight = `${clampSideMargin(appearance.rightMargin) / 3}px`;
}

// MARK: — Початковий екран і помилки

export function setStartVisible(visible: boolean): void {
  byId("start").classList.toggle("visible", visible);
}

export function showError(message: string): void {
  const box = byId("error");
  box.textContent = message;
  box.classList.add("visible");
}

export function hideError(): void {
  byId("error").classList.remove("visible");
}
