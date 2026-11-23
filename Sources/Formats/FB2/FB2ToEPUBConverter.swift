import Foundation

/// Перетворює FB2 на EPUB.
///
/// Сам розбір — у ``FB2Parser``; тут лишається спакувати результат. Шлях
/// через EPUB обрано свідомо, замість власного `PublicationParser` для
/// Readium: TXT і RTF уже стоять на ``EPUBBuilder``, результат кешується на
/// диску, а далі книгу веде той самий перевірений шлях Readium, що й
/// справжній EPUB, — із пагінацією, змістом і пошуком.
enum FB2ToEPUBConverter {
    static let handledExtensions: Set<String> = ["fb2"]

    /// За повним URL, а не лише розширенням: у `книга.fb2.zip` розширення —
    /// `zip`, і за ним самим FB2 не відрізнити від будь-якого архіву.
    static func handles(_ url: URL) -> Bool {
        handledExtensions.contains(url.pathExtension.lowercased()) || FB2ZipExtractor.handles(url)
    }

    static func convert(fileURL: URL) throws -> URL {
        // Кеш перевіряємо до розбору: друге відкриття не має витрачати час
        // на розпакування й XML, якщо EPUB уже зібрано.
        let identifier = EPUBBuilder.cacheKey(for: fileURL, salt: cacheSalt)
        if let cached = EPUBBuilder.cachedBook(identifier: identifier) {
            return cached
        }

        // Відображення файлу, а не копія: на час розбору книга не займає
        // власної памʼяті процесу, і система може скинути сторінки, щойно
        // вони прочитані.
        var data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        if FB2ZipExtractor.handles(fileURL) {
            data = try FB2ZipExtractor.extractBook(from: data)
        }
        let document = try FB2Parser.parse(data: data)

        // Якщо книга не назвала себе сама, беремо імʼя файлу: показувати в
        // шапці порожнечу гірше, ніж назву файлу.
        let title = document.title.isEmpty ? displayName(of: fileURL) : document.title

        return try EPUBBuilder.build(
            metadata: .init(
                title: title,
                authors: document.authors,
                language: document.language,
                identifier: identifier
            ),
            chapters: document.chapters,
            resources: document.images
        )
    }

    /// Змінюється разом із розміткою, яку видає розбірник. Інакше вже
    /// зібрані книги лишилися б у кеші в старому вигляді.
    static let cacheSalt = "fb2-v2"

    /// `книга.fb2.zip` → `книга`.
    static func displayName(of url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".zip", ".fb2"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }
}
