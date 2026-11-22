import SwiftUI

@main
struct ChytachApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ReaderStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                // Відкриття через Finder → «Відкрити за допомогою».
                .onOpenURL { store.open(fileURL: $0) }
                // Темна тема примусово: зі світлою SwiftUI бере системні
                // кольори тла, і на запуску встигає блимнути біле.
                .preferredColorScheme(.dark)
        }
        .commands {
            // На Mac Catalyst це дає пункт у меню «Файл» із ⌘O.
            // Замінюємо «Новий», бо створювати книги застосунок не вміє.
            CommandGroup(replacing: .newItem) {
                Button("Відкрити книгу…") {
                    store.isImporting = true
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Закрити книгу") {
                    store.closeBook()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(store.bookURL == nil)
            }

            // Розмір тексту з клавіатури. На Mac ⌘+ фізично вводиться як
            // ⌘= без Shift, тому реєструємо обидва варіанти — інакше
            // спрацьовує лише один розклад.
            CommandGroup(after: .toolbar) {
                Button("Більший текст") { store.stepFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!store.canIncreaseFontSize)

                Button("Більший текст (альт.)") { store.stepFontSize(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(!store.canIncreaseFontSize)

                Button("Менший текст") { store.stepFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!store.canDecreaseFontSize)

                Divider()

                Button("Оформлення…") { store.isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)

                Divider()

                Button("На початок книги") { store.pendingJump = .start }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(store.bookURL == nil)

                Button("У кінець книги") { store.pendingJump = .end }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(store.bookURL == nil)
            }
        }
    }
}
