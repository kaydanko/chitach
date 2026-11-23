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

    /// Чи тримають файл над вікном. Два прапорці, бо каналів приймання два.
    @State private var isWindowDropTargeted = false
    @State private var isViewDropTargeted = false

    var body: some View {
        @Bindable var store = store

        GeometryReader { geometry in
            // Бібліотека накриває вміст, а не підмінює його. Якби вона
            // ставала на місце читалки, та щоразу демонтувалася б і
            // збиралася знову — разом із WKWebView і місцем у книзі.
            ZStack {
                content

                if store.isShowingLibrary {
                    LibraryView(onClose: { store.isShowingLibrary = false })
                        .background(Color(BookAppearance.voidColor).ignoresSafeArea())
                        .transition(.opacity)
                }

                if store.isShowingDonation {
                    DonationView(onClose: { store.isShowingDonation = false })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: store.isShowingLibrary)
            .animation(.easeOut(duration: 0.16), value: store.isShowingDonation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(BookAppearance.voidColor).ignoresSafeArea())
            // Перетягування приймається двома каналами навмисно.
            //
            // Жоден з них поодинці досі не спрацював, а з коду не видно,
            // котрий саме мовчить: UIKit віддає кидок найглибшій
            // взаємодії, тож одночасно вони не спрацюють, зате журнал
            // одразу покаже, хто з них отримав подію. Повтор, якби він
            // усе ж стався, відсіюється у сховищі.
            .background(WindowDropCatcher(isTargeted: $isWindowDropTargeted) { providers in
                store.open(providers: providers, source: "вікно")
            })
            .onDrop(of: [.item], isTargeted: $isViewDropTargeted) { providers in
                store.open(providers: providers, source: "SwiftUI")
            }
            .overlay { dropHighlight }
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
                    .buttonStyle(VoidButtonStyle(kind: .filled, fontSize: 20))
            }
        }
    }

    /// Видима відповідь на наведення файлу.
    ///
    /// Потрібна не лише для вигляду: доки перетягування не працює, це
    /// єдиний спосіб побачити, чи подія взагалі доходить до застосунку.
    @ViewBuilder
    private var dropHighlight: some View {
        if isWindowDropTargeted || isViewDropTargeted {
            ZStack {
                Color(BookAppearance.voidColor).opacity(0.55)
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        Color(BookAppearance.onVoidColor),
                        style: StrokeStyle(lineWidth: 3, dash: [11, 8])
                    )
                Text("Відпустіть, щоб відкрити")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color(BookAppearance.onVoidColor))
            }
            .padding(14)
            .allowsHitTesting(false)
            .transition(.opacity)
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

            // Назва й автор відомі лише після розбору — звідси бібліотека їх
            // і бере, замість показувати ім`я файлу.
            LibraryStore.remember(opened.publication, for: url)
            store.refreshLibrary()

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

/// Кнопка на темному тлі, намальована власноруч.
///
/// Системний `.borderedProminent` на Mac прибирає заливку, щойно вікно
/// втрачає фокус: лишається темний напис на темному тлі, і кнопки просто не
/// видно. На заставці це неприпустимо — там вона єдиний спосіб відкрити
/// книгу, і саме туди людина дивиться, повертаючись до вікна з іншого
/// застосунку.
///
/// Тому заливку малюємо самі: її вигляд не залежить ні від фокуса вікна, ні
/// від системного акцентного кольору.
private struct VoidButtonStyle: ButtonStyle {
    enum Kind {
        /// Світла заливка з темним написом — найбільший контраст на чорному.
        case filled
        /// Лише обведення: для другорядної дії поруч.
        case outlined
    }

    let kind: Kind
    let fontSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(Color(
                kind == .filled ? BookAppearance.voidColor : BookAppearance.onVoidColor
            ))
            .padding(.horizontal, fontSize)
            .padding(.vertical, fontSize * 0.55)
            .background(background)
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private var background: some View {
        if kind == .filled {
            Capsule().fill(Color(BookAppearance.onVoidColor))
        } else {
            Capsule().strokeBorder(Color(BookAppearance.onVoidColor).opacity(0.5), lineWidth: 1.5)
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

    /// Ширина, під яку ці розміри добиралися.
    ///
    /// Сталі пункти добре працюють, доки вікно широке. На зовнішньому екрані
    /// складаного телефона ширини всього 466 pt — і написи на кнопках там
    /// обрізалися до «Відк…». Тому розміри масштабуються від наявної ширини,
    /// а не від пристрою: вікно змінює розмір і на Mac, і коли телефон
    /// розкладають.
    private let referenceWidth: CGFloat = 760

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, geometry.size.width / referenceWidth)
            layout(scale: scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { supportLink(scale: scale) }
        }
    }

    /// Тихе посилання на внесок у самому низу: помітне, але не змагається
    /// з головною дією екрана.
    private func supportLink(scale: CGFloat) -> some View {
        Button {
            store.isShowingDonation = true
        } label: {
            Label("Підтримати проєкт", systemImage: "heart")
                .font(.system(size: max(15, 19 * scale), weight: .medium))
                .foregroundStyle(Color(BookAppearance.onVoidMutedColor))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 20 * scale)
    }

    private func layout(scale: CGFloat) -> some View {
        VStack(spacing: 34 * scale) {
            Image(systemName: "books.vertical")
                .font(.system(size: iconSize * scale, weight: .light))
                .foregroundStyle(Color(BookAppearance.onVoidMutedColor))

            Text("Chytach")
                .font(.system(size: titleSize * scale, weight: .semibold))
                .foregroundStyle(Color(BookAppearance.onVoidColor))

            VStack(spacing: 12 * scale) {
                Text("Перетягніть книгу сюди")
                Text("або натисніть кнопку нижче, або ⌘O")
            }
            .font(.system(size: hintSize * scale))
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .foregroundStyle(Color(BookAppearance.onVoidMutedColor))

            HStack(spacing: 18 * scale) {
                // Коли книги вже додані, головна дія — повернутися до них,
                // а не шукати новий файл. На порожній бібліотеці навпаки:
                // повертатися нема до чого, зате є зразок, щоб застосунок
                // можна було оцінити без власної книжки.
                if store.library.isEmpty {
                    Button("Відкрити книгу…") { store.isImporting = true }
                        .buttonStyle(VoidButtonStyle(kind: .filled, fontSize: buttonSize * scale))

                    Button("Відкрити зразок") { store.openSample() }
                        .buttonStyle(VoidButtonStyle(kind: .outlined, fontSize: buttonSize * scale))
                } else {
                    Button("Бібліотека (\(store.library.count))") {
                        store.refreshLibrary()
                        store.isShowingLibrary = true
                    }
                    .buttonStyle(VoidButtonStyle(kind: .filled, fontSize: buttonSize))

                    Button("Відкрити книгу…") { store.isImporting = true }
                        .buttonStyle(VoidButtonStyle(kind: .outlined, fontSize: buttonSize))
                }
            }
            .padding(.top, 8 * scale)

            Text("Підтримуються EPUB, FB2, TXT, Markdown, RTF, PDF і CBZ.")
                .font(.system(size: noteSize * scale))
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .lineSpacing(5 * scale)
                .foregroundStyle(Color(BookAppearance.onVoidMutedColor))
                .padding(.top, 18 * scale)
        }
        .padding(56 * scale)
    }
}
