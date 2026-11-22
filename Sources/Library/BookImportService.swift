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
                "Немає доступу до файлу \(url.lastPathComponent)."
            case let .unreadableDrop(types):
                """
                Не вдалося прочитати перетягнутий файл.
                Система віддала: \(types.isEmpty ? "нічого" : types.joined(separator: ", "))
                """
            case let .unsupportedFormat(ext):
                """
                Формат «\(ext)» поки не підтримується.
                Зараз відкриваються EPUB, TXT, Markdown, RTF, PDF і CBZ.
                FB2 буде в наступному етапі.
                """
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
        "rtf", "rtfd",
    ]

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
        guard supportedExtensions.contains(ext) else {
            throw ImportError.unsupportedFormat(ext.isEmpty ? "без розширення" : ext)
        }

        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

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

    /// Не перезаписуємо наявні книги: до імені додається номер.
    private static func uniqueDestination(for filename: String) -> URL {
        let directory = booksDirectory
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

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
        for ext in ["cbz", "md", "markdown", "rtfd"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}
