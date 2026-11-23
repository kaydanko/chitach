import Compression
import Foundation

/// Дістає книгу FB2 з архіву `.fb2.zip`.
///
/// Бібліотеки віддають FB2 здебільшого саме так: XML добре стискається, і
/// книга важить уп'ятеро менше. Архів — це завжди одна книга, тож повний
/// розпакувальник не потрібен: досить знайти один запис і розгорнути його.
///
/// Власний розбір замість ZIP-читача Readium: той асинхронний і прив'язаний
/// до його ресурсів, а конвертер синхронний і має перевірятися окремо від
/// застосунку (`Scripts/test-fb2.sh`). Формат ZIP для одного запису простий,
/// а `Compression` уміє «сирий» deflate, яким ZIP і стискає.
enum FB2ZipExtractor {
    enum ExtractError: LocalizedError {
        case notZip
        case noBook
        case encrypted
        case unsupportedMethod(Int)
        case tooLarge
        case corrupted

        var errorDescription: String? {
            switch self {
            case .notZip: String(localized: "Файл не схожий на архів ZIP.", bundle: AppLanguage.bundle)
            case .noBook: String(localized: "В архіві немає файлу .fb2.", bundle: AppLanguage.bundle)
            case .encrypted: String(localized: "Архів зашифровано паролем.", bundle: AppLanguage.bundle)
            case let .unsupportedMethod(method): String(localized: "Архів стиснуто непідтримуваним способом (\(method)).", bundle: AppLanguage.bundle)
            case .tooLarge: String(localized: "Книга в архіві завелика.", bundle: AppLanguage.bundle)
            case .corrupted: String(localized: "Архів пошкоджено.", bundle: AppLanguage.bundle)
            }
        }
    }

    /// Межа розміру розпакованої книги. Розмір береться із заголовка архіву,
    /// тобто з чужих даних: без межі пошкоджений чи навмисне підроблений
    /// файл змусив би виділити гігабайти пам'яті й поклав би застосунок.
    /// Найбільші справжні FB2 з ілюстраціями — десятки мегабайтів.
    static let maxUncompressedSize = 256 * 1024 * 1024

    nonisolated static func handles(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".fb2.zip")
    }

    /// Вміст першого файлу `.fb2` в архіві.
    static func extractBook(from archive: Data) throws -> Data {
        let bytes = [UInt8](archive)
        let entries = try centralDirectory(bytes)

        // Службові записи macOS (`__MACOSX/._книга.fb2`) теж закінчуються на
        // .fb2, але це не книга, а розширені атрибути.
        guard let entry = entries.first(where: {
            let name = $0.name.lowercased()
            return name.hasSuffix(".fb2")
                && !name.hasPrefix("__macosx/")
                && !(name as NSString).lastPathComponent.hasPrefix("._")
        }) else {
            throw ExtractError.noBook
        }
        return try contents(of: entry, in: bytes)
    }

    // MARK: - Центральний каталог

    struct Entry {
        var name: String
        var method: Int
        var flags: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// Розміри беремо з центрального каталогу, а не з локального заголовка:
    /// архіватори, що пишуть потоком, ставлять у локальному нулі й додають
    /// дескриптор даних після запису.
    static func centralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        let eocdSize = 22
        guard bytes.count >= eocdSize else { throw ExtractError.notZip }

        // Кінцевий запис стоїть наприкінці, але за ним може бути коментар до
        // 64 КБ, тому шукаємо сигнатуру назад.
        let lowest = max(0, bytes.count - eocdSize - 0xFFFF)
        var eocd: Int?
        var position = bytes.count - eocdSize
        while position >= lowest {
            if u32(bytes, position) == 0x0605_4B50 { eocd = position; break }
            position -= 1
        }
        guard let eocd else { throw ExtractError.notZip }

        let count = u16(bytes, eocd + 10)
        var offset = Int(u32(bytes, eocd + 16))
        var entries: [Entry] = []

        for _ in 0 ..< count {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4B50 else {
                throw ExtractError.corrupted
            }
            let nameLength = u16(bytes, offset + 28)
            let extraLength = u16(bytes, offset + 30)
            let commentLength = u16(bytes, offset + 32)
            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else { throw ExtractError.corrupted }

            let flags = u16(bytes, offset + 8)
            let nameBytes = bytes[nameStart ..< nameStart + nameLength]
            // Біт 11 — імена в UTF-8. Без нього старі архіватори пишуть у
            // кодовій сторінці DOS; для пошуку розширення .fb2 вистачить і
            // латиниці, тож падати на кирилиці в імені не треба.
            let name = String(bytes: nameBytes, encoding: flags & 0x0800 != 0 ? .utf8 : .isoLatin1)
                ?? String(decoding: nameBytes, as: UTF8.self)

            entries.append(Entry(
                name: name,
                method: u16(bytes, offset + 10),
                flags: flags,
                compressedSize: Int(u32(bytes, offset + 20)),
                uncompressedSize: Int(u32(bytes, offset + 24)),
                localHeaderOffset: Int(u32(bytes, offset + 42))
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Вміст запису

    static func contents(of entry: Entry, in bytes: [UInt8]) throws -> Data {
        guard entry.flags & 0x0001 == 0 else { throw ExtractError.encrypted }
        guard entry.uncompressedSize <= maxUncompressedSize else { throw ExtractError.tooLarge }

        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, u32(bytes, header) == 0x0403_4B50 else {
            throw ExtractError.corrupted
        }
        let dataStart = header + 30 + u16(bytes, header + 26) + u16(bytes, header + 28)
        guard dataStart + entry.compressedSize <= bytes.count else { throw ExtractError.corrupted }
        let compressed = bytes[dataStart ..< dataStart + entry.compressedSize]

        switch entry.method {
        case 0:
            return Data(compressed)

        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = [UInt8](repeating: 0, count: entry.uncompressedSize)
            let written = compressed.withUnsafeBufferPointer { source in
                compression_decode_buffer(
                    &output, output.count,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB   // у Apple це сирий deflate, без обгортки zlib
                )
            }
            // Менше байтів, ніж обіцяв каталог, — архів обрізано. Віддати
            // половину книги мовчки гірше, ніж чесно відмовити.
            guard written == entry.uncompressedSize else { throw ExtractError.corrupted }
            return Data(output)

        default:
            throw ExtractError.unsupportedMethod(entry.method)
        }
    }

    // MARK: - Числа little-endian

    private static func u16(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 2 <= bytes.count else { return 0 }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
