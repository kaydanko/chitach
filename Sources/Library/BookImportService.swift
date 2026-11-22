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

        var errorDescription: String? {
            switch self {
            case let .accessDenied(url):
                "Немає доступу до файлу \(url.lastPathComponent)."
            case let .unsupportedFormat(ext):
                """
                Формат «\(ext)» поки не підтримується.
                Зараз відкриваються EPUB, TXT, MD, PDF і CBZ.
                FB2, RTF і MOBI будуть у наступних етапах.
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
        // Конвертуємо ми (TextToEPUBConverter).
        "txt", "text", "md", "markdown",
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
        for ext in ["cbz", "md", "markdown"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}
