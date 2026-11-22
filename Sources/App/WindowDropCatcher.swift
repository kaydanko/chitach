import SwiftUI
import UniformTypeIdentifiers

/// Ловить файли, перетягнуті у вікно застосунку.
///
/// Історія тут важливіша за код. Перетягування не працювало тричі поспіль, і
/// щоразу з іншої причини — точніше, щоразу припущення про причину було
/// хибним: спершу `.dropDestination(for: URL.self)`, потім `.onDrop` з явним
/// `public.file-url`, потім взаємодія UIKit на вікні. Спільне в них те, що
/// жодна не давала знати, **де саме** обривається ланцюг: подія не дійшла до
/// застосунку, застосунок її відкинув, чи файл не вдалося прочитати.
///
/// Тому тут не лише приймання, а й докладний журнал на кожному кроці та
/// видима реакція на наведення. Якщо рамка підсвічується — подія доходить, і
/// шукати треба далі по ланцюгу. Якщо ні — не доходить зовсім.
///
/// Взаємодія ставиться на кореневий вид, а не на власний: власний вид лежить
/// тлом, і кидок просто на кнопку заставки повз нього не пройшов би.
/// Кореневий — предок усього, тож накриває вікно цілком.
struct WindowDropCatcher: UIViewRepresentable {
    @Binding var isTargeted: Bool
    let onFiles: ([NSItemProvider]) -> Bool

    func makeUIView(context: Context) -> UIView {
        let view = DropCatcherView()
        view.isUserInteractionEnabled = false
        view.install = { [weak coordinator = context.coordinator] host in
            coordinator?.install(on: host)
        }
        return view
    }

    func updateUIView(_: UIView, context: Context) {
        context.coordinator.onFiles = onFiles
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, onFiles: onFiles)
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        @Binding private var isTargeted: Bool
        var onFiles: ([NSItemProvider]) -> Bool
        private var installedViews: [ObjectIdentifier] = []

        init(isTargeted: Binding<Bool>, onFiles: @escaping ([NSItemProvider]) -> Bool) {
            _isTargeted = isTargeted
            self.onFiles = onFiles
        }

        func install(on view: UIView) {
            guard !installedViews.contains(ObjectIdentifier(view)) else { return }

            // Якщо SwiftUI перестворить обгортку, лишиться стара взаємодія —
            // і кожен кидок імпортував би книгу двічі.
            for case let existing as UIDropInteraction in view.interactions
                where existing.delegate is Coordinator
            {
                view.removeInteraction(existing)
            }

            view.addInteraction(UIDropInteraction(delegate: self))
            installedViews.append(ObjectIdentifier(view))
            DropLog.note("взаємодію встановлено на \(type(of: view))")
        }

        /// Беремо все, що несе хоч якийсь файл.
        ///
        /// Навмисно без переліку підтримуваних типів: відмова на цьому кроці
        /// показала б лише перекреслене коло, без пояснення. Краще прийняти
        /// й сказати словами, якщо формат не той.
        func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            let types = session.items.flatMap(\.itemProvider.registeredTypeIdentifiers)
            let accepted = session.items.contains {
                $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.item.identifier)
            }
            DropLog.note("canHandle: \(accepted ? "так" : "ні"), типи: \(types.joined(separator: ", "))")
            return accepted
        }

        func dropInteraction(_: UIDropInteraction, sessionDidEnter _: UIDropSession) {
            DropLog.note("курсор над вікном")
            isTargeted = true
        }

        func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_: UIDropInteraction, sessionDidExit _: UIDropSession) {
            isTargeted = false
        }

        func dropInteraction(_: UIDropInteraction, sessionDidEnd _: UIDropSession) {
            isTargeted = false
        }

        func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
            isTargeted = false
            let providers = session.items.map(\.itemProvider)
            DropLog.note("кидок: елементів \(providers.count)")
            _ = onFiles(providers)
        }
    }
}

/// Журнал ланцюга перетягування.
///
/// Пишемо в потік помилок, а не `print`. Причина практична: `print` у файл
/// чи канал буферизується блоками, і якщо застосунок завершити, усе
/// накопичене гине разом із ним — перша ж спроба зняти журнал дала порожній
/// файл. Потік помилок небуферизований, тож рядок зʼявляється одразу.
enum DropLog {
    static func note(_ message: String) {
        fputs("[DROP] \(message)\n", stderr)
    }
}

/// Повідомляє, коли вид потрапив у вікно, і віддає кореневий вид.
///
/// `view.window` у `updateUIView` ще порожній — вид туди лише прямує.
private final class DropCatcherView: UIView {
    var install: ((UIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }

        // І кореневий вид, і саме вікно: кореневий накриває вміст, вікно —
        // усе інше, зокрема смугу над ним. Подвійного імпорту це не дає:
        // UIKit віддає кидок найглибшій взаємодії, а на випадок, якщо це
        // колись зміниться, повтор відсіюється у сховищі.
        if let root = window.rootViewController?.view {
            install?(root)
        }
        install?(window)
    }
}
