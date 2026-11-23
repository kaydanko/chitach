import Foundation
import ObjectiveC

/// Мова інтерфейсу, обрана в самому застосунку.
///
/// Системний вибір мови для окремого застосунку на iOS схований глибоко в
/// Параметрах, а на Mac його немає зовсім. Тому мова перемикається на
/// заставці й діє одразу, без перезапуску.
///
/// Українські рядки в коді — водночас і ключі, і український текст.
/// Переклади лежать у `Localizable.xcstrings`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case uk
    case en

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Підпис на перемикачі. Кожна мова названа сама собою: так її впізнає
    /// людина, яка поточної мови не розуміє.
    var shortName: String {
        switch self {
        case .uk: "УКР"
        case .en: "ENG"
        }
    }

    var fullName: String {
        switch self {
        case .uk: "Українська"
        case .en: "English"
        }
    }

    private static let defaultsKey = "appLanguage"

    /// Збережений вибір. На першому запуску — українська, якщо вона перша
    /// серед мов системи, інакше англійська.
    static var stored: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let language = AppLanguage(rawValue: raw) {
            return language
        }
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("uk") ? .uk : .en
    }

    /// Мова, якою зараз шукаються рядки.
    nonisolated static var current: AppLanguage { LanguageBundle.language }

    /// Бандл з рядками обраної мови — для `String(localized:bundle:)`.
    ///
    /// `Text("…")` перекладається сам, а `String(localized:)` — ні: він
    /// шукає рядок повз `Bundle.localizedString`, тож підміна класу
    /// головного бандла до нього не доходить, і він бере мову системи.
    /// Тому всі рядки поза `Text` передають цей бандл явно.
    nonisolated static var bundle: Bundle { LanguageBundle.translations ?? .main }

    /// Перемикає пошук рядків у всьому процесі й запамʼятовує вибір.
    static func apply(_ language: AppLanguage, persist: Bool = true) {
        LanguageBundle.install()
        LanguageBundle.language = language
        LanguageBundle.translations = Bundle.main
            .path(forResource: language.rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:))
        if persist {
            UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        }
    }
}

/// `Bundle.main`, що шукає рядки в обраній мові, а не в мові системи.
///
/// `Text("…")` зрештою питає `Bundle.main.localizedString(forKey:value:table:)`.
/// Підмінивши клас головного бандла, ми перенаправляємо всі написи разом —
/// інакше довелося б загортати кожен у власну функцію. `String(localized:)`
/// цим шляхом не йде, тож йому бандл передається явно (`AppLanguage.bundle`).
///
/// `nonisolated`, бо рядки в бандла питають з будь-якого потоку, а не лише
/// з головного.
nonisolated private final class LanguageBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var language: AppLanguage = .uk
    nonisolated(unsafe) static var translations: Bundle?
    nonisolated(unsafe) private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        object_setClass(Bundle.main, LanguageBundle.self)
    }

    override func localizedString(
        forKey key: String,
        value: String?,
        table tableName: String?
    ) -> String {
        // Українська — мова вихідних рядків: ключ і є текстом. Питати
        // системний пошук не можна: на англомовному пристрої він повернув
        // би переклад.
        if Self.language == .uk, tableName == nil || tableName == "Localizable" {
            if let value, !value.isEmpty { return value }
            return key
        }
        if let translations = Self.translations {
            return translations.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
