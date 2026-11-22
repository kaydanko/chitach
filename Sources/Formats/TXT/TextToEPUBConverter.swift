import CryptoKit
import Foundation

/// Перетворює простий текст на мінімальний EPUB.
///
/// Readium не має парсера TXT — його `DefaultPublicationParser` знає лише
/// EPUB, PDF, WebPub, зображення й аудіо. Тому текст доводиться підносити до
/// формату, який рушій розуміє.
///
/// Результат — **розпакований** каталог EPUB, не ZIP. Readium відкриває його
/// через `DirectoryContainer`, тож архівувати немає потреби: економимо і час
/// конвертації, і місце.
enum TextToEPUBConverter {
    static let handledExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    static func handles(_ pathExtension: String) -> Bool {
        handledExtensions.contains(pathExtension.lowercased())
    }

    enum ConversionError: LocalizedError {
        case unreadableEncoding(String)

        var errorDescription: String? {
            switch self {
            case let .unreadableEncoding(name):
                "Не вдалося визначити кодування файлу «\(name)». Спробуйте зберегти його в UTF-8."
            }
        }
    }

    /// Приблизний розмір одного розділу в символах.
    ///
    /// Потрібен, щоб великий текст не перетворювався на один XHTML-файл:
    /// Readium завантажує ресурс цілком, і книга на кілька мегабайтів з'їдала б
    /// памʼять і гальмувала перепагінацію.
    private static let charactersPerChapter = 60_000

    // MARK: - Конвертація

    /// Повертає каталог готового EPUB. Повторні виклики для того самого файлу
    /// віддають кеш.
    static func convert(fileURL: URL) throws -> URL {
        let (text, encoding) = try readText(at: fileURL)
        let title = fileURL.deletingPathExtension().lastPathComponent

        let fingerprint = cacheKey(for: fileURL, encoding: encoding)
        let destination = cacheDirectory.appendingPathComponent(fingerprint, isDirectory: true)

        // Кеш: якщо вже конвертували цей файл, нічого не робимо.
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("EPUB/package.opf").path) {
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

        let chapters = splitIntoChapters(text)

        try write(mimetype(), to: destination.appendingPathComponent("mimetype"))
        try write(containerXML(), to: destination.appendingPathComponent("META-INF/container.xml"))

        for (index, paragraphs) in chapters.enumerated() {
            try write(
                chapterXHTML(paragraphs: paragraphs, title: title),
                to: destination.appendingPathComponent("EPUB/chapter\(index + 1).xhtml")
            )
        }

        try write(
            navXHTML(chapterCount: chapters.count, title: title),
            to: destination.appendingPathComponent("EPUB/nav.xhtml")
        )
        try write(
            packageOPF(chapterCount: chapters.count, title: title, identifier: fingerprint),
            to: destination.appendingPathComponent("EPUB/package.opf")
        )

        return destination
    }

    // MARK: - Читання і кодування

    /// Визначає кодування й читає текст.
    ///
    /// Однобайтові кодування «успішно» декодують будь-які байти, тому самої
    /// спроби замало — результат треба оцінити. Рахуємо частку символів, які
    /// взагалі бувають у тексті; переможе та кодова таблиця, що дасть найменше
    /// сміття.
    static func readText(at url: URL) throws -> (String, String.Encoding) {
        let data = try Data(contentsOf: url)

        // BOM має пріоритет: він однозначний.
        if let bom = encodingFromBOM(data) {
            if let text = String(data: data, encoding: bom) {
                return (text, bom)
            }
        }

        // UTF-8 перевіряємо строго: невалідні послідовності її відкидають.
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }

        let candidates: [String.Encoding] = [
            .windowsCP1251,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.KOI8_U.rawValue)
            )),
            .isoLatin1,
        ]

        var best: (text: String, encoding: String.Encoding, score: Double)?
        for encoding in candidates {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let score = plausibility(of: text)
            if best == nil || score > best!.score {
                best = (text, encoding, score)
            }
        }

        if let best, best.score > 0.9 {
            return (best.text, best.encoding)
        }
        throw ConversionError.unreadableEncoding(url.lastPathComponent)
    }

    private static func encodingFromBOM(_ data: Data) -> String.Encoding? {
        guard data.count >= 2 else { return nil }
        let b = [UInt8](data.prefix(3))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return .utf8 }
        if b[0] == 0xFF, b[1] == 0xFE { return .utf16LittleEndian }
        if b[0] == 0xFE, b[1] == 0xFF { return .utf16BigEndian }
        return nil
    }

    /// Частка «нормальних» символів: букви, цифри, пробіли, пунктуація.
    private static func plausibility(of text: String) -> Double {
        let sample = text.prefix(4000)
        guard !sample.isEmpty else { return 0 }
        var good = 0
        for scalar in sample.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
            {
                good += 1
            }
        }
        return Double(good) / Double(sample.unicodeScalars.count)
    }

    // MARK: - Розбиття

    /// Рядок = абзац.
    ///
    /// Саме так показує такі файли FBReader: рядки з розміткою
    /// («# Заголовок», «*курсив*») лишаються окремими абзацами, а не
    /// склеюються. Розмітку не інтерпретуємо — це простий текст.
    static func splitIntoChapters(_ text: String) -> [[String]] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let paragraphs = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else { return [[""]] }

        var chapters: [[String]] = []
        var current: [String] = []
        var size = 0

        for paragraph in paragraphs {
            current.append(paragraph)
            size += paragraph.count
            if size >= charactersPerChapter {
                chapters.append(current)
                current = []
                size = 0
            }
        }
        if !current.isEmpty { chapters.append(current) }
        return chapters
    }

    // MARK: - Шаблони EPUB

    private static func mimetype() -> String { "application/epub+zip" }

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

    private static func chapterXHTML(paragraphs: [String], title: String) -> String {
        let body = paragraphs
            .map { "  <p>\(escape($0))</p>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="uk" lang="uk">
        <head>
          <meta charset="UTF-8"/>
          <title>\(escape(title))</title>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func navXHTML(chapterCount: Int, title: String) -> String {
        let items = (1 ... max(chapterCount, 1))
            .map { "      <li><a href=\"chapter\($0).xhtml\">Частина \($0)</a></li>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="uk" lang="uk">
        <head>
          <meta charset="UTF-8"/>
          <title>\(escape(title))</title>
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

    private static func packageOPF(chapterCount: Int, title: String, identifier: String) -> String {
        let manifest = (1 ... max(chapterCount, 1))
            .map { "    <item id=\"ch\($0)\" href=\"chapter\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }
            .joined(separator: "\n")
        let spine = (1 ... max(chapterCount, 1))
            .map { "    <itemref idref=\"ch\($0)\"/>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="uk">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:chytach:\(identifier)</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:language>uk</dc:language>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(manifest)
          </manifest>
          <spine>
        \(spine)
          </spine>
        </package>
        """
    }

    /// Екранування для XML. Порядок важливий: амперсанд першим, інакше
    /// подвійно екрануються власні підстановки.
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Кеш

    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("ConvertedBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Ключ кешу — хеш вмісту плюс кодування. Змінився файл — зміниться ключ.
    private static func cacheKey(for url: URL, encoding: String.Encoding) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let seed = "\(url.lastPathComponent)|\(size)|\(modified)|\(encoding.rawValue)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
