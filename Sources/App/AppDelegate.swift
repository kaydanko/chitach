import UIKit
import WebKit


/// Прибирає білий спалах на запуску.
///
/// `UILaunchScreen` з Info.plist діє лише на iOS — Mac Catalyst його
/// практично ігнорує. На Mac світло до першого кадру дають два інші джерела:
/// тло самого вікна (за замовчуванням системне світле) і світла тема
/// інтерфейсу, з якої SwiftUI бере кольори тла.
///
/// `UIWindow.appearance()` застосовується до вікон ще до того, як вони
/// зʼявляться на екрані, тому перехоплює саме той момент, коли білий встигав
/// блимнути.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIWindow.appearance().backgroundColor = BookAppearance.voidColor

        // Те саме для webview, і з тієї ж причини: проксі вигляду діє на
        // види ще до того, як вони зʼявляться. Readium створює webview сам,
        // і дотягнутися до щойно створеного ми не встигаємо — він устигає
        // блимнути білим. Заданий тут колір він має від народження.
        WKWebView.appearance().backgroundColor = BookAppearance.loadingBackdropColor

        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Фарбує вікно одразу після його створення.
///
/// Потрібен на додачу до `UIWindow.appearance()`: proxy не завжди встигає,
/// якщо сцена вже існувала (відновлення стану, друге вікно на Mac).
final class SceneDelegate: NSObject, UIWindowSceneDelegate {

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        #if targetEnvironment(macCatalyst)
        // Ховаємо системний титульний рядок: роль шапки виконує власна
        // панель. Інакше у вікні маємо два рядки поспіль, а в розгорнутому
        // стані системні кнопки лягають поверх наших.
        // Початкове положення панелі кольорів — тут, бо лише тут є сцена,
        // у якій її відкриють.
        ColorPanelPlacement.seedIfNeeded(in: windowScene)

        if let titlebar = windowScene.titlebar {
            titlebar.titleVisibility = .hidden
            titlebar.toolbar = nil
            titlebar.separatorStyle = .none
        }
        #endif
        for window in windowScene.windows {
            window.backgroundColor = BookAppearance.voidColor
            window.rootViewController?.view.backgroundColor = BookAppearance.voidColor

        }
    }
}
