import CryptoKit
import Foundation

/// Збирає розпакований EPUB із готових розділів.
///
/// Спільна основа для всіх форматів, яких Readium не знає: TXT, RTF, далі
/// FB2. Кожен конвертер відповідає лише за перетворення свого формату в
/// XHTML-розділи, а пакування, маніфест і зміст — тут.
///
/// Результат — **каталог**, не ZIP. Readium відкриває його через
/// `DirectoryContainer`, тож архівувати немає потреби: економимо і час, і
/// місце.
enum EPUBBuilder {
    struct Chapter {
        /// Назва для змісту. `nil` — буде «Частина N».
        var title: String?
        /// Вміст `<body>` у вигляді XHTML.
        var bodyXHTML: String
    }

    /// Додатковий файл усередині книги: зображення, обкладинка.
    struct Resource {
        /// Шлях відносно теки `EPUB/`, наприклад `images/1.jpg`.
        var path: String
        var data: Data
        var mediaType: String
        /// Чи є це зображення обкладинкою.
        var isCover: Bool = false
    }

    struct Metadata {
        var title: String
        var authors: [String] = []
        var language: String = "uk"
        /// Стабільний ключ книги. Він же — імʼя теки кешу.
        var identifier: String
    }

    // MARK: - Складання

    /// Каталог уже зібраної книги, якщо вона є в кеші.
    ///
    /// Окремо від ``build(metadata:chapters:resources:)``, бо туди треба
    /// прийти з готовими розділами — тобто вже розібравши файл. Для FB2 це
    /// розпакування й увесь XML, і саме їх кеш має заощадити.
    static func cachedBook(identifier: String) -> URL? {
        let destination = cacheDirectory.appendingPathComponent(identifier, isDirectory: true)
        let marker = destination.appendingPathComponent("EPUB/package.opf")
        return FileManager.default.fileExists(atPath: marker.path) ? destination : nil
    }

    /// Повертає каталог готового EPUB. Якщо такий уже зібрано, віддає кеш.
    static func build(
        metadata: Metadata,
        chapters: [Chapter],
        resources: [Resource] = []
    ) throws -> URL {
        let destination = cacheDirectory.appendingPathComponent(
            metadata.identifier,
            isDirectory: true
        )
        let marker = destination.appendingPathComponent("EPUB/package.opf")

        if FileManager.default.fileExists(atPath: marker.path) {
            return destination
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("META-INF"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("EPUB"),
            withIntermediateDirectories: true
        )

        let chapters = chapters.isEmpty
            ? [Chapter(title: nil, bodyXHTML: "<p></p>")]
            : chapters

        try write("application/epub+zip", to: destination.appendingPathComponent("mimetype"))
        try write(containerXML(), to: destination.appendingPathComponent("META-INF/container.xml"))

        for (index, chapter) in chapters.enumerated() {
            try write(
                chapterXHTML(chapter, language: metadata.language, fallbackTitle: metadata.title),
                to: destination.appendingPathComponent("EPUB/chapter\(index + 1).xhtml")
            )
        }

        for resource in resources {
            let url = destination.appendingPathComponent("EPUB/\(resource.path)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try resource.data.write(to: url, options: .atomic)
        }

        try write(
            navXHTML(chapters: chapters, metadata: metadata),
            to: destination.appendingPathComponent("EPUB/nav.xhtml")
        )
        try write(
            packageOPF(chapters: chapters, resources: resources, metadata: metadata),
            to: destination.appendingPathComponent("EPUB/package.opf")
        )

        return destination
    }

    // MARK: - Шаблони

    private static func containerXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private static func chapterXHTML(
        _ chapter: Chapter,
        language: String,
        fallbackTitle: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(escape(language))" lang="\(escape(language))">
        <head>
          <meta charset="UTF-8"/>
          <title>\(escape(chapter.title ?? fallbackTitle))</title>
          <style>\(structuralCSS)</style>
        </head>
        <body>
        \(chapter.bodyXHTML)
        </body>
        </html>
        """
    }

    /// Стилі для розмітки, якої не буває у звичайному EPUB.
    ///
    /// Вірші, строфи, епіграфи й підписи приходять із FB2, і без цих правил
    /// поезія виглядає як низка звичайних абзаців: рядки розсунуті на повний
    /// міжабзацний відступ, вирівняні по ширині й з червоним рядком. Для
    /// формату, яким поширюють здебільшого художнє, це помітно зразу.
    ///
    /// `!important` обовʼязковий: Readium CSS задає виключку й відступи теж
    /// через нього, і без цього виграє вона.
    private static let structuralCSS = """
    .poem { margin: 1.1em 0; }
    .stanza { margin-bottom: 1em; }
    .stanza:last-child { margin-bottom: 0; }
    .verse {
      margin: 0 !important;
      line-height: 1.45;
    }
    /* Вирівнювання й червоний рядок тут не задаємо: Readium CSS нав'язує
       виключку користувача специфічнішим правилом, і клас йому програє.
       Це робить вбудований стиль — див. FB2Parser. */
    .epigraph {
      margin: 1.2em 0 1.4em 12%;
      font-style: italic;
      border: 0;
      padding: 0;
    }
    .cite { margin: 1.1em 0 1.1em 6%; }
    .text-author { font-style: italic; margin-top: 0.4em; }
    .subtitle { font-weight: 600; margin: 1.1em 0 0.7em; }
    .annotation { margin: 0 0 1.4em; font-style: italic; }
    .empty-line { margin: 0 !important; }
    .note { text-decoration: none; }
    .backref { font-size: 0.85em; margin: 0.3em 0 1em !important; }
    img { max-width: 100%; height: auto; }
    """

    private static func navXHTML(chapters: [Chapter], metadata: Metadata) -> String {
        let items = chapters.enumerated().map { index, chapter in
            let title = chapter.title ?? "Частина \(index + 1)"
            return "      <li><a href=\"chapter\(index + 1).xhtml\">\(escape(title))</a></li>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" \
        xml:lang="\(escape(metadata.language))" lang="\(escape(metadata.language))">
        <head>
          <meta charset="UTF-8"/>
          <title>\(escape(metadata.title))</title>
        </head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>Зміст</h1>
            <ol>
        \(items)
            </ol>
          </nav>
        </body>
        </html>
        """
    }

    private static func packageOPF(
        chapters: [Chapter],
        resources: [Resource],
        metadata: Metadata
    ) -> String {
        let chapterItems = (1 ... chapters.count).map {
            "    <item id=\"ch\($0)\" href=\"chapter\($0).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")

        let resourceItems = resources.enumerated().map { index, resource in
            let properties = resource.isCover ? " properties=\"cover-image\"" : ""
            return "    <item id=\"res\(index + 1)\" href=\"\(resource.path)\" "
                + "media-type=\"\(resource.mediaType)\"\(properties)/>"
        }.joined(separator: "\n")

        let spine = (1 ... chapters.count)
            .map { "    <itemref idref=\"ch\($0)\"/>" }
            .joined(separator: "\n")

        let authors = metadata.authors
            .map { "    <dc:creator>\(escape($0))</dc:creator>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" \
        unique-identifier="pub-id" xml:lang="\(escape(metadata.language))">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:chytach:\(metadata.identifier)</dc:identifier>
            <dc:title>\(escape(metadata.title))</dc:title>
        \(authors)
            <dc:language>\(escape(metadata.language))</dc:language>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(chapterItems)
        \(resourceItems)
          </manifest>
          <spine>
        \(spine)
          </spine>
        </package>
        """
    }

    // MARK: - Допоміжне

    /// Екранування для XML. Порядок важливий: амперсанд першим, інакше
    /// подвійно екрануються власні підстановки.
    /// Екранує текст для XHTML.
    ///
    /// Подвійну лапку теж, хоч у тексті сторінки вона й нешкідлива: той
    /// самий рядок може опинитися в атрибуті, а там лапка розриває значення
    /// й дає змогу дописати до тега що завгодно. Книга — чужий файл, і
    /// покладатися на те, що її метадані кудись не потраплять, не можна.
    ///
    /// Апостроф не чіпаємо навмисно: усі атрибути тут у подвійних лапках,
    /// тож розірвати значення він не може, а в українському тексті він у
    /// кожному другому слові — `&apos;` замість нього лише засмітив би
    /// розмітку.
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("ConvertedBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Ключ кешу з імені, розміру й дати зміни файлу. Змінився файл —
    /// зміниться ключ, і книга перезбереться.
    static func cacheKey(for url: URL, salt: String = "") -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let seed = "\(url.lastPathComponent)|\(size)|\(modified)|\(salt)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
