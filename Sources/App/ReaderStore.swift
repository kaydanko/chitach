import Foundation
import Observation
import UIKit

/// Спільний стан застосунку: яка книга відкрита і що з імпортом.
///
/// Потрібен, бо пункт меню «Відкрити книгу…» живе у `ChytachApp`, а показує
/// діалог `ContentView` — їм треба спільна точка.
/// Куди перейти на вимогу з меню.
enum ReaderJump: Equatable {
    case start
    case end
}

@Observable
final class ReaderStore {
    private static let lastBookKey = "lastOpenedBook"
    private static let fontSizeKey = "readerFontSize"
    private static let paperKey = "readerPaperColor"
    private static let inkKey = "readerInkColor"

    /// Книга, яку читаємо. `nil` — показуємо екран відкриття.
    var bookURL: URL? {
        didSet { persistLastBook() }
    }

    /// Чи показаний системний вибір файлів.
    var isImporting = false

    /// Текст помилки для користувача, якщо імпорт не вдався.
    var errorMessage: String?

    /// Чи відкрито налаштування оформлення.
    var isShowingSettings = false

    /// Запит переходу з меню. Екран читання його виконує й скидає.
    ///
    /// Потрібен місток: пункти меню живуть у `ChytachApp`, а навігатор —
    /// усередині екрана читання, і прямого доступу між ними немає.
    var pendingJump: ReaderJump?

    /// Лічильник змін оформлення. Екран читання стежить за ним і застосовує
    /// нові налаштування, зберігаючи місце в тексті.
    private(set) var appearanceRevision = 0

    // MARK: - Оформлення

    // Значення зберігаються тут, а не лише в `BookAppearance`, і це принципово.
    // `BookAppearance` — простий enum зі статичними полями, за якими
    // `@Observable` не стежить. Якщо читати їх напряму з екрана, SwiftUI не
    // дізнається про зміну й не перемалює: саме через це цифра розміру тексту
    // в налаштуваннях лишалася на місці. Тут поля збережені, тож залежність
    // відстежується, а `BookAppearance` отримує копію для Readium.

    private var storedFontSize = BookAppearance.minimumFontSize
    private var storedPaperColor = BookAppearance.defaultPaper
    private var storedInkColor = BookAppearance.defaultInk

    var fontSize: Double {
        get { storedFontSize }
        set {
            let clamped = min(
                max(newValue, BookAppearance.minimumFontSize),
                BookAppearance.maximumFontSize
            )
            guard abs(clamped - storedFontSize) > 0.0001 else { return }
            storedFontSize = clamped
            BookAppearance.fontSize = clamped
            UserDefaults.standard.set(clamped, forKey: Self.fontSizeKey)
            appearanceRevision += 1
        }
    }

    var paperColor: UIColor {
        get { storedPaperColor }
        set {
            guard newValue.hexValue != storedPaperColor.hexValue else { return }
            storedPaperColor = newValue
            BookAppearance.paperColor = newValue
            UserDefaults.standard.set(Int(newValue.hexValue), forKey: Self.paperKey)
            appearanceRevision += 1
        }
    }

    var inkColor: UIColor {
        get { storedInkColor }
        set {
            guard newValue.hexValue != storedInkColor.hexValue else { return }
            storedInkColor = newValue
            BookAppearance.inkColor = newValue
            UserDefaults.standard.set(Int(newValue.hexValue), forKey: Self.inkKey)
            appearanceRevision += 1
        }
    }

    /// Крок кегля: `+1` більший, `-1` менший.
    func stepFontSize(by steps: Int) {
        fontSize += Double(steps) * BookAppearance.fontSizeStep
    }

    var canIncreaseFontSize: Bool { fontSize < BookAppearance.maximumFontSize - 0.001 }
    var canDecreaseFontSize: Bool { fontSize > BookAppearance.minimumFontSize + 0.001 }

    func resetAppearance() {
        paperColor = BookAppearance.defaultPaper
        inkColor = BookAppearance.defaultInk
        fontSize = BookAppearance.minimumFontSize
    }

    private static func restoreAppearance() {
        let defaults = UserDefaults.standard
        if let size = defaults.object(forKey: fontSizeKey) as? Double {
            BookAppearance.fontSize = min(
                max(size, BookAppearance.minimumFontSize),
                BookAppearance.maximumFontSize
            )
        }
        if let paper = defaults.object(forKey: paperKey) as? Int {
            BookAppearance.paperColor = UIColor(hex: UInt32(truncatingIfNeeded: paper))
        }
        if let ink = defaults.object(forKey: inkKey) as? Int {
            BookAppearance.inkColor = UIColor(hex: UInt32(truncatingIfNeeded: ink))
        }
    }

    init() {
        Self.restoreAppearance()
        storedFontSize = BookAppearance.fontSize
        storedPaperColor = BookAppearance.paperColor
        storedInkColor = BookAppearance.inkColor

        // `--settings` одразу відкриває аркуш оформлення. Потрібно, щоб
        // перевіряти його вигляд без вказівника. Разом із `--open` та
        // `--selftest` прибрати, коли запрацює тест-ранер.
        isShowingSettings = CommandLine.arguments.contains("--settings")
        ColorPanelPlacement.seedIfNeeded()

        // Запуск із файлом: `--open <шлях або імʼя у теці Books>`.
        // Потрібно для перевірки без UI; користувачу стає в пригоді, коли
        // треба швидко відкрити конкретний файл.
        if let requested = Self.requestedBookFromLaunchArguments() {
            bookURL = requested
        } else {
            bookURL = Self.restoreLastBook()
        }
    }

    private static func requestedBookFromLaunchArguments() -> URL? {
        let arguments = CommandLine.arguments
        guard
            let index = arguments.firstIndex(of: "--open"),
            index + 1 < arguments.count
        else { return nil }

        let value = arguments[index + 1]
        let candidates = [
            URL(fileURLWithPath: value),
            BookImportService.booksDirectory.appendingPathComponent(value),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Приймає файл від вибору або перетягування.
    func open(fileURL: URL) {
        do {
            bookURL = try BookImportService.importBook(from: fileURL)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Відкриває зашитий зразок.
    ///
    /// Потрібен, щоб застосунок можна було оцінити без власного файлу —
    /// і щоб перевіряти вигляд на симуляторі. Прибрати разом із
    /// `Sources/Resources/sample.epub`, коли зʼявиться бібліотека (Фаза 2).
    func openSample() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "epub") else {
            errorMessage = "Зразок не знайдено в бандлі."
            return
        }
        open(fileURL: url)
    }

    func closeBook() {
        bookURL = nil
    }

    // MARK: - Збереження обраної книги

    /// Зберігаємо лише імʼя файлу, не повний шлях: контейнер застосунку на
    /// кожному запуску може мати інший UUID у шляху, і абсолютний URL
    /// протухає.
    private func persistLastBook() {
        guard let bookURL else {
            UserDefaults.standard.removeObject(forKey: Self.lastBookKey)
            return
        }
        UserDefaults.standard.set(bookURL.lastPathComponent, forKey: Self.lastBookKey)
    }

    private static func restoreLastBook() -> URL? {
        guard let name = UserDefaults.standard.string(forKey: Self.lastBookKey) else {
            return nil
        }
        let url = BookImportService.booksDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
