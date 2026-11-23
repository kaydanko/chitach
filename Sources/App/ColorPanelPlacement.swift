import UIKit

#if targetEnvironment(macCatalyst)

/// Ставить системну панель кольорів по центру вікна.
///
/// Лише для Mac: на iOS `ColorPicker` показує власний аркуш, і панелі AppKit
/// там немає взагалі. Доти цей код виконувався на всіх пристроях і писав
/// налаштування, яке ніде не читалося.
///
/// Коли в панелі немає збереженого положення, AppKit кладе її в лівий нижній
/// кут — там її легко не помітити, а решта інтерфейсу на той час не реагує.
/// Виглядає як зависання застосунку.
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

    /// - Parameter windowScene: сцена, у якій відкриють панель. Саме вона, а
    ///   не `UIScreen.main`: глобальний «головний екран» нічого не знає про
    ///   те, де насправді живе вікно. На складаному телефоні вікно займає то
    ///   зовнішній екран, то внутрішній, і панель полетіла б повз.
    static func seedIfNeeded(in windowScene: UIWindowScene) {
        guard UserDefaults.standard.string(forKey: key) == nil else { return }

        let screen = windowScene.screen.bounds
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

#endif
