import Foundation
import ReadiumShared

/// Запамʼятовує, де саме зупинилося читання кожної книги.
///
/// Зберігається повний `Locator`, а не відсоток прочитаного. Відсоток
/// непридатний: після зміни кегля, полів або розміру вікна книга
/// перепагінується, і та сама частка прокрутки вказує вже на інший абзац.
/// `Locator` містить `href` ресурсу й точне положення всередині нього, тож
/// витримує перепагінацію.
///
/// Поки що `UserDefaults` — один JSON-рядок на книгу. У Фазі 2 це переїде в
/// базу разом із бібліотекою, закладками й нотатками.
enum ReadingPositionStore {
    /// Ключ по імені файлу, а не по повному шляху: контейнер застосунку на
    /// кожному запуску має інший UUID у шляху, і абсолютний URL протухає.
    private static func key(for bookURL: URL) -> String {
        "readingPosition." + bookURL.lastPathComponent
    }

    static func save(_ locator: Locator, for bookURL: URL) {
        guard let json = try? locator.jsonString() else { return }
        UserDefaults.standard.set(json, forKey: key(for: bookURL))
    }

    static func locator(for bookURL: URL) -> Locator? {
        guard let json = UserDefaults.standard.string(forKey: key(for: bookURL)) else {
            return nil
        }

        // Шлях навмисно не через `Locator(legacyJSONString:)`: той розбирає
        // HREF за правилами Readium 2.x і призначений лише для міграції
        // старих баз. Для рядків, які ми самі щойно записали, потрібен
        // звичайний розбір.
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let value = JSONValue(object)
        else {
            return nil
        }
        return try? Locator(json: value, warnings: nil)
    }

    static func forget(_ bookURL: URL) {
        UserDefaults.standard.removeObject(forKey: key(for: bookURL))
    }
}
