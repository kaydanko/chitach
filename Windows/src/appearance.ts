/**
 * Оформлення сторінки — порт `BookAppearance` зі Swift і Kotlin версій.
 *
 * Значення ті самі, бо вони вже виміряні на пікселях: читалка на трьох
 * системах має виглядати однаково.
 */

export const DEFAULT_PAPER = "#CDC28B";
export const DEFAULT_INK = "#38331C";

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
