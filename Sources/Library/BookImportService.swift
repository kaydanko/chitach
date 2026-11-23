import CryptoKit
import Foundation
import ReadiumShared
import UniformTypeIdentifiers

/// Імпорт книг із файлової системи.
///
/// Поки без бази даних — вона зʼявиться у Фазі 2. Завдання цього сервісу
/// мінімальне: забрати файл, на який користувач має тимчасовий доступ, і
/// покласти його туди, звідки застосунок зможе читати його будь-коли.
enum BookImportService {
    enum ImportError: LocalizedError {
        case accessDenied(URL)
        case unsupportedFormat(String)
        /// Перетягнули щось, із чого не вдалося дістати файл.
        ///
        /// Разом із переліком типів: якщо таке колись станеться, по ньому
        /// одразу видно, що саме віддала система, — без цього довелося б
        /// гадати втретє поспіль.
        case unreadableDrop([String])

        var errorDescription: String? {
            switch self {
            case let .accessDenied(url):
                String(localized: "Немає доступу до файлу \(url.lastPathComponent).", bundle: AppLanguage.bundle)
            case let .unreadableDrop(types):
                String(localized: """
                Не вдалося прочитати перетягнутий файл.
                Система віддала: \(types.isEmpty ? String(localized: "нічого", bundle: AppLanguage.bundle) : types.joined(separator: ", "))
                """, bundle: AppLanguage.bundle)
            case let .unsupportedFormat(ext):
                String(localized: """
                Формат «\(ext)» поки не підтримується.
                Зараз відкриваються EPUB, FB2, TXT, Markdown, RTF, PDF і CBZ.
                """, bundle: AppLanguage.bundle)
            }
        }
    }

    /// Формати, які Readium `DefaultPublicationParser` розбирає сьогодні.
    ///
    /// Список навмисно консервативний: краще чесно відмовити одразу, ніж
    /// показати порожній екран після спроби відкрити FB2.
    static let supportedExtensions: Set<String> = [
        // Readium розбирає сам.
        "epub", "pdf", "cbz", "webpub", "audiobook", "lcpa", "lcpdf", "divina",
        // Конвертуємо ми.
        "txt", "text", "md", "markdown",
        "rtf", "rtfd", "fb2",
    ]

    /// Чи вміє застосунок відкрити цей файл.
    ///
    /// Одне правило на всіх, бо перевіряти доводиться у двох місцях — при
    /// імпорті й при складанні переліку бібліотеки, — і вони вже встигли
    /// розійтися: `книга.fb2.zip` імпортувалася, але в переліку не
    /// показувалася, бо розширення там `zip`.
    static func canOpen(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
            || FB2ZipExtractor.handles(url)
    }

    /// Тека з імпортованими книгами всередині контейнера застосунку.
    static var booksDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let books = documents.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        return books
    }

    /// Копіює файл у контейнер і повертає URL копії.
    ///
    /// Копіювати, а не читати на місці, обовʼязково: і document picker, і
    /// drag-and-drop дають лише тимчасовий доступ у межах
    /// security-scoped-сесії. Після її завершення оригінальний URL стає
    /// недійсним, і книга «зникає» при наступному запуску.
    static func importBook(from source: URL) throws -> URL {
        let ext = source.pathExtension.lowercased()
        // Довільний ZIP не приймаємо: за розширенням не видно, що всередині.
        // `.fb2.zip` — усталена назва, під якою бібліотеки віддають FB2.
        guard canOpen(source) else {
            throw ImportError.unsupportedFormat(ext.isEmpty ? String(localized: "без розширення", bundle: AppLanguage.bundle) : ext)
        }

        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

        // Ту саму книгу часто додають удруге — перетягнули ще раз, бо не
        // помітили, що вона вже є. Друга копія не просто засмічує перелік:
        // вона приходить із власним, нульовим місцем читання, і книга
        // «забуває», де її залишили. Тому повертаємо ту, що вже є.
        if let existing = existingBook(matching: source) {
            return existing
        }

        let destination = uniqueDestination(for: source.lastPathComponent)

        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            // Якщо копіювання не вдалося саме через доступ — повідомляємо
            // зрозуміло, а не кодом помилки файлової системи.
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw ImportError.accessDenied(source)
            }
            throw error
        }

        return destination
    }

    /// Забирає книгу з перетягування.
    ///
    /// Порядок спроб не випадковий.
    ///
    /// Спершу URL: він дає і доступ, і правильне імʼя файлу. Файлове
    /// подання імені не зберігає — система називає тимчасову копію за
    /// описом типу, і книга лягла б у бібліотеку як «EPUB publication».
    ///
    /// Якщо URL недоступний — а саме так буває, коли файл приходить з
    /// іншого застосунку або з-під обмеженого доступу, — беремо файлове
    /// подання: система готує тимчасову копію незалежно від того, чи віддає
    /// вона URL. Саме цього бракувало раніше: код питав лише URL і, не
    /// діставши його, не робив більше нічого. Копія живе, доки триває
    /// зворотний виклик, тому переносимо її в бібліотеку прямо всередині.
    static func importBook(from provider: NSItemProvider) async throws -> URL {
        if let source = await loadURL(from: provider),
           FileManager.default.isReadableFile(atPath: source.path)
        {
            return try importBook(from: source)
        }

        guard provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) else {
            throw ImportError.unreadableDrop(provider.registeredTypeIdentifiers)
        }
        return try await importFileRepresentation(from: provider)
    }

    private static func importFileRepresentation(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.item.identifier
            ) { url, error in
                guard let url else {
                    continuation.resume(
                        throwing: error
                            ?? ImportError.unreadableDrop(provider.registeredTypeIdentifiers)
                    )
                    return
                }
                do {
                    continuation.resume(returning: try importBook(from: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// Книга з таким самим вмістом, якщо вона вже в бібліотеці.
    ///
    /// Порівнюємо вміст, а не імена: той самий файл легко завантажити під
    /// назвами `Intermezzo.epub` і `Intermezzo (1).epub`, і за іменами це
    /// були б різні книги.
    ///
    /// Спершу розмір, і лише для збігів — відбиток. Розмір читається з
    /// метаданих файлу миттєво, тож на бібліотеці в сотні книг рахувати
    /// доведеться хіба кілька відбитків замість усіх.
    private static func existingBook(matching source: URL) -> URL? {
        guard let size = fileSize(of: source), let sourceDigest = digest(of: source) else {
            return nil
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: booksDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.first { candidate in
            fileSize(of: candidate) == size && digest(of: candidate) == sourceDigest
        }
    }

    static func fileSize(of url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        // Бандл (`.rtfd`) розміру не має — такі не звіряємо, тільки
        // копіюємо. Трапляються вони рідко, а обходити теку заради
        // порівняння не варто.
        guard values?.isDirectory != true else { return nil }
        return values?.fileSize
    }

    /// Відбиток вмісту, порціями: книга може важити сотні мегабайтів, і
    /// читати її в пам`ять цілком заради порівняння не треба.
    static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Не перезаписуємо наявні книги: до імені додається номер.
    private static func uniqueDestination(for filename: String) -> URL {
        let directory = booksDirectory
        var base = (filename as NSString).deletingPathExtension
        var ext = (filename as NSString).pathExtension
        // Подвійне розширення тримаємо цілим: «книга.fb2 2.zip» уже не
        // впізнається як FB2 в архіві, а «книга 2.fb2.zip» — так.
        if filename.lowercased().hasSuffix(".fb2.zip") {
            base = String(filename.dropLast(".fb2.zip".count))
            ext = String(filename.suffix("fb2.zip".count))
        }

        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Типи для системного вибору файлів.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.epub, .plainText, .pdf]
        types.append(.rtf)
        for ext in ["cbz", "md", "markdown", "rtfd", "fb2"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        // Без цього `.fb2.zip` у виборі файлів сірий. Ширше, ніж треба, —
        // видно буде й інші архіви, — але чужий ZIP імпорт чесно відхилить.
        types.append(.zip)
        return types
    }
}
