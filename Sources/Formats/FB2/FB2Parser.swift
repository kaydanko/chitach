import Foundation

/// Розбирає FB2 — XML-формат, поширений в українських і російських
/// бібліотеках.
///
/// Потоково, через `XMLParser`, а не побудовою дерева: книжки трапляються на
/// десятки мегабайтів, а дерево нам ні до чого — текст однаково одразу
/// перетворюється на XHTML. Заразом `XMLParser` сам розбирається з
/// оголошенням кодування, тож windows-1251 читається без наших здогадок.
///
/// Структура FB2, яка тут важлива:
/// - `<description><title-info>` — назва, автори, мова, обкладинка;
/// - `<body>` з вкладеними `<section>` — власне текст;
/// - `<body name="notes">` — зноски, окремим розділом;
/// - `<binary>` наприкінці файлу — картинки в base64.
///
/// Картинки й зноски посилаються одне на одне ідентифікаторами, а `<binary>`
/// лежать **після** тексту, який на них посилається. Тому в розмітку спершу
/// йдуть мітки, а справжні шляхи підставляються, коли файл дочитано.
final class FB2Parser: NSObject {
    struct Document {
        var title: String
        var authors: [String]
        var language: String
        var chapters: [EPUBBuilder.Chapter]
        var images: [EPUBBuilder.Resource]
    }

    enum ParseError: LocalizedError {
        case malformed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case let .malformed(reason): "Не вдалося розібрати FB2: \(reason)"
            case .empty: "У файлі FB2 немає тексту."
            }
        }
    }

    static func parse(data: Data) throws -> Document {
        let parser = FB2Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false   // `l:href` лишається як є

        guard xml.parse() else {
            throw ParseError.malformed(
                xml.parserError?.localizedDescription ?? "невідома помилка"
            )
        }
        return try parser.makeDocument()
    }

    // MARK: - Стан розбору

    private enum Region {
        case outside
        case description
        case body
        case notes
        case binary
    }

    private var region: Region = .outside

    /// Шлях у `<description>` — щоб відрізнити `<title-info><lang>` від
    /// однойменних полів в інших розділах опису.
    private var descriptionPath: [String] = []

    private var bookTitle = ""
    private var authors: [String] = []
    private var authorParts: [String: String] = [:]
    private var language = ""
    private var coverID: String?

    /// Глибина вкладених `<section>`: верхній рівень — окремий розділ книги.
    private var sectionDepth = 0

    /// Скільки відкрито елементів, які справді містять текст. Поза ними
    /// пробіли й переводи рядка — лише форматування самого XML.
    private var textDepth = 0

    private var chapters: [EPUBBuilder.Chapter] = []
    private var currentChapter = ""
    private var currentTitle: String?

    /// Збираємо заголовок окремо: він потрібен і в розмітці, і у змісті.
    private var titleBuffer: String?

    /// Чи ми всередині `<title>` і скільки абзаців там уже було.
    ///
    /// У FB2 заголовок складається з `<p>`, але вкладати абзац у `<h2>` не
    /// можна — це недійсний HTML, і читалка покаже заголовок розірваним.
    private var titleDepth = 0
    private var titleParagraphs = 0

    /// Чи ми всередині епіграфа або цитати.
    private var quoteDepth = 0

    private var notesHTML = ""

    /// Ідентифікатори секцій поточного розділу. Справжній номер розділу
    /// відомий лише тоді, коли розділ дочитано: порожні ми відкидаємо, і
    /// нумерація зсунулася б.
    private var pendingAnchors: [String] = []
    private var anchorChapter: [String: Int] = [:]
    private var noteAnchors: [String] = []

    /// Ідентифікатори відкритих секцій — щоб, закриваючи зноску, знати, яку
    /// саме закрили.
    private var sectionIDs: [String?] = []

    /// Зноска → перше посилання на неї в тексті. Потрібне для зворотного
    /// переходу: дочитавши зноску, читач має повернутися туди, де був, а не
    /// гортати назад сторінками.
    private var noteBackReferences: [String: String] = [:]
    private var noteReferenceCount = 0

    /// Ідентифікатори, на які посилаються мітки. У самій мітці — лише номер
    /// у цьому списку: ідентифікатор — чужі дані, і з `@@` чи `<` усередині
    /// він обірвав би мітку, а хвіст ліг би в XHTML неекранованим, тобто
    /// розміткою або скриптом у WKWebView.
    private var markerTargets: [String] = []

    private var binaryID = ""
    private var binaryType = ""
    private var binaryBuffer = ""
    private var binaries: [(id: String, type: String, data: Data)] = []

    private var output: String {
        get { region == .notes ? notesHTML : currentChapter }
        set { if region == .notes { notesHTML = newValue } else { currentChapter = newValue } }
    }

    // MARK: - Відповідники тегів

    /// Накреслення. Назви FB2 інші, ніж у HTML, але зміст той самий.
    private static let inlineTags: [String: String] = [
        "emphasis": "em",
        "strong": "strong",
        "strikethrough": "s",
        "sub": "sub",
        "sup": "sup",
        "code": "code",
    ]

    /// Блоки. Клас проставляємо там, де HTML-тег сам по собі змісту не
    /// передає: вірш, строфа, рядок вірша, підпис під цитатою.
    private static let blockTags: [String: (tag: String, cssClass: String?, style: String?)] = [
        "p": ("p", nil, nil),
        "subtitle": ("p", "subtitle", centered),
        "cite": ("blockquote", "cite", nil),
        "epigraph": ("blockquote", "epigraph", nil),
        "poem": ("div", "poem", nil),
        "stanza": ("div", "stanza", nil),
        "v": ("p", "verse", flushLeft),
        "text-author": ("p", "text-author", flushRight),
        "table": ("table", nil, nil),
        "tr": ("tr", nil, nil),
        "td": ("td", nil, nil),
        "th": ("th", nil, nil),
        "annotation": ("div", "annotation", nil),
    ]

    /// Вирівнювання й червоний рядок задаємо вбудованим стилем, а не класом.
    ///
    /// Readium CSS нав'язує виключку користувача правилом виду
    /// `:root[style*="--USER__textAlign"] p { … !important }`. Воно
    /// специфічніше за будь-який наш клас, тож рядок вірша розтягувало б по
    /// ширині, а підпис під епіграфом стояв би ліворуч. Вбудований стиль
    /// переважує будь-який селектор — це єдиний надійний шлях.
    private static let flushLeft = "text-indent:0 !important;text-align:left !important"
    private static let flushRight = "text-indent:0 !important;text-align:right !important"
    private static let centered = "text-indent:0 !important;text-align:center !important"
    private static let noIndent = "text-indent:0 !important"

    /// Елементи, усередині яких текст — це текст, а не відступи XML.
    private static let textBearing: Set<String> = [
        "p", "v", "subtitle", "text-author", "td", "th", "code",
    ]
}

// MARK: - XMLParserDelegate

extension FB2Parser: XMLParserDelegate {
    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        switch element {
        case "description":
            region = .description
            return

        case "body":
            // `<body name="notes">` — зноски; решта тіл це текст книги.
            region = attributes["name"] == "notes" ? .notes : .body
            return

        case "binary":
            region = .binary
            binaryID = attributes["id"] ?? ""
            binaryType = attributes["content-type"] ?? "image/jpeg"
            binaryBuffer = ""
            return

        default:
            break
        }

        switch region {
        case .description:
            descriptionPath.append(element)
            if element == "image", descriptionPath.contains("coverpage") {
                coverID = Self.reference(from: attributes)
            }

        case .body, .notes:
            startBodyElement(element, attributes: attributes)

        case .outside, .binary:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement element: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        switch element {
        case "description":
            region = .outside
            descriptionPath.removeAll()
            return

        case "body":
            finishChapter()
            region = .outside
            return

        case "binary":
            if let data = Data(base64Encoded: binaryBuffer, options: .ignoreUnknownCharacters),
               !data.isEmpty, !binaryID.isEmpty
            {
                binaries.append((binaryID, binaryType, data))
            }
            binaryBuffer = ""
            region = .outside
            return

        default:
            break
        }

        switch region {
        case .description:
            endDescriptionElement(element)
        case .body, .notes:
            endBodyElement(element)
        case .outside, .binary:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch region {
        case .binary:
            binaryBuffer += string

        case .description:
            guard let field = descriptionPath.last else { return }
            switch field {
            case "book-title" where descriptionPath.contains("title-info"):
                bookTitle += string
            case "lang" where descriptionPath.contains("title-info"):
                language += string.trimmingCharacters(in: .whitespacesAndNewlines)
            case "first-name", "middle-name", "last-name", "nickname":
                guard descriptionPath.contains("author") else { return }
                authorParts[field, default: ""] += string
            default:
                break
            }

        case .body, .notes:
            // Поза текстовими елементами пробіли — лише відступи XML.
            guard textDepth > 0 else { return }
            let escaped = EPUBBuilder.escape(string)
            if titleBuffer != nil { titleBuffer? += string }
            output += escaped

        case .outside:
            break
        }
    }
}

// MARK: - Розмітка тіла

private extension FB2Parser {
    func startBodyElement(_ element: String, attributes: [String: String]) {
        switch element {
        case "section":
            sectionDepth += 1
            if region == .body, sectionDepth == 1 {
                startChapter()
            }
            sectionIDs.append(attributes["id"])
            if let id = attributes["id"] {
                if region == .notes { noteAnchors.append(id) } else { pendingAnchors.append(id) }
                output += "<div id=\"\(Self.attribute(id))\">"
            } else {
                output += "<div>"
            }

        case "title":
            // Заголовок верхнього рівня стає назвою розділу у змісті.
            if titleBuffer == nil { titleBuffer = "" }
            titleDepth += 1
            titleParagraphs = 0
            output += "<h\(headingLevel)>"
            textDepth += 1

        case "p" where titleDepth > 0:
            // Абзаци заголовка розділяємо переносом рядка, а не тегами.
            if titleParagraphs > 0 {
                output += "<br/>"
                titleBuffer? += " "
            }
            titleParagraphs += 1
            textDepth += 1

        case "empty-line":
            output += "<p class=\"empty-line\"><br/></p>"

        case "image":
            guard let id = Self.reference(from: attributes) else { return }
            output += marker(Self.imageMarkerPrefix, id)

        case "a":
            let target = Self.reference(from: attributes) ?? ""
            var extra = ""
            if attributes["type"] == "note" {
                extra = " class=\"note\""
                // Своє місце в тексті посилання отримує лише в основному
                // тексті: саме сюди веде зворотний перехід зі зноски.
                if region == .body {
                    noteReferenceCount += 1
                    let id = "fb2-ref-\(noteReferenceCount)"
                    extra += " id=\"\(id)\""
                    pendingAnchors.append(id)
                    if noteBackReferences[target] == nil { noteBackReferences[target] = id }
                }
            }
            output += "<a href=\"\(marker(Self.linkMarkerPrefix, target))\"\(extra)>"
            textDepth += 1

        default:
            if let inline = Self.inlineTags[element] {
                output += "<\(inline)>"
            } else if let block = Self.blockTags[element] {
                if element == "epigraph" || element == "cite" { quoteDepth += 1 }

                let cssClass = block.cssClass.map { " class=\"\($0)\"" } ?? ""
                // Абзац усередині епіграфа чи цитати теж без червоного рядка.
                let style = block.style ?? (element == "p" && quoteDepth > 0 ? Self.noIndent : nil)
                let inlineStyle = style.map { " style=\"\($0)\"" } ?? ""

                output += "<\(block.tag)\(cssClass)\(inlineStyle)>"
                if Self.textBearing.contains(element) { textDepth += 1 }
            }
        }
    }

    func endBodyElement(_ element: String) {
        switch element {
        case "section":
            let id = sectionIDs.popLast() ?? nil
            if region == .notes, let id {
                output += marker(Self.backMarkerPrefix, id)
            }
            output += "</div>"
            sectionDepth = max(0, sectionDepth - 1)
            if region == .body, sectionDepth == 0 {
                finishChapter()
            }

        case "p" where titleDepth > 0:
            textDepth = max(0, textDepth - 1)

        case "title":
            output += "</h\(headingLevel)>"
            textDepth = max(0, textDepth - 1)
            titleDepth = max(0, titleDepth - 1)
            if currentTitle == nil {
                // Між абзацами заголовка в XML лише перевід рядка й відступ;
                // у змісті з нього має вийти один пробіл.
                let text = titleBuffer?
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                currentTitle = (text?.isEmpty == false) ? text : nil
            }
            titleBuffer = nil

        case "empty-line", "image":
            break

        case "a":
            output += "</a>"
            textDepth = max(0, textDepth - 1)

        default:
            if let inline = Self.inlineTags[element] {
                output += "</\(inline)>"
            } else if let block = Self.blockTags[element] {
                output += "</\(block.tag)>"
                if element == "epigraph" || element == "cite" { quoteDepth = max(0, quoteDepth - 1) }
                if Self.textBearing.contains(element) { textDepth = max(0, textDepth - 1) }
            }
        }
    }

    /// Рівень заголовка за глибиною вкладення: `<title>` самого тіла — це
    /// назва книги або частини, тож `h1`.
    var headingLevel: Int {
        sectionDepth == 0 ? 1 : min(6, sectionDepth + 1)
    }

    /// Початок розділу книги.
    ///
    /// Накопичене навмисно не стираємо: до першої секції тіло встигає
    /// віддати назву книги та епіграфи, і вони належать першому розділові.
    /// Саме через стирання вони спершу зникали безслідно.
    func startChapter() {
        currentTitle = nil
        pendingAnchors.removeAll()
    }

    func finishChapter() {
        guard region != .notes else { return }
        let trimmed = currentChapter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chapters.append(.init(title: currentTitle, bodyXHTML: trimmed))
        for id in pendingAnchors { anchorChapter[id] = chapters.count - 1 }
        pendingAnchors.removeAll()
        currentChapter = ""
        currentTitle = nil
    }

    func endDescriptionElement(_ element: String) {
        if element == "author", !authorParts.isEmpty {
            let name = ["first-name", "middle-name", "last-name", "nickname"]
                .compactMap { authorParts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !name.isEmpty, descriptionPath.contains("title-info") {
                authors.append(name)
            }
            authorParts.removeAll()
        }
        if descriptionPath.last == element { descriptionPath.removeLast() }
    }

    /// `l:href="#id"` — посилання на `<binary>` або на зноску.
    static func reference(from attributes: [String: String]) -> String? {
        let raw = attributes["l:href"]
            ?? attributes["xlink:href"]
            ?? attributes["href"]
        guard let raw else { return nil }
        return raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    }
}

// MARK: - Мітки

/// Картинки й зноски в FB2 посилаються на ідентифікатори, а самі `<binary>`
/// лежать у файлі **після** тексту. Тому в розмітку спершу йде мітка, а
/// справжній шлях підставляється, коли файл дочитано й відомо, що де лежить.
private extension FB2Parser {
    /// Починаються з U+0001: XML 1.0 не дозволяє цей символ у тексті, тож
    /// `XMLParser` його ніколи не віддасть, і мітку неможливо підробити
    /// текстом книги.
    static let imageMarkerPrefix = "\u{1}fb2-image:"
    static let linkMarkerPrefix = "\u{1}fb2-link:"
    static let backMarkerPrefix = "\u{1}fb2-back:"
    static let markerSuffix = "\u{1}"

    func marker(_ prefix: String, _ id: String) -> String {
        markerTargets.append(id)
        return prefix + String(markerTargets.count - 1) + Self.markerSuffix
    }

    /// Ідентифікатор за номером із мітки. Чужий номер дає `nil`.
    func target(of index: String) -> String? {
        guard let index = Int(index), markerTargets.indices.contains(index) else { return nil }
        return markerTargets[index]
    }

    /// Значення атрибута. `escape` лапок не чіпає — для тексту вони
    /// безпечні, а ідентифікатор із лапкою розірвав би атрибут.
    static func attribute(_ value: String) -> String {
        EPUBBuilder.escape(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func replacingMarkers(
        in text: String,
        prefix: String,
        with replacement: (String) -> String
    ) -> String {
        guard text.contains(prefix) else { return text }

        var result = ""
        var rest = Substring(text)

        while let start = rest.range(of: prefix) {
            result += rest[rest.startIndex ..< start.lowerBound]
            let tail = rest[start.upperBound...]

            guard let close = tail.range(of: markerSuffix) else {
                result += rest[start.lowerBound...]
                return result
            }

            result += replacement(String(tail[tail.startIndex ..< close.lowerBound]))
            rest = tail[close.upperBound...]
        }

        return result + rest
    }
}

// MARK: - Збирання результату

extension FB2Parser {
    func makeDocument() throws -> Document {
        let notes = notesHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            chapters.append(.init(title: "Примітки", bodyXHTML: notes))
            for id in noteAnchors { anchorChapter[id] = chapters.count - 1 }
        }

        guard !chapters.isEmpty else { throw ParseError.empty }

        var images: [EPUBBuilder.Resource] = []
        var paths: [String: String] = [:]
        for binary in binaries {
            let (ext, mediaType) = Self.imageFormat(declared: binary.type, data: binary.data)
            let path = "images/\(images.count + 1).\(ext)"
            paths[binary.id] = path
            images.append(.init(
                path: path,
                data: binary.data,
                mediaType: mediaType,
                isCover: binary.id == coverID
            ))
        }

        func href(to id: String) -> String {
            let anchor = Self.attribute(id)
            guard let index = anchorChapter[id] else { return "#\(anchor)" }
            return "chapter\(index + 1).xhtml#\(anchor)"
        }

        let resolved = chapters.map { chapter in
            var body = Self.replacingMarkers(in: chapter.bodyXHTML, prefix: Self.imageMarkerPrefix) {
                guard let id = target(of: $0), let path = paths[id] else { return "" }
                return "<img src=\"\(path)\" alt=\"\" style=\"max-width:100%;height:auto\"/>"
            }
            body = Self.replacingMarkers(in: body, prefix: Self.linkMarkerPrefix) {
                target(of: $0).map(href(to:)) ?? "#"
            }
            // Зноска, на яку в тексті ніхто не посилається, лишається без
            // зворотного переходу: вести нікуди.
            body = Self.replacingMarkers(in: body, prefix: Self.backMarkerPrefix) {
                guard let id = target(of: $0), let reference = noteBackReferences[id] else { return "" }
                return "<p class=\"backref\" style=\"\(Self.flushLeft)\">"
                    + "<a href=\"\(href(to: reference))\">↩ до тексту</a></p>"
            }
            return EPUBBuilder.Chapter(title: chapter.title, bodyXHTML: body)
        }

        return Document(
            title: bookTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            authors: authors,
            language: language.isEmpty ? "uk" : language,
            chapters: resolved,
            images: images
        )
    }

    /// Тип картинки. Оголошеному в `content-type` довіряємо лише тоді, коли
    /// EPUB такий формат узагалі дозволяє; інакше дивимося на самі байти.
    static func imageFormat(declared: String, data: Data) -> (String, String) {
        switch declared.lowercased() {
        case "image/jpeg", "image/jpg": return ("jpg", "image/jpeg")
        case "image/png": return ("png", "image/png")
        case "image/gif": return ("gif", "image/gif")
        case "image/svg+xml": return ("svg", "image/svg+xml")
        default: break
        }

        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return ("jpg", "image/jpeg")
        }
        if bytes.count >= 3, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return ("gif", "image/gif")
        }
        return ("png", "image/png")
    }
}
