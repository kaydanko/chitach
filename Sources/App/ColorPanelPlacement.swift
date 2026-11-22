import UIKit

/// Ставить системну панель кольорів по центру екрана.
///
/// На Mac Catalyst `ColorPicker` відкриває панель кольорів AppKit. Коли в неї
/// немає збереженого положення, AppKit кладе її в лівий нижній кут — і там її
/// легко не помітити, а решта інтерфейсу на той час не реагує. Виглядає як
/// зависання застосунку.
///
/// Дістатися до `NSColorPanel` із Catalyst напряму не можна, але AppKit
/// зберігає положення вікон у `UserDefaults` під ключем
/// `NSWindow Frame <autosaveName>`. Записуємо туди розумне початкове
/// значення — далі система сама памʼятатиме, куди користувач її пересунув.
enum ColorPanelPlacement {
    private static let key = "NSWindow Frame NSColorPanel"

    /// Масштаб інтерфейсу Catalyst за замовчуванням: UIKit-точки малюються на
    /// Mac зменшеними. Потрібен, щоб перерахувати розмір екрана в координати
    /// AppKit.
    private static let catalystScale: CGFloat = 0.77

    private static let panelSize = CGSize(width: 232, height: 420)

    static func seedIfNeeded() {
        guard UserDefaults.standard.string(forKey: key) == nil else { return }

        let screen = UIScreen.main.bounds
        let width = screen.width * catalystScale
        let height = screen.height * catalystScale

        let x = ((width - panelSize.width) / 2).rounded()
        let y = ((height - panelSize.height) / 2).rounded()

        // Формат AppKit: x y w h screenX screenY screenW screenH.
        let frame = "\(Int(x)) \(Int(y)) \(Int(panelSize.width)) \(Int(panelSize.height))"
            + " 0 0 \(Int(width)) \(Int(height))"
        UserDefaults.standard.set(frame, forKey: key)
    }
}
