import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ReaderStore.self) private var store

    private enum LoadState: Equatable {
        case empty
        case loading
        case ready(ReaderHostViewController)
        case failed(String)

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty), (.loading, .loading): true
            case let (.failed(l), .failed(r)): l == r
            case let (.ready(l), .ready(r)): l === r
            default: false
            }
        }
    }

    @State private var state: LoadState = .empty

    var body: some View {
        @Bindable var store = store

        GeometryReader { geometry in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(BookAppearance.voidColor).ignoresSafeArea())
                // Перетягування файлу у вікно. Саме `onDrop` із явним типом
                // `public.file-url`, а не `dropDestination(for: URL.self)`:
                // Finder віддає файл провайдером, і типізований варіант на
                // Catalyst його не бачить.
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    store.open(providers: providers)
                }
                .fileImporter(
                    isPresented: $store.isImporting,
                    allowedContentTypes: BookImportService.contentTypes
                ) { result in
                    switch result {
                    case let .success(url): store.open(fileURL: url)
                    case let .failure(error): store.errorMessage = error.localizedDescription
                    }
                }
                .task(id: store.bookURL) {
                    await reload(width: geometry.size.width)
                }
        }
        .alert(
            "Не вдалося відкрити",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("Зрозуміло", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            OpenBookPlaceholder()

        case .loading:
            ProgressView()

        case let .ready(host):
            ReaderView(host: host)

        case let .failed(message):
            ContentUnavailableView {
                Label("Не вдалося відкрити книгу", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).font(.footnote.monospaced())
            } actions: {
                Button("Обрати інший файл") { store.isImporting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// `true`, коли процес запущено тест-ранером.
    private static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private func reload(width: CGFloat) async {
        // Під тестами нічого не відкриваємо: тестовий бандл хоститься в цьому
        // ж застосунку, і WKWebView на старті не дає тест-ранеру встановити
        // зʼєднання — запуск зависає.
        guard !Self.isRunningTests else { return }

        guard let url = store.bookURL else {
            // Самоперевірка має що відкрити навіть на чистій установці.
            if Phase0SelfCheck.isRequested {
                store.openSample()
            }
            state = .empty
            return
        }

        state = .loading
        do {
            let opened = try await ReadiumPublicationService()
                .open(fileURL: url, allowUserInteraction: true)

            // Кількість колонок визначаємо до створення навігатора, щоб на
            // старті не було зайвої перепагінації.
            let twoColumns = BookAppearance.shouldUseTwoColumns(width: width)

            let navigator = try EPUBNavigatorViewController(
                publication: opened.publication,
                initialLocation: ReadingPositionStore.locator(for: url),
                config: BookAppearance.navigatorConfiguration(twoColumns: twoColumns)
            )

            let host = ReaderHostViewController(
                navigator: navigator,
                bookURL: url,
                startsTwoColumns: twoColumns
            )
            state = .ready(host)

            if Phase0SelfCheck.isRequested {
                Task { await Phase0SelfCheck.run(host: host) }
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

/// Екран, коли книга не обрана.
///
/// Існує тому, що досі єдиним способом щось прочитати був зашитий зразок, і з
/// інтерфейсу не було видно, як відкрити власний файл.
private struct OpenBookPlaceholder: View {
    @Environment(ReaderStore.self) private var store

    // Розміри задані в пунктах, а не семантичними стилями
    // (`.callout`, `.footnote`). На Mac Catalyst інтерфейс малюється в
    // масштабі 77%, тож системні стилі виходять там помітно дрібнішими за
    // задумане, і керувати ними стає неможливо.
    private let iconSize: CGFloat = 112
    private let titleSize: CGFloat = 64
    private let hintSize: CGFloat = 30
    private let buttonSize: CGFloat = 26
    private let noteSize: CGFloat = 23

    var body: some View {
        VStack(spacing: 34) {
            Image(systemName: "books.vertical")
                .font(.system(size: iconSize, weight: .light))
                .foregroundStyle(Color(BookAppearance.onVoidMutedColor))

            Text("Chytach")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Color(BookAppearance.onVoidColor))

            VStack(spacing: 12) {
                Text("Перетягніть книгу сюди")
                Text("або натисніть кнопку нижче, або ⌘O")
            }
            .font(.system(size: hintSize))
            .foregroundStyle(Color(BookAppearance.onVoidMutedColor))

            HStack(spacing: 18) {
                // Світла заливка з темною підписом: на чорному тлі це
                // єдине поєднання, що дає достатній контраст.
                Button("Відкрити книгу…") { store.isImporting = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(BookAppearance.onVoidColor))
                    .foregroundStyle(Color(BookAppearance.voidColor))

                Button("Відкрити зразок") { store.openSample() }
                    .buttonStyle(.bordered)
                    .tint(Color(BookAppearance.onVoidColor))
                    .foregroundStyle(Color(BookAppearance.onVoidColor))
            }
            .font(.system(size: buttonSize, weight: .medium))
            .controlSize(.extraLarge)
            .padding(.top, 8)

            Text("Зараз підтримуються EPUB, TXT, Markdown, PDF і CBZ.\nFB2, RTF і MOBI — у наступних етапах.")
                .font(.system(size: noteSize))
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .foregroundStyle(Color(BookAppearance.onVoidMutedColor))
                .padding(.top, 18)
        }
        .padding(56)
    }
}
