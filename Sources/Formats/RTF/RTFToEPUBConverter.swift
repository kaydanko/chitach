import Foundation
import UIKit

/// Перетворює RTF на EPUB зі збереженням накреслень, вирівнювання й
/// вбудованих зображень.
///
/// Текст розбирає система: `NSAttributedString` уміє читати RTF і сам
/// розвʼязує питання кодування — RTF несе назву кодової таблиці всередині
/// себе, тож кирилиця з Windows-1251 розкодовується правильно без наших
/// здогадок.
///
/// А от назад — експорт `NSAttributedString` у HTML — на iOS не підтримується:
/// `DocumentType.html` придатний лише для читання. Тому XHTML збираємо самі,
/// обходячи ділянки атрибутів. Так результат ще й передбачуваний: ми точно
/// знаємо, які теги вийдуть, і не тягнемо в книгу чужу розмітку зі стилями.
///
/// Картинки з плоского RTF система теж не віддає (див.
/// ``RTFPictureExtractor``), тому перед розбором підміняємо групи `\pict`
/// текстовими мітками. У RTFD картинки приходять нормальними вкладеннями.
enum RTFToEPUBConverter {
    static let handledExtensions: Set<String> = ["rtf", "rtfd"]

    static func handles(_ pathExtension: String) -> Bool {
        handledExtensions.contains(pathExtension.lowercased())
    }

    enum ConversionError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name):
                String(localized: "Не вдалося прочитати файл «\(name)». Можливо, він пошкоджений.", bundle: AppLanguage.bundle)
            }
        }
    }

    /// Приблизний розмір розділу в символах — щоб велика книга не ставала
    /// одним ресурсом, який Readium вантажить цілком.
    static let charactersPerChapter = 60_000

    static func convert(fileURL: URL) throws -> URL {
        let document = try read(fileURL)
        let assembly = Assembly(pictures: document.pictures)
        let paragraphs = assembly.paragraphs(from: document.text)

        return try EPUBBuilder.build(
            metadata: .init(
                title: fileURL.deletingPathExtension().lastPathComponent,
                identifier: EPUBBuilder.cacheKey(for: fileURL, salt: "rtf")
            ),
            chapters: chunk(paragraphs).map {
                EPUBBuilder.Chapter(title: nil, bodyXHTML: $0.joined(separator: "\n"))
            },
            resources: assembly.images
        )
    }

    // MARK: - Читання

    struct Document {
        var text: NSAttributedString
        var pictures: [Data]
    }

    static func read(_ url: URL) throws -> Document {
        do {
            // RTFD — це бандл: картинки там окремими файлами, і система
            // віддає їх як вкладення. Підміна міток тут ні до чого.
            if url.pathExtension.lowercased() == "rtfd" {
                return Document(
                    text: try NSAttributedString(
                        url: url,
                        options: [.documentType: NSAttributedString.DocumentType.rtfd],
                        documentAttributes: nil
                    ),
                    pictures: []
                )
            }

            let extracted = RTFPictureExtractor.extract(from: try Data(contentsOf: url))
            return Document(
                text: try NSAttributedString(
                    data: extracted.data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                ),
                pictures: extracted.pictures
            )
        } catch {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
    }

    // MARK: - Розбиття на розділи

    static func chunk(_ paragraphs: [String]) -> [[String]] {
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
        return chapters.isEmpty ? [["<p></p>"]] : chapters
    }
}

// MARK: - Збирання XHTML

/// Накопичує розмітку й ресурси за один обхід тексту.
///
/// Клас, а не набір функцій з `inout`: замикання `enumerateAttributes` і
/// `enumerateSubstrings` escaping, а `inout`-параметр у таке не захопити.
private final class Assembly {
    private let pictures: [Data]

    /// Зіставлення «номер картинки → шлях у книзі»: та сама картинка в RTF
    /// може стояти кілька разів, і другий раз файл писати не треба.
    private var paths: [Int: String] = [:]
    private(set) var images: [EPUBBuilder.Resource] = []

    init(pictures: [Data]) {
        self.pictures = pictures
    }

    /// Розбиває текст на абзаци й перетворює кожен на `<p>`.
    func paragraphs(from attributed: NSAttributedString) -> [String] {
        let full = attributed.string as NSString
        var ranges: [NSRange] = []

        full.enumerateSubstrings(
            in: NSRange(location: 0, length: full.length),
            options: [.byParagraphs]
        ) { _, range, _, _ in
            ranges.append(range)
        }

        var result: [String] = []
        for range in ranges {
            if let html = paragraph(attributed.attributedSubstring(from: range)) {
                result.append(html)
            }
        }

        return result.isEmpty ? ["<p></p>"] : result
    }

    private func paragraph(_ paragraph: NSAttributedString) -> String? {
        var runs: [(attributes: [NSAttributedString.Key: Any], range: NSRange)] = []
        paragraph.enumerateAttributes(
            in: NSRange(location: 0, length: paragraph.length),
            options: []
        ) { attributes, range, _ in
            runs.append((attributes, range))
        }

        var inner = ""
        for run in runs {
            if let attachment = run.attributes[.attachment] as? NSTextAttachment {
                inner += tag(for: attachment) ?? ""
                continue
            }

            // U+FFFC — заповнювач на місці вкладення. Якщо ділянка лишилася
            // без самого вкладення, символ видно як порожній прямокутник.
            let text = (paragraph.string as NSString).substring(with: run.range)
            let cleaned = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !cleaned.isEmpty else { continue }

            inner += wrap(EPUBBuilder.escape(cleaned), traits: run.attributes)
        }

        inner = RTFPictureExtractor.replacingMarkers(in: inner) { [weak self] index in
            self?.tag(forPicture: index)
        }

        let collapsed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }

        return "  <p\(alignmentStyle(of: paragraph))>\(collapsed)</p>"
    }

    /// Накреслення читаємо з дескриптора шрифту, а не з його назви: назви в
    /// RTF бувають будь-які, а символьні риси стандартні.
    private func wrap(_ escaped: String, traits attributes: [NSAttributedString.Key: Any]) -> String {
        var html = escaped

        if let font = attributes[.font] as? UIFont {
            let symbolic = font.fontDescriptor.symbolicTraits
            if symbolic.contains(.traitItalic) { html = "<em>\(html)</em>" }
            if symbolic.contains(.traitBold) { html = "<strong>\(html)</strong>" }
        }

        if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
            html = "<u>\(html)</u>"
        }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
            html = "<s>\(html)</s>"
        }

        return html
    }

    /// Вирівнювання переносимо лише тоді, коли воно відрізняється від
    /// звичайного: у читалки є власні налаштування виключки, і не варто їх
    /// перебивати на кожному абзаці.
    ///
    /// `!important` обовʼязковий. Readium CSS задає виключку теж через
    /// `!important`, і без цього заголовок, який автор поставив посередині,
    /// розтягнеться по ширині разом з усім іншим. Обидва правила авторські,
    /// тож перемагає те, що специфічніше, — вбудоване.
    private func alignmentStyle(of paragraph: NSAttributedString) -> String {
        guard paragraph.length > 0,
              let style = paragraph.attribute(
                  .paragraphStyle,
                  at: 0,
                  effectiveRange: nil
              ) as? NSParagraphStyle
        else { return "" }

        return switch style.alignment {
        case .center: " style=\"text-align:center !important\""
        case .right: " style=\"text-align:right !important\""
        default: ""
        }
    }

    // MARK: Картинки

    /// Картинка з RTFD: байти приходять у самому вкладенні.
    private func tag(for attachment: NSTextAttachment) -> String? {
        var payload: Data?
        if let contents = attachment.contents, !contents.isEmpty {
            payload = contents
        } else if let wrapped = attachment.fileWrapper?.regularFileContents, !wrapped.isEmpty {
            payload = wrapped
        } else if let image = attachment.image {
            payload = image.pngData()
        }

        guard let payload, let (data, ext, mediaType) = Self.webSafe(payload) else { return nil }
        return tag(registering: data, ext: ext, mediaType: mediaType)
    }

    /// Картинка з плоского RTF: байти вже витягнуті розбірником.
    private func tag(forPicture index: Int) -> String? {
        if let path = paths[index] { return Self.imageTag(path) }

        guard pictures.indices.contains(index),
              let (data, ext, mediaType) = Self.webSafe(pictures[index])
        else { return nil }

        let path = "images/\(images.count + 1).\(ext)"
        paths[index] = path
        images.append(.init(path: path, data: data, mediaType: mediaType))
        return Self.imageTag(path)
    }

    private func tag(registering data: Data, ext: String, mediaType: String) -> String {
        let path = "images/\(images.count + 1).\(ext)"
        images.append(.init(path: path, data: data, mediaType: mediaType))
        return Self.imageTag(path)
    }

    /// Межа ширини потрібна тому, що в RTF картинка несе розмір у пунктах
    /// паперового аркуша. На вужчій колонці вона інакше вилізе за край і
    /// поламає розбиття на сторінки.
    private static func imageTag(_ path: String) -> String {
        "<img src=\"\(path)\" alt=\"\" style=\"max-width:100%;height:auto\"/>"
    }

    /// Приводить картинку до формату, який EPUB дозволяє.
    ///
    /// Тип визначаємо за сигнатурою файлу: ні назви, ні розширення в
    /// картинки з RTF немає. Якщо формат не з дозволених — а RTF любить
    /// вкладати TIFF, WMF та EMF, — перемальовуємо в PNG. Інакше читалка
    /// покаже порожнє місце: рушій EPUB зобовʼязаний знати лише GIF, JPEG,
    /// PNG і SVG.
    private static func webSafe(_ data: Data) -> (Data, String, String)? {
        let bytes = [UInt8](data.prefix(8))

        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return (data, "jpg", "image/jpeg")
        }
        if bytes.count >= 8,
           Array(bytes[0 ..< 8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return (data, "png", "image/png")
        }
        if bytes.count >= 3, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return (data, "gif", "image/gif")
        }

        guard let image = UIImage(data: data), let png = image.pngData() else { return nil }
        return (png, "png", "image/png")
    }
}
