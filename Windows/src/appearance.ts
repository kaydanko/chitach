/**
 * Оформлення сторінки — порт `BookAppearance` зі Swift і Kotlin версій.
 *
 * Значення ті самі, бо вони вже виміряні на пікселях: читалка на трьох
 * системах має виглядати однаково.
 */

export const DEFAULT_PAPER = "#CDC28B";
export const DEFAULT_INK = "#38331C";

/** Готові теми. Значення ті самі, що в Swift-версії. */
export const THEMES: ReadonlyArray<{
  id: string;
  name: string;
  paper: string;
  ink: string;
}> = [
  { id: "sand", name: "Пісочна", paper: "#CDC28B", ink: "#38331C" },
  { id: "cream", name: "Кремова", paper: "#EEE6D3", ink: "#2B2419" },
  { id: "sepia", name: "Сепія", paper: "#E4D5B7", ink: "#4A3826" },
  { id: "grey", name: "Сіра", paper: "#C9C9C4", ink: "#242424" },
  { id: "night", name: "Нічна", paper: "#2A2A28", ink: "#C4BFAE" },
  { id: "black", name: "Чорна", paper: "#000000", ink: "#9A9A92" },
];

export const appearance = {
  paperColor: DEFAULT_PAPER,
  inkColor: DEFAULT_INK,

  fontSize: 1.0,
  minimumFontSize: 1.0,
  maximumFontSize: 3.0,
  fontSizeStep: 0.1,

  /**
   * Проміжок між колонками в розкладці мусить бути нульовим: ширина
   * сторінки `W = 2w + G`, крок колонки `w + G`, і різниця `kG` росте з
   * кожним гортанням. Зазор робимо полями всередині колонки.
   */
  columnGap: 0,

  defaultSideMargin: 42,
  minimumSideMargin: 0,
  maximumSideMargin: 160,
  sideMarginStep: 4,

  leftMargin: 42,
  rightMargin: 42,

  spreadGap: 84,
  minimumSpreadGap: 0,
  maximumSpreadGap: 240,

  verticalTextInset: 22,
  minimumColumnWidth: 330,
  maximumLineLength: 120,
  twoColumnThreshold: 700,
};

export function clampSideMargin(value: number): number {
  return Math.min(
    Math.max(Math.round(value), appearance.minimumSideMargin),
    appearance.maximumSideMargin,
  );
}

export function clampSpreadGap(value: number): number {
  return Math.min(
    Math.max(Math.round(value), appearance.minimumSpreadGap),
    appearance.maximumSpreadGap,
  );
}

export function shouldUseTwoColumns(width: number): boolean {
  return width >= appearance.twoColumnThreshold;
}

export interface TextInsets {
  document: { left: number; right: number };
  view: { left: number; right: number };
}

/**
 * Розподіл полів між документом і вікном.
 *
 * Усередині документа проміжок між колонками дорівнює сумі бічних полів —
 * властивість сітки колонок, яку не обійти жодним із трьох важелів. Тому
 * проміжок лишається документу, а бічні поля доміряються звуженням самої
 * області читання: з краю лишається смуга, де видно папір із зерном.
 */
export function textInsets(twoColumns: boolean): TextInsets {
  const left = clampSideMargin(appearance.leftMargin);
  const right = clampSideMargin(appearance.rightMargin);

  if (!twoColumns) {
    return { document: { left, right }, view: { left: 0, right: 0 } };
  }

  const half = clampSpreadGap(appearance.spreadGap) / 2;
  return {
    document: { left: half, right: half },
    view: { left: left - half, right: right - half },
  };
}

/**
 * Бічні поля задаються двома правилами, і це не перестраховка.
 *
 * Readium CSS має на `body` два правила з `!important`: базове
 * `body { padding: 0 var(--RS__pageGutter) }` зі специфічністю (0,0,1) і
 * правило полів користувача `:root[style*="--USER__pageMargins"] body` зі
 * специфічністю (0,2,1). Наш стиль додається в кінець `head`, тож за
 * рівної специфічності виграє він — але лише за рівної.
 */
function sideMarginDeclarations(left: number, right: number): string {
  return `
    padding-left: ${clampSideMargin(left)}px !important;
    padding-right: ${clampSideMargin(right)}px !important;`;
}

/**
 * CSS сторінки.
 *
 * Селектор обов'язково `:root`, а не `html`: Readium CSS фарбує тло
 * правилом `:root { background-color: … !important }` зі специфічністю
 * (0,1,0), а в `html` вона (0,0,1) — і перемагає Readium. На однаковому
 * `:root` виграє те правило, що йде пізніше.
 *
 * `background-attachment: fixed` прив'язує зерно до області перегляду, щоб
 * воно не їхало разом із колонками: аркуш стоїть, рухається текст.
 */
export function pageCSS(twoColumns: boolean, grainDataURI?: string): string {
  const grain = grainDataURI
    ? `
    background-image: url(${grainDataURI}) !important;
    background-repeat: repeat !important;
    background-size: 128px 128px !important;
    background-attachment: fixed !important;`
    : "";

  const { document } = textInsets(twoColumns);
  const margins = sideMarginDeclarations(document.left, document.right);

  return `
:root {
    background-color: ${appearance.paperColor} !important;
    padding-top: ${appearance.verticalTextInset}px !important;
    padding-bottom: ${appearance.verticalTextInset}px !important;
    box-sizing: border-box !important;${grain}
}
body {
    background-color: transparent !important;
    background-image: none !important;${margins}
}
:root[style] body {${margins}
}
`;
}

// MARK: — Збереження

const STORED = "chytach.appearance";

type Stored = Pick<
  typeof appearance,
  "paperColor" | "inkColor" | "fontSize" | "leftMargin" | "rightMargin" | "spreadGap"
>;

/**
 * Оформлення переживає перезапуск.
 *
 * Зберігаємо лише те, що міняє людина: решта значень — константи, і
 * тягнути їх крізь сховище означало б зберегти колись підібране число
 * назавжди, навіть коли воно в коді зміниться.
 */
export function loadAppearance(): void {
  try {
    const raw = window.localStorage.getItem(STORED);
    if (!raw) return;
    const stored = JSON.parse(raw) as Partial<Stored>;
    if (typeof stored.paperColor === "string") appearance.paperColor = stored.paperColor;
    if (typeof stored.inkColor === "string") appearance.inkColor = stored.inkColor;
    if (typeof stored.fontSize === "number") appearance.fontSize = stored.fontSize;
    if (typeof stored.leftMargin === "number") appearance.leftMargin = stored.leftMargin;
    if (typeof stored.rightMargin === "number") appearance.rightMargin = stored.rightMargin;
    if (typeof stored.spreadGap === "number") appearance.spreadGap = stored.spreadGap;
  } catch {
    // Зіпсоване сховище не причина не відкрити книгу.
  }
}

export function saveAppearance(): void {
  try {
    const stored: Stored = {
      paperColor: appearance.paperColor,
      inkColor: appearance.inkColor,
      fontSize: appearance.fontSize,
      leftMargin: appearance.leftMargin,
      rightMargin: appearance.rightMargin,
      spreadGap: appearance.spreadGap,
    };
    window.localStorage.setItem(STORED, JSON.stringify(stored));
  } catch {
    // Те саме.
  }
}

export function resetAppearance(): void {
  appearance.paperColor = DEFAULT_PAPER;
  appearance.inkColor = DEFAULT_INK;
  appearance.fontSize = appearance.minimumFontSize;
  appearance.leftMargin = appearance.defaultSideMargin;
  appearance.rightMargin = appearance.defaultSideMargin;
  appearance.spreadGap = appearance.defaultSideMargin * 2;
  saveAppearance();
}

export function clampFontSize(value: number): number {
  const stepped = Math.round(value * 10) / 10;
  return Math.min(Math.max(stepped, appearance.minimumFontSize), appearance.maximumFontSize);
}
