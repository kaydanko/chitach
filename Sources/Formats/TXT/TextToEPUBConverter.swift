import Foundation

/// Перетворює простий текст на EPUB.
///
/// Readium не має парсера TXT — його `DefaultPublicationParser` знає лише
/// EPUB, PDF, WebPub, зображення й аудіо. Тому текст доводиться підносити до
/// формату, який рушій розуміє. Пакування робить `EPUBBuilder`.
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
                String(localized: "Не вдалося визначити кодування файлу «\(name)». Спробуйте зберегти його в UTF-8.", bundle: AppLanguage.bundle)
            }
        }
    }

    /// Приблизний розмір одного розділу в символах.
    ///
    /// Потрібен, щоб великий текст не перетворювався на один XHTML-файл:
    /// Readium завантажує ресурс цілком, і книга на кілька мегабайтів зʼїдала б
    /// памʼять і гальмувала перепагінацію.
    static let charactersPerChapter = 60_000

    static func convert(fileURL: URL) throws -> URL {
        let (text, encoding) = try readText(at: fileURL)

        return try EPUBBuilder.build(
            metadata: .init(
                title: fileURL.deletingPathExtension().lastPathComponent,
                identifier: EPUBBuilder.cacheKey(for: fileURL, salt: "txt\(encoding.rawValue)")
            ),
            chapters: splitIntoChapters(text).map { paragraphs in
                EPUBBuilder.Chapter(
                    title: nil,
                    bodyXHTML: paragraphs
                        .map { "  <p>\(EPUBBuilder.escape($0))</p>" }
                        .joined(separator: "\n")
                )
            }
        )
    }

    // MARK: - Читання і кодування

    /// Визначає кодування й читає текст.
    ///
    /// Однобайтові кодування «успішно» декодують будь-які байти, тому самої
    /// спроби замало — результат треба оцінити. Рахуємо частку символів, які
    /// взагалі бувають у тексті; переможе та кодова таблиця, що дасть
    /// найменше сміття.
    static func readText(at url: URL) throws -> (String, String.Encoding) {
        // Відображення, а не копія — як у FB2: текст лише читається.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        if let bom = encodingFromBOM(data), let text = String(data: data, encoding: bom) {
            return (text, bom)
        }

        // UTF-8 перевіряється строго: невалідні послідовності її відкидають.
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }

        let koi8u = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.KOI8_U.rawValue)
        ))
        let candidates: [String.Encoding] = [.windowsCP1251, koi8u, .isoLatin1]

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
}
