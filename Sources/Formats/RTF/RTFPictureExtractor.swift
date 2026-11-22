import Foundation

/// Витягує картинки з плоского RTF.
///
/// Потрібен тому, що системний читач RTF картинки просто втрачає: групи
/// `\pict` він не розбирає, і `NSAttributedString` повертає текст зовсім без
/// вкладень. Перевірено на `\pngblip`, `\jpegblip`, `\dibitmap` і `\wbitmap`
/// — результат однаковий; та сама Cocoa при записі плоского RTF картинку теж
/// не зберігає. Вона виживає лише в RTFD, де лежить окремим файлом у бандлі,
/// — там вкладення приходять нормально, і цей розбірник не потрібен.
///
/// Замість власного розбору всього RTF робимо мінімальну підміну: знаходимо
/// групи з картинками, забираємо з них байти, а на місце групи ставимо
/// текстову мітку. Далі текст, як і раніше, розбирає система — отже
/// кодування, стилі й межі абзаців лишаються її клопотом, а мітка опиняється
/// точно там, де була картинка.
enum RTFPictureExtractor {
    struct Result {
        var data: Data
        var pictures: [Data]
    }

    /// Мітка, якою підміняємо картинку.
    ///
    /// Звичайні ASCII-символи RTF віддає в текст без змін, тож до нас мітка
    /// доходить незайманою. Якщо ж картинка стоїть у групі, яку читач
    /// пропускає, мітка зникне разом із нею — тоді картинки просто не буде,
    /// без зіпсованої розмітки.
    static func marker(_ index: Int) -> String { "[[chytach-image-\(index)]]" }

    private static let markerPrefix = "[[chytach-image-"
    private static let markerSuffix = "]]"

    // MARK: - Розбір

    private enum Destination {
        case picture        // \pict або \*\shppict — беремо
        case fallback       // \nonshppict — дублікат попередньої картинки
    }

    static func extract(from data: Data) -> Result {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        var pictures: [Data] = []
        var i = 0
        // Word пише картинку двічі: `{\*\shppict{\pict…}}` для нових читачів і
        // `{\nonshppict{\pict…}}` для старих. Другу копію треба відкинути —
        // але лише тоді, коли перша справді щойно була.
        var previousWasPicture = false

        while i < bytes.count {
            let byte = bytes[i]

            // Екранований символ: копіюємо разом із похилою рискою, щоб
            // `\{` і `\}` не збили підрахунок дужок.
            if byte == .backslash, i + 1 < bytes.count, !bytes[i + 1].isASCIILetter {
                out.append(byte)
                out.append(bytes[i + 1])
                i += 2
                previousWasPicture = false
                continue
            }

            if byte == .openBrace, let destination = destination(at: i, in: bytes) {
                let end = groupEnd(from: i, in: bytes)

                switch destination {
                case .fallback where previousWasPicture:
                    break               // дублікат — викидаємо цілком

                case .picture, .fallback:
                    if let picture = payload(in: bytes, range: (i + 1) ..< (end - 1)) {
                        out.append(contentsOf: Array(marker(pictures.count).utf8))
                        pictures.append(picture)
                        previousWasPicture = true
                    }
                }

                i = end
                continue
            }

            if !byte.isRTFWhitespace { previousWasPicture = false }
            out.append(byte)
            i += 1
        }

        return Result(data: Data(out), pictures: pictures)
    }

    /// Якщо з позиції `start` починається група з картинкою, повертає її вид.
    private static func destination(at start: Int, in bytes: [UInt8]) -> Destination? {
        var i = start + 1
        while i < bytes.count, bytes[i].isRTFWhitespace { i += 1 }

        // Необовʼязкова позначка «пропускати, якщо не знаєш»: `\*`.
        if i + 1 < bytes.count, bytes[i] == .backslash, bytes[i + 1] == .asterisk {
            i += 2
            while i < bytes.count, bytes[i].isRTFWhitespace { i += 1 }
        }

        guard i < bytes.count, bytes[i] == .backslash else { return nil }
        i += 1

        var word = ""
        while i < bytes.count, bytes[i].isASCIILetter {
            word.append(Character(UnicodeScalar(bytes[i])))
            i += 1
        }

        return switch word {
        case "pict", "shppict": .picture
        case "nonshppict": .fallback
        default: nil
        }
    }

    /// Індекс одразу за дужкою, що закриває групу, відкриту на `start`.
    ///
    /// Двійкові дані `\binN` мусимо перестрибувати разом із підрахунком
    /// дужок: серед сирих байтів картинки рано чи пізно трапиться `}`, і без
    /// цього група обірветься посеред зображення.
    private static func groupEnd(from start: Int, in bytes: [UInt8]) -> Int {
        var depth = 0
        var i = start

        while i < bytes.count {
            let byte = bytes[i]

            if byte == .backslash {
                i = skip(controlAt: i, in: bytes, limit: bytes.count)
                continue
            }
            if byte == .openBrace {
                depth += 1
            } else if byte == .closeBrace {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }

        return bytes.count
    }

    /// Розбирає керівне слово, що починається з похилої риски на `index`.
    ///
    /// `nil`, якщо це не слово, а екранований символ.
    private static func controlWord(
        at index: Int,
        in bytes: [UInt8],
        limit: Int
    ) -> (word: String, parameter: Int?, next: Int)? {
        var i = index + 1
        guard i < limit, bytes[i].isASCIILetter else { return nil }

        var word = ""
        while i < limit, bytes[i].isASCIILetter {
            word.append(Character(UnicodeScalar(bytes[i])))
            i += 1
        }

        var digits = ""
        if i < limit, bytes[i] == .hyphen {
            digits.append("-")
            i += 1
        }
        while i < limit, bytes[i].isASCIIDigit {
            digits.append(Character(UnicodeScalar(bytes[i])))
            i += 1
        }

        // Один пробіл після слова — роздільник, а не текст.
        if i < limit, bytes[i] == .space { i += 1 }

        return (word, Int(digits), i)
    }

    /// Обмежує довжину двійкового хвоста тим, що справді лишилося у файлі.
    ///
    /// Складати напряму не можна. У пошкодженому — чи зумисне зіпсованому —
    /// файлі `\binN` буває завбільшки з `Int.max`, і додавання переповнює
    /// тип. У Swift переповнення не «загортається», а аварійно завершує
    /// застосунок: досить було б однієї такої книжки, щоб читалка падала на
    /// відкритті.
    private static func clamped(_ count: Int, upTo available: Int) -> Int {
        guard available > 0 else { return 0 }
        return min(count, available)
    }

    /// Позиція одразу за керівним словом разом із його двійковим хвостом.
    private static func skip(controlAt index: Int, in bytes: [UInt8], limit: Int) -> Int {
        guard let control = controlWord(at: index, in: bytes, limit: limit) else {
            // `\'41` — символ за кодом; решта — екранований знак на зразок `\{`.
            let isHexEscape = index + 1 < limit && bytes[index + 1] == .apostrophe
            return min(index + (isHexEscape ? 4 : 2), limit)
        }

        if control.word == "bin", let count = control.parameter, count > 0 {
            return control.next + clamped(count, upTo: limit - control.next)
        }
        return control.next
    }

    /// Збирає байти картинки з тіла групи.
    ///
    /// Дані бувають у двох виглядах: шістнадцятковий текст (звично) або
    /// двійковий блок після `\binN` (трапляється у великих файлах).
    private static func payload(in bytes: [UInt8], range: Range<Int>) -> Data? {
        var hex: [UInt8] = []
        var i = range.lowerBound

        while i < range.upperBound {
            let byte = bytes[i]

            if byte == .backslash {
                // `\binN` означає, що далі йдуть сирі байти картинки, а не
                // шістнадцятковий текст.
                if let control = controlWord(at: i, in: bytes, limit: range.upperBound),
                   control.word == "bin",
                   let count = control.parameter, count > 0 {
                    let end = control.next + clamped(count, upTo: range.upperBound - control.next)
                    return end > control.next ? Data(bytes[control.next ..< end]) : nil
                }

                i = skip(controlAt: i, in: bytes, limit: range.upperBound)
                continue
            }

            if byte.isASCIIHexDigit { hex.append(byte) }
            i += 1
        }

        return Data(hexDigits: hex)
    }

    // MARK: - Підстановка

    /// Замінює мітки на результат `replacement`.
    ///
    /// `replacement` повертає `nil`, якщо картинку не вдалося підготувати, —
    /// тоді мітка просто зникає з тексту.
    static func replacingMarkers(
        in text: String,
        replacement: (Int) -> String?
    ) -> String {
        guard text.contains(markerPrefix) else { return text }

        var result = ""
        var rest = Substring(text)

        while let start = rest.range(of: markerPrefix) {
            result += rest[rest.startIndex ..< start.lowerBound]
            let afterPrefix = rest[start.upperBound...]

            guard let close = afterPrefix.range(of: markerSuffix),
                  let index = Int(afterPrefix[afterPrefix.startIndex ..< close.lowerBound])
            else {
                // Не наша мітка — лишаємо текст як є, щоб нічого не загубити.
                result += rest[start.lowerBound ..< start.upperBound]
                rest = afterPrefix
                continue
            }

            result += replacement(index) ?? ""
            rest = afterPrefix[close.upperBound...]
        }

        return result + rest
    }
}

// MARK: - Байти

private extension UInt8 {
    static let backslash = UInt8(ascii: "\\")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let asterisk = UInt8(ascii: "*")
    static let apostrophe = UInt8(ascii: "'")
    static let hyphen = UInt8(ascii: "-")
    static let space = UInt8(ascii: " ")

    var isASCIILetter: Bool {
        (self >= 0x41 && self <= 0x5A) || (self >= 0x61 && self <= 0x7A)
    }

    var isASCIIDigit: Bool { self >= 0x30 && self <= 0x39 }

    var isASCIIHexDigit: Bool {
        isASCIIDigit || (self >= 0x41 && self <= 0x46) || (self >= 0x61 && self <= 0x66)
    }

    /// Пробіли, табуляція й переводи рядка — у RTF вони лише форматування
    /// самого файлу.
    var isRTFWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}

private extension Data {
    /// Збирає байти з шістнадцяткових знаків. Непарний «хвіст» відкидаємо:
    /// половина байта — це вже пошкоджений файл.
    init?(hexDigits: [UInt8]) {
        guard hexDigits.count >= 2 else { return nil }

        func value(_ digit: UInt8) -> UInt8 {
            switch digit {
            case 0x30 ... 0x39: digit - 0x30
            case 0x41 ... 0x46: digit - 0x41 + 10
            default: digit - 0x61 + 10
            }
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexDigits.count / 2)
        for i in stride(from: 0, to: hexDigits.count - 1, by: 2) {
            bytes.append(value(hexDigits[i]) << 4 | value(hexDigits[i + 1]))
        }
        self = Data(bytes)
    }
}
