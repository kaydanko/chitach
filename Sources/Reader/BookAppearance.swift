import ReadiumNavigator
import ReadiumShared
import UIKit

extension UIColor {
    /// `UIColor` із числа виду `0xRRGGBB`.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// `0xRRGGBB`.
    var hexValue: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt32(r * 255) << 16) | (UInt32(g * 255) << 8) | UInt32(b * 255)
    }

    /// `#RRGGBB` для вставки в CSS.
    var cssHex: String { String(format: "#%06X", hexValue) }

    /// Наскільки колір світлий (0…1). Потрібно, щоб підібрати контрастний
    /// колір дрібних елементів поверх довільного тла.
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// Оформлення сторінки: кольори, кегль, розворот.
///
/// Кольори не константи, бо їх задає користувач у налаштуваннях. Значення за
/// замовчуванням зняті піксельно з референсного скриншота.
enum BookAppearance {
    // MARK: - Налаштовні значення

    static let defaultPaper = UIColor(hex: 0xCDC28B)
    static let defaultInk = UIColor(hex: 0x38331C)

    /// Тло сторінки.
    static var paperColor = defaultPaper

    /// Колір тексту. Навмисно не чорний: на теплому тлі чистий чорний дає
    /// надмірний контраст.
    static var inkColor = defaultInk

    /// Кегль як множник. 1.0 — найменший, далі вгору.
    static var fontSize: Double = minimumFontSize

    static let minimumFontSize: Double = 1.0
    static let maximumFontSize: Double = 3.0
    static let fontSizeStep: Double = 0.1

    // MARK: - Похідні кольори хрому

    /// Текст на темному тлі застосунку — екран без книги, повідомлення про
    /// помилки.
    ///
    /// Книжкове чорнило тут не годиться: воно темно-оливкове, розраховане на
    /// світлий папір, і на майже чорному тлі зливається з ним.
    static let onVoidColor = UIColor(hex: 0xE4DFD0)

    static var onVoidMutedColor: UIColor {
        onVoidColor.withAlphaComponent(0.60)
    }

    /// Приглушений колір дрібного тексту поверх паперу.
    static var mutedInkColor: UIColor {
        inkColor.withAlphaComponent(0.55)
    }

    /// Відступ ліворуч у шапці.
    ///
    /// Був час, коли на Mac тут стояв резерв у 78 pt: системні кнопки вікна
    /// лягали поверх наших, бо власний титульний рядок ми ховаємо. Відтоді
    /// шапку переробили, накладання більше не відтворюється, і резерв лише
    /// відсував кнопки від краю. Якщо колись повернеться — причина саме ця.
    static let toolbarLeadingInset: CGFloat = 14

    /// Чим фарбуємо webview, доки сторінка ще не відмальована.
    ///
    /// Не кольором паперу: нова сторінка вантажиться помітний час, і
    /// порожній аркуш кольору паперу виглядав би як готова, але порожня
    /// сторінка. Чорне читається як «зараз буде», а не як помилка — і не
    /// сліпить, на відміну від білого, яке WebKit малює за замовчуванням.
    static let loadingBackdropColor = voidColor

    static let toolbarColor = UIColor(hex: 0x000000)

    /// Тло, яке видно до того, як книга відрендериться, і в будь-яких щілинах.
    /// Чорне навмисно: у темряві спалах білого екрана на запуску різкий для
    /// очей.
    static let voidColor = UIColor(hex: 0x0A0A0A)
    static let toolbarControlColor = UIColor(hex: 0x323232)
    static let footerColor = UIColor(hex: 0x212121)

    // MARK: - Налаштування Readium

    /// `publisherStyles: false` обовʼязкове, а не стильове рішення: без нього
    /// Readium ігнорує `textAlign`, `hyphens` і міжслівні інтервали — так
    /// описано в docs/Guides/Navigator/Preferences.md.
    ///
    /// `backgroundColor` навмисно не задаємо: будь-яке значення тут емітує
    /// `--USER__backgroundColor`, який Readium CSS застосовує з `!important`
    /// і яким перекриває нашу текстуру. Тло задається в `pageCSS`.
    static func preferences(twoColumns: Bool) -> EPUBPreferences {
        EPUBPreferences(
            columnCount: twoColumns ? .two : .one,
            fontSize: fontSize,
            hyphens: true,
            pageMargins: 1.0,
            paragraphIndent: 1.0,
            publisherStyles: false,
            scroll: false,
            spread: twoColumns ? .always : .never,
            textAlign: .justify,
            textColor: Color(uiColor: inkColor),
            theme: .light
        )
    }

    /// Конфігурація навігатора.
    ///
    /// `readiumCSSRSProperties` — найважливіша частина. Самого
    /// `columnCount: .two` недостатньо:
    ///
    /// 1. `columnCount` мапиться в `--USER__colCount`, а правило, що його
    ///    застосовує, загорнуте в `@media (min-width: 60em)` — працює лише
    ///    від 960px, тож на планшеті в портреті не діє взагалі.
    /// 2. Базове правило пагінації без медіазапиту читає `--RS__colCount`
    ///    (дефолт 1) і `--RS__colWidth` (дефолт 45em ≈ 720px), а фактична
    ///    кількість колонок = `min(column-count, ⌊ширина ÷ column-width⌋)`.
    ///
    /// Тому задаємо RS-рівень напряму. Readium інжектить ці властивості
    /// інлайновим `style` на `<html>`, що перебиває таблицю стилів.
    static func navigatorConfiguration(twoColumns: Bool) -> EPUBNavigatorViewController.Configuration {
        EPUBNavigatorViewController.Configuration(
            preferences: preferences(twoColumns: twoColumns),
            // Нуль: поле тексту має доходити до самого верху області читання.
            // Будь-який відступ лишає смугу, яку малює не документ, а шар під
            // ним — саме вона роками читалася як білий дефект.
            // Вертикальні поля дають власні панелі зверху й знизу.
            contentInset: [
                .compact: (top: 0, bottom: 0),
                .regular: (top: 0, bottom: 0),
            ],
            readiumCSSRSProperties: CSSRSProperties(
                colWidth: CSSPxLength(minimumColumnWidth),
                colCount: twoColumns ? .two : .one,
                colGap: CSSPxLength(columnGap),
                pageGutter: CSSPxLength(sideMargin),
                // Знімаємо `--RS__maxLineLength: 40rem`, яке перетворюється на
                // `body { max-width: 640px }` і не дає колонкам заповнити
                // ширину, а при фрагментації ще й зміщує текст від сторінки до
                // сторінки.
                maxLineLength: CSSRemLength(maximumLineLength)
            )
        )
    }

    // MARK: - Геометрія

    static let minimumColumnWidth: Double = 330

    /// Проміжок між колонками **мусить** бути нульовим.
    ///
    /// Інакше посторінкова прокрутка розходиться з розкладкою колонок, і
    /// похибка накопичується з кожним гортанням. Арифметика проста: ширина
    /// сторінки `W = 2w + G`, а крок колонки — `w + G`. Сторінка `k`
    /// починається на `kW = k(2w + G)`, колонка `2k` — на `2k(w + G)`.
    /// Різниця `kG` росте лінійно: за проміжку 36 px на 18-й сторінці це
    /// вже 648 px — видно край попередньої сторінки, а поточна зрізана.
    ///
    /// Нуль — єдине значення, за якого рівність тримається, і Readium не
    /// випадково має саме його за замовчуванням. Зазор між колонками
    /// створюємо не розкладкою, а полями всередині колонки.
    static let columnGap: Double = 0

    /// Бічні поля. Мають умістити кнопки гортання, щоб текст під них не
    /// підлазив.
    static let sideMargin: Double = 42

    /// Ширина кнопки гортання біля краю.
    static let pageTurnButtonWidth: CGFloat = 30

    static let maximumLineLength: Double = 120

    /// Відступ від верхнього й нижнього краю до тексту, у CSS-пікселях.
    ///
    /// Живе всередині документа, а не в `contentInset` навігатора: відступ
    /// ззовні лишав смугу, де документ не малює ні тла, ні зерна. Усередині —
    /// фактура доходить до самого краю, а текст усе одно не тулиться.
    static let verticalTextInset: Double = 22

    /// Поріг переходу на дві колонки. Вужче — рядок стає надто коротким, і
    /// виключка розриває слова драбинкою.
    static func shouldUseTwoColumns(width: CGFloat) -> Bool {
        width >= 700
    }

    // MARK: - CSS сторінки

    /// Зерно як прозоре накладання. Кешуємо base64 один раз: перекодовувати
    /// 61 КБ на кожну зміну кольору немає сенсу.
    private static let grainDataURI: String? = {
        guard
            let url = Bundle.main.url(forResource: "grain@2x", withExtension: "png"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("grain@2x.png не потрапив у бандл")
            return nil
        }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }()

    /// CSS, що задає тло сторінки прямо в документі.
    ///
    /// Чому в документі, а не прозорим webview з підкладкою знизу:
    /// діагностика показала, що `html` і `body` справді стають прозорими, усі
    /// `WKWebView` обробляються — і WebKit усе одно малює білу підкладку.
    /// Якщо тло всередині документа, шар під webview перестає мати значення.
    ///
    /// `background-attachment: fixed` прив'язує зерно до області перегляду,
    /// щоб воно не їхало разом із колонками: аркуш стоїть, рухається текст.
    ///
    /// Селектор обовʼязково `:root`, а не `html`. Readium CSS фарбує тло
    /// правилом `:root { background-color: var(--RS__backgroundColor)
    /// !important }` зі специфічністю (0,1,0); у `html` вона (0,0,1), і при
    /// рівній важливості перемагає Readium зі своїм білим. На однаковому
    /// `:root` виграє те правило, що йде пізніше, — наше.
    static let styleElementID = "chytach-appearance"

    static var pageCSS: String {
        let grainLayer = grainDataURI.map {
            """
                background-image: url(\($0)) !important;
                background-repeat: repeat !important;
                background-size: 128px 128px !important;
                background-attachment: fixed !important;
            """
        } ?? ""

        return """
        :root {
            background-color: \(paperColor.cssHex) !important;
            padding-top: \(Int(verticalTextInset))px !important;
            padding-bottom: \(Int(verticalTextInset))px !important;
            box-sizing: border-box !important;
        \(grainLayer)
        }
        body {
            background-color: transparent !important;
            background-image: none !important;
        }
        """
    }
}
