import Foundation
import ReadiumShared

/// Книга в бібліотеці.
struct LibraryBook: Identifiable, Hashable {
    var url: URL
    var title: String
    var author: String?
    /// Розширення великими літерами — «EPUB», «FB2». Показуємо його, бо від
    /// формату залежить, чого чекати: у TXT не буде ні змісту, ні картинок.
    var format: String
    var addedAt: Date
    var lastOpenedAt: Date?
    /// Частка прочитаного, 0…1. `nil` — книгу ще не відкривали.
    var progress: Double?

    var id: String { url.lastPathComponent }

    var isStarted: Bool { (progress ?? 0) > 0.001 }
}

/// Облік книг, доданих у застосунок.
///
/// Окремої бази даних немає й поки не треба: книги фізично лежать у теці
/// `Documents/Books`, куди їх кладе ``BookImportService``. Отже сам перелік —
/// це вміст теки, і він не може розійтися з дійсністю. У налаштуваннях
/// тримаємо лише те, чого з файлу не видно: справжню назву з метаданих,
/// автора й коли книгу востаннє відкривали.
///
/// Назву з`ясовуємо не наперед, а при першому відкритті: щоб дізнатися її
/// заздалегідь, довелося б розібрати кожну книгу в теці — для FB2 чи RTF це
/// повна конвертація. Доти в переліку стоїть ім`я файлу.
enum LibraryStore {
    private static let metadataKey = "libraryMetadata"

    private struct Entry: Codable {
        var title: String?
        var author: String?
        var lastOpenedAt: Date?
    }

    // MARK: - Перелік

    static func books() -> [LibraryBook] {
        let directory = BookImportService.booksDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let metadata = storedMetadata()

        return contents
            .filter { BookImportService.canOpen($0) }
            .map { url in
                let entry = metadata[url.lastPathComponent]
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)

                return LibraryBook(
                    url: url,
                    title: entry?.title ?? displayName(of: url),
                    author: entry?.author,
                    // Для `книга.fb2.zip` розширення — `zip`, але показувати
                    // треба те, що всередині: читача цікавить формат книги.
                    format: FB2ZipExtractor.handles(url) ? "FB2" : url.pathExtension.uppercased(),
                    addedAt: created ?? .distantPast,
                    lastOpenedAt: entry?.lastOpenedAt,
                    progress: ReadingPositionStore.locator(for: url)?.locations.totalProgression
                )
            }
            // Нещодавно читане — вгорі: саме до нього найчастіше вертаються.
            // Далі нещодавно додане.
            .sorted { left, right in
                switch (left.lastOpenedAt, right.lastOpenedAt) {
                case let (l?, r?): l > r
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): left.addedAt > right.addedAt
                }
            }
    }

    /// Ім`я файлу без розширень: `нотатки.txt` → `нотатки`,
    /// `книга.fb2.zip` → `книга`. Стоїть у переліку доти, доки книгу не
    /// відкрили бодай раз і не стала відома справжня назва.
    private static func displayName(of url: URL) -> String {
        let base = url.deletingPathExtension()
        // Подвійне розширення: знявши `.zip`, натрапляємо ще на `.fb2`.
        return supportedExtensions.contains(base.pathExtension.lowercased())
            ? base.deletingPathExtension().lastPathComponent
            : base.lastPathComponent
    }

    private static var supportedExtensions: Set<String> {
        BookImportService.supportedExtensions
    }

    // MARK: - Облік

    /// Запам`ятовує назву й автора, щойно книгу вдалося розібрати.
    static func remember(_ publication: Publication, for url: URL) {
        var metadata = storedMetadata()
        var entry = metadata[url.lastPathComponent] ?? Entry()

        let title = publication.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { entry.title = title }

        let authors = publication.metadata.authors
            .map(\.name)
            .filter { !$0.isEmpty }
        if !authors.isEmpty { entry.author = authors.joined(separator: ", ") }

        entry.lastOpenedAt = Date()
        metadata[url.lastPathComponent] = entry
        store(metadata)
    }

    // MARK: - Дублікати

    /// Книги, що повторюються, без тієї копії, яку варто лишити.
    ///
    /// Потрібно для бібліотек, зібраних до того, як повторне додавання
    /// почало впізнаватися: там та сама книга лежить по п`ять разів із
    /// номерами в назві.
    ///
    /// Лишаємо копію з найбільшим поступом читання — саме її людина й
    /// читала. За рівного поступу перемагає коротша назва: `Епістемій`
    /// проти `Епістемій 4` — це оригінал проти випадкової копії.
    static func redundantCopies() -> [LibraryBook] {
        // Спершу за розміром, і лише всередині збігів — за відбитком.
        //
        // Рахувати відбиток кожної книги означало б прочитати всю бібліотеку
        // цілком щоразу, коли її відкривають. Розмір береться з метаданих
        // миттєво, а різний розмір уже доводить, що книги різні.
        var bySize: [Int: [LibraryBook]] = [:]
        for book in books() {
            guard let size = BookImportService.fileSize(of: book.url) else { continue }
            bySize[size, default: []].append(book)
        }

        var groups: [String: [LibraryBook]] = [:]
        for sameSize in bySize.values where sameSize.count > 1 {
            for book in sameSize {
                guard let digest = BookImportService.digest(of: book.url) else { continue }
                groups[digest, default: []].append(book)
            }
        }

        return groups.values
            .filter { $0.count > 1 }
            .flatMap { group -> [LibraryBook] in
                let sorted = group.sorted { left, right in
                    let l = left.progress ?? 0
                    let r = right.progress ?? 0
                    if l != r { return l > r }
                    return left.url.lastPathComponent.count < right.url.lastPathComponent.count
                }
                return Array(sorted.dropFirst())
            }
    }

    /// Прибирає зайві копії. Повертає скільки книг вилучено.
    @discardableResult
    static func removeDuplicates() -> Int {
        var removed = 0
        for copy in redundantCopies() where (try? remove(copy)) != nil {
            removed += 1
        }
        return removed
    }

    /// Прибирає книгу: сам файл, місце читання й запис про неї.
    static func remove(_ book: LibraryBook) throws {
        try FileManager.default.removeItem(at: book.url)
        ReadingPositionStore.forget(book.url)

        var metadata = storedMetadata()
        metadata.removeValue(forKey: book.id)
        store(metadata)
    }

    // MARK: - Сховище

    private static func storedMetadata() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func store(_ metadata: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}
