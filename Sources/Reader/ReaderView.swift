import ReadiumNavigator
import ReadiumShared
import SwiftUI

/// SwiftUI-обгортка над хост-контролером.
///
/// Скопійовано з docs/Guides/Navigator/SwiftUI.md @ 3.11.0.
struct ReaderViewControllerWrapper: UIViewControllerRepresentable {
    let viewController: ReaderHostViewController

    func makeUIViewController(context: Context) -> ReaderHostViewController {
        viewController
    }

    func updateUIViewController(_ uiViewController: ReaderHostViewController, context: Context) {}
}

/// Екран читання з панелями.
struct ReaderView: View {
    let host: ReaderHostViewController

    @Environment(ReaderStore.self) private var store

    @State private var locator: Locator?
    @State private var hoveredButton: PageDirection?

    /// Чи відмалював документ перший кадр.
    ///
    /// До цього моменту `WKWebView` показує власну білу площину. Знизу її не
    /// перекрити — вона непрозора, — тому область читання накривається зверху
    /// аркушем кольору паперу. Знімок екрана під час запуску показав саме це:
    /// панелі вже на місці, а весь текстовий простір білий.
    @State private var isDocumentReady = false

    /// Видима частина книги. `progression` — діапазон від 0 до 1, тож на
    /// першій сторінці його нижня межа дорівнює нулю, а на останній верхня —
    /// одиниці. Саме за цим ховаємо кнопки, яким нікуди гортати.
    @State private var viewport: NavigatorViewport?

    private enum PageDirection { case backward, forward }

    /// Невеликий допуск: межі діапазону рідко дорівнюють 0 і 1 точно.
    private static let edgeTolerance = 0.0005

    private func canTurn(_ direction: PageDirection) -> Bool {
        guard let viewport else { return false }
        return switch direction {
        case .backward: viewport.progression.lowerBound > Self.edgeTolerance
        case .forward: viewport.progression.upperBound < 1 - Self.edgeTolerance
        }
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            topBar
            readingArea
            bottomBar
        }
        .background(Color(BookAppearance.voidColor))
        .onAppear {
            host.onLocationChange = { locator = $0 }
            host.onViewportChange = { newViewport in
                viewport = newViewport

                // Непорожній viewport означає, що сторінка вже відмальована.
                guard newViewport != nil, !isDocumentReady else { return }
                withAnimation(.easeOut(duration: 0.18)) { isDocumentReady = true }
            }
            // ⌘ + коліщатко миші.
            host.onFontSizeStep = { steps in store.stepFontSize(by: steps) }
        }
        .onChange(of: store.appearanceRevision) {
            Task { await host.refreshAppearance() }
        }
        .sheet(isPresented: $store.isShowingSettings) {
            AppearanceSettingsView()
        }
    }

    // MARK: - Шапка

    private var topBar: some View {
        HStack(spacing: 14) {
            toolbarButton("chevron.left", label: "До бібліотеки") { store.closeBook() }
            toolbarButton("folder", label: "Відкрити книгу") { store.isImporting = true }

            Spacer(minLength: 12)

            Text(host.bookTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            toolbarButton("textformat.size", label: "Оформлення") {
                store.isShowingSettings = true
            }
        }
        .padding(.leading, BookAppearance.toolbarLeadingInset)
        .padding(.trailing, 14)
        .frame(height: 44)
        .background(Color(BookAppearance.toolbarColor))
    }

    private func toolbarButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 26)
                .background(Color(BookAppearance.toolbarControlColor), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.8))
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Текст і кнопки гортання

    private var readingArea: some View {
        ZStack {
            // Явний папір під обгорткою. Види самого навігатора вже кольору
            // паперу (перевірено дампом ієрархії), але смуги в зоні безпечної
            // області лишалися білими — їх малює шар SwiftUI навколо
            // UIViewControllerRepresentable, не UIKit.
            Color(BookAppearance.paperColor)

            ReaderViewControllerWrapper(viewController: host)

            HStack(spacing: 0) {
                pageTurnButton(.backward)
                Spacer()
                pageTurnButton(.forward)
            }

            if !isDocumentReady {
                Color(BookAppearance.paperColor)
                    .transition(.opacity)
            }
        }
    }

    /// Висока заокруглена смуга біля краю.
    ///
    /// Сидить у бічному полі сторінки (`BookAppearance.sideMargin`), тож текст
    /// під неї не підлазить. Без наведення майже невидима — щоб не відволікала
    /// від читання; під вказівником проявляється.
    private func pageTurnButton(_ direction: PageDirection) -> some View {
        let isHovered = hoveredButton == direction
        let forward = direction == .forward
        let isAvailable = canTurn(direction)

        return Button {
            Task {
                if forward {
                    await host.goForward()
                } else {
                    await host.goBackward()
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(BookAppearance.inkColor).opacity(isHovered ? 0.13 : 0.03))
                .frame(width: BookAppearance.pageTurnButtonWidth)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 60)
                .overlay {
                    Image(systemName: forward ? "arrow.right" : "arrow.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            Color(BookAppearance.inkColor).opacity(isHovered ? 0.55 : 0.12)
                        )
                }
        }
        .buttonStyle(.plain)
        // Ховаємо прозорістю, а не прибиранням із ієрархії: так колонка
        // тексту не смикається, коли кнопка зникає на краю книги.
        .opacity(isAvailable ? 1 : 0)
        .disabled(!isAvailable)
        .animation(.easeOut(duration: 0.15), value: isAvailable)
        .onHover { hovering in
            guard isAvailable else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredButton = hovering ? direction : nil
            }
        }
        .accessibilityLabel(forward ? "Наступна сторінка" : "Попередня сторінка")
    }

    // MARK: - Підвал

    private var bottomBar: some View {
        VStack(spacing: 0) {
            progressBar
            HStack {
                Text(locator?.title ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 16)
                Text(pageLabel)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(Color(BookAppearance.footerColor))
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle()
                    .fill(Color(BookAppearance.paperColor).opacity(0.75))
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 3)
    }

    private var progress: Double {
        min(max(locator?.locations.totalProgression ?? 0, 0), 1)
    }

    /// Сторінок як таких у reflowable-книзі немає: їх кількість залежить від
    /// шрифту й розміру вікна. Позиції Readium стабільні, тому рахунок ведемо
    /// по них і додаємо відсоток, щоб число мало сенс.
    private var pageLabel: String {
        let percent = Int((progress * 100).rounded())
        guard host.totalPositions > 0, let position = locator?.locations.position else {
            return "\(percent)%"
        }
        return "Сторінка \(position) з \(host.totalPositions) · \(percent)%"
    }
}
