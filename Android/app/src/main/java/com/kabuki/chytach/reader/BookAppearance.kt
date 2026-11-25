package com.kabuki.chytach.reader

import android.content.Context
import android.util.Base64
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.epub.css.ColCount
import org.readium.r2.navigator.epub.css.Length
import org.readium.r2.navigator.epub.css.RsProperties
import org.readium.r2.navigator.preferences.Color
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.Spread
import org.readium.r2.navigator.preferences.TextAlign
import org.readium.r2.navigator.preferences.Theme
import org.readium.r2.shared.ExperimentalReadiumApi

/**
 * Оформлення сторінки: кольори, кегль, розворот, поля.
 *
 * Порт `BookAppearance` зі Swift-версії. Значення, пороги й причини
 * збігаються навмисно: читалка на двох системах має виглядати однаково, а
 * кожне з цих чисел там уже виміряне на пікселях.
 */
@OptIn(ExperimentalReadiumApi::class)
object BookAppearance {

    // MARK: — Кольори

    const val DEFAULT_PAPER: Int = 0xCDC28B
    const val DEFAULT_INK: Int = 0x38331C

    var paperColor: Int = DEFAULT_PAPER
    var inkColor: Int = DEFAULT_INK

    /** Тло, яке видно до першого кадру й у щілинах. */
    const val VOID: Int = 0x0A0A0A

    // MARK: — Кегль

    const val MINIMUM_FONT_SIZE: Double = 1.0
    const val MAXIMUM_FONT_SIZE: Double = 3.0
    const val FONT_SIZE_STEP: Double = 0.1

    var fontSize: Double = MINIMUM_FONT_SIZE

    // MARK: — Геометрія

    const val MINIMUM_COLUMN_WIDTH: Double = 330.0
    const val MAXIMUM_LINE_LENGTH: Double = 120.0

    /**
     * Проміжок між колонками в розкладці **мусить** бути нульовим.
     *
     * Ширина сторінки `W = 2w + G`, крок колонки `w + G`. Сторінка `k`
     * починається на `k(2w + G)`, колонка `2k` — на `2k(w + G)`; різниця
     * `kG` росте лінійно, і за 36 px на 18-й сторінці це вже 648 px.
     * Зазор робимо полями всередині колонки, а не розкладкою.
     */
    const val COLUMN_GAP: Double = 0.0

    const val DEFAULT_SIDE_MARGIN: Double = 42.0
    const val MINIMUM_SIDE_MARGIN: Double = 0.0
    const val MAXIMUM_SIDE_MARGIN: Double = 160.0
    const val SIDE_MARGIN_STEP: Double = 4.0

    /**
     * Поля ліворуч і праворуч — окремі значення.
     *
     * На телефоні вічко камери зʼїдає смугу біля одного краю, і в
     * горизонтальному положенні текст лізе під нього. Симетричне поле
     * довелося б розганяти з обох боків, втрачаючи рядок там, де нічого
     * не перекриває.
     */
    var leftMargin: Double = DEFAULT_SIDE_MARGIN
    var rightMargin: Double = DEFAULT_SIDE_MARGIN

    val DEFAULT_SPREAD_GAP: Double = DEFAULT_SIDE_MARGIN * 2
    const val MINIMUM_SPREAD_GAP: Double = 0.0
    const val MAXIMUM_SPREAD_GAP: Double = 240.0

    /** Проміжок між колонками на розвороті — окреме значення, не сума полів. */
    var spreadGap: Double = DEFAULT_SPREAD_GAP

    /** Відступ від верхнього й нижнього краю до тексту, у CSS-пікселях. */
    const val VERTICAL_TEXT_INSET: Double = 22.0

    /**
     * Додаткові відступи згори й знизу — рівно на висоту системних вирізів.
     *
     * Та сама причина, що й окремі бічні поля: вічко камери з'їдає смугу
     * біля краю, і верхній рядок лізе просто під нього. Тло при цьому
     * лишається на всю площу — відступ живе всередині `:root`, тож фарба й
     * зерно доходять до самого краю, а відсувається тільки текст.
     */
    var safeTopInset: Double = 0.0
    var safeBottomInset: Double = 0.0

    /** Поріг переходу на дві колонки, у dp. */
    const val TWO_COLUMN_THRESHOLD: Double = 700.0

    fun clampSideMargin(value: Double): Double =
        min(max(value.roundToInt().toDouble(), MINIMUM_SIDE_MARGIN), MAXIMUM_SIDE_MARGIN)

    fun clampSpreadGap(value: Double): Double =
        min(max(value.roundToInt().toDouble(), MINIMUM_SPREAD_GAP), MAXIMUM_SPREAD_GAP)

    fun shouldUseTwoColumns(widthDp: Double): Boolean = widthDp >= TWO_COLUMN_THRESHOLD

    data class Insets(val left: Double, val right: Double)

    data class TextInsets(val document: Insets, val view: Insets)

    /**
     * Розподіл полів між документом і видом.
     *
     * Усередині документа проміжок між колонками **дорівнює** сумі бічних
     * полів — це властивість сітки колонок, не вада: поле в `body`
     * повторюється в кожному фрагменті, тож проміжок усередині сторінки й
     * проміжок через її край — одна й та сама відстань. Тому проміжок
     * лишається документу, а бічні поля доміряються зсувом самого вебвʼю:
     * вужчий за видиму область — з краю лишається смуга з зерном; ширший —
     * зайве відтинається. В одну колонку все поле знову задає документ.
     */
    fun textInsets(twoColumns: Boolean): TextInsets {
        val left = clampSideMargin(leftMargin)
        val right = clampSideMargin(rightMargin)

        if (!twoColumns) {
            return TextInsets(Insets(left, right), Insets(0.0, 0.0))
        }

        val half = clampSpreadGap(spreadGap) / 2
        return TextInsets(Insets(half, half), Insets(left - half, right - half))
    }

    // MARK: — Налаштування Readium

    /**
     * `publisherStyles = false` обовʼязкове: без нього Readium ігнорує
     * `textAlign`, `hyphens` і міжслівні інтервали.
     *
     * `pageMargins` передаємо, хоч справжні поля задає `pageCSS`. Причина не
     * в запасному значенні: без зміни в налаштуваннях Readium не перераховує
     * розкладку й не повідомляє про новий viewport, і повернення на місце
     * чекає таймауту.
     */
    fun preferences(twoColumns: Boolean): EpubPreferences {
        val document = textInsets(twoColumns).document
        return EpubPreferences(
            backgroundColor = Color(argb(paperColor)),
            columnCount = if (twoColumns) ColumnCount.TWO else ColumnCount.ONE,
            fontSize = fontSize,
            hyphens = true,
            pageMargins = (document.left + document.right) / (2 * DEFAULT_SIDE_MARGIN),
            paragraphIndent = 1.0,
            publisherStyles = false,
            scroll = false,
            spread = if (twoColumns) Spread.ALWAYS else Spread.NEVER,
            textAlign = TextAlign.JUSTIFY,
            textColor = Color(argb(inkColor)),
            theme = Theme.LIGHT
        )
    }

    /**
     * Властивості рівня Reading System.
     *
     * Самого `columnCount` недостатньо: правило, що його застосовує,
     * загорнуте в `@media (min-width: 60em)` і на планшеті в портреті не
     * діє. Базове правило пагінації читає `--RS__colCount` і
     * `--RS__colWidth`, а фактична кількість колонок —
     * `min(column-count, ⌊ширина ÷ column-width⌋)`.
     *
     * `maxLineLength` знімає `--RS__maxLineLength: 40rem`, яке
     * перетворюється на `body { max-width: 640px }` і не дає колонкам
     * заповнити ширину.
     */
    fun rsProperties(twoColumns: Boolean): RsProperties =
        RsProperties(
            colWidth = Length.Px(MINIMUM_COLUMN_WIDTH),
            colCount = if (twoColumns) ColCount.TWO else ColCount.ONE,
            colGap = Length.Px(COLUMN_GAP),
            pageGutter = Length.Px(DEFAULT_SIDE_MARGIN),
            maxLineLength = Length.Rem(MAXIMUM_LINE_LENGTH)
        )

    // MARK: — CSS сторінки

    const val STYLE_ELEMENT_ID = "chytach-appearance"

    private var cachedGrainDataUri: String? = null

    /**
     * Зерно як прозоре накладання, закодоване один раз.
     *
     * Перекодовувати 61 КБ на кожну зміну кольору немає сенсу, а віддавати
     * файл через `servedAssets` не вийде: шлях до нього залежить від
     * внутрішнього сервера навігатора.
     */
    private fun grainDataUri(context: Context): String? {
        cachedGrainDataUri?.let { return it }
        return runCatching {
            val bytes = context.assets.open("grain.png").use { it.readBytes() }
            val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
            "data:image/png;base64,$base64".also { cachedGrainDataUri = it }
        }.getOrNull()
    }

    /**
     * Бічні поля задаються двома правилами, і це не перестраховка.
     *
     * Readium CSS має на `body` два правила з `!important`: базове
     * `body { padding: 0 var(--RS__pageGutter) }` зі специфічністю (0,0,1) і
     * правило полів користувача `:root[style*="--USER__pageMargins"] body`
     * зі специфічністю (0,2,1). Друге діє завжди, бо `pageMargins` ми
     * передаємо. Наш стиль додається в кінець документа, тож за рівної
     * специфічності виграє він — але лише за рівної.
     */
    private const val SIDE_MARGIN_SELECTOR = ":root[style]"

    fun sideMarginDeclarations(left: Double, right: Double): String =
        """
            padding-left: ${clampSideMargin(left).toInt()}px !important;
            padding-right: ${clampSideMargin(right).toInt()}px !important;
        """.trimIndent()

    /**
     * CSS, що задає тло сторінки прямо в документі.
     *
     * Селектор обовʼязково `:root`, а не `html`: Readium CSS фарбує тло
     * правилом `:root { background-color: … !important }` зі специфічністю
     * (0,1,0), а в `html` вона (0,0,1) — і Readium перемагає зі своїм
     * кольором. На однаковому `:root` виграє те правило, що йде пізніше.
     *
     * `background-attachment: fixed` прив'язує зерно до області перегляду,
     * щоб воно не їхало разом із колонками: аркуш стоїть, рухається текст.
     */
    fun pageCSS(context: Context, twoColumns: Boolean): String {
        val grainLayer = grainDataUri(context)?.let {
            """
                background-image: url($it) !important;
                background-repeat: repeat !important;
                background-size: 128px 128px !important;
                background-attachment: fixed !important;
            """.trimIndent()
        } ?: ""

        val document = textInsets(twoColumns).document
        val margins = sideMarginDeclarations(document.left, document.right)

        return """
        :root {
            background-color: ${cssHex(paperColor)} !important;
            padding-top: ${(VERTICAL_TEXT_INSET + safeTopInset).toInt()}px !important;
            padding-bottom: ${(VERTICAL_TEXT_INSET + safeBottomInset).toInt()}px !important;
            box-sizing: border-box !important;
            $grainLayer
        }
        body {
            background-color: transparent !important;
            background-image: none !important;
            $margins
        }
        $SIDE_MARGIN_SELECTOR body {
            $margins
        }
        """.trimIndent()
    }

    /**
     * Скрипт, що вставляє стиль у документ.
     *
     * На iOS те саме робить user script, який WebKit виконує в кінці
     * документа. Android-навігатор такого хука не має, тож вставляємо
     * вручну після кожного завантаження ресурсу — елемент знаходимо за
     * `id` і замінюємо, щоб повторний виклик нічого не плодив.
     */
    fun styleInjectionScript(context: Context, twoColumns: Boolean): String {
        val css = pageCSS(context, twoColumns)
        return """
        (function () {
            var id = ${jsString(STYLE_ELEMENT_ID)};
            var style = document.getElementById(id);
            if (!style) {
                style = document.createElement('style');
                style.id = id;
                document.head.appendChild(style);
            } else {
                document.head.appendChild(style);
            }
            style.textContent = ${jsString(css)};
            return true;
        })();
        """.trimIndent()
    }

    // MARK: — Дрібниці

    /** `0xRRGGBB` → непрозорий ARGB, якого чекає Android. */
    fun argb(rgb: Int): Int = (0xFF shl 24) or (rgb and 0xFFFFFF)

    fun cssHex(rgb: Int): String = String.format("#%06X", rgb and 0xFFFFFF)

    private fun jsString(value: String): String =
        "\"" + value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "") + "\""
}
