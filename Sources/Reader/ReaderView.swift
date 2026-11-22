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

    /// Куди веде користувач смугою. Поки не `nil`, смуга показує саме це,
    /// а не те, що повідомляє навігатор.
    ///
    /// Раніше замість цього був прапорець «тягнемо», який скидався в ту ж
    /// мить, коли палець відпускали. Перехід при цьому ще тривав, тож смуга
    /// встигала повернутися на стару позицію й лише потім стрибала на нову —
    /// звідси смикання й відчуття, що повзунок живе своїм життям. Ціль
    /// тримаємо доти, доки сторінка справді не стане на місце.
    @State private var scrubTarget: Double?
    @State private var isDraggingScrubber = false
    @State private var isHoveringScrubber = false

    /// Зміст книги.
    ///
    /// Читаємо одразу при відкритті, хоч це й зайвий виклик для книжок, де
    /// змісту немає: інакше неможливо вирішити, чи показувати кнопку. А
    /// кнопка, що відкриває порожнечу, гірша за її відсутність.
    @State private var contents: [TableOfContentsEntry] = []
    @State private var isShowingContents = false

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
            host.onLocationChange = { newLocator in
                locator = newLocator
            }
            host.onViewportChange = { newViewport in
                viewport = newViewport

                // Непорожній viewport означає, що сторінка вже відмальована.
                guard newViewport != nil, !isDocumentReady else { return }
                withAnimation(.easeOut(duration: 0.18)) { isDocumentReady = true }
            }
            // ⌘ + коліщатко миші.
            host.onFontSizeStep = { steps in store.stepFontSize(by: steps) }

            Task {
                contents = TableOfContentsEntry.flatten(await host.tableOfContents())

                // Перевірка вигляду без вказівника — так само, як
                // `--settings` і `--library`. Прибрати разом з ними, коли
                // запрацює тест-ранер.
                if CommandLine.arguments.contains("--contents"), contents.count > 1 {
                    isShowingContents = true
                }
            }
        }
        .onChange(of: store.pendingJump) { _, jump in
            guard let jump else { return }
            store.pendingJump = nil
            Task {
                switch jump {
                case .start: await host.goToStart()
                case .end: await host.goToEnd()
                }
            }
        }
        .onChange(of: store.appearanceRevision) {
            Task { await host.refreshAppearance() }
        }
        // `.environment(store)` на вмісті аркушів — не зайвина. Аркуш
        // показується в окремому контексті, і звіт про аварію з Mac показує
        // спрацьовану перевірку саме в пошуку значення середовища. Явна
        // передача знімає залежність від того, як середовище успадковується.
        .sheet(isPresented: $store.isShowingSettings) {
            AppearanceSettingsView()
                .environment(store)
        }
        .sheet(isPresented: $store.isShowingLibrary) {
            LibraryView(onClose: { store.isShowingLibrary = false })
                .environment(store)
        }
        .sheet(isPresented: $isShowingContents) {
            TableOfContentsView(
                entries: contents,
                currentResource: locator?.href.removingQuery().removingFragment().string,
                onSelect: { entry in
                    isShowingContents = false
                    Task { await host.go(to: entry.link) }
                },
                onClose: { isShowingContents = false }
            )
        }
    }

    // MARK: - Шапка

    private var topBar: some View {
        HStack(spacing: 14) {
            toolbarButton("chevron.left", label: "Закрити книгу") { store.closeBook() }
            toolbarButton("books.vertical", label: "Бібліотека") {
                store.refreshLibrary()
                store.isShowingLibrary = true
            }
            toolbarButton("folder", label: "Відкрити файл") { store.isImporting = true }
            // Менше двох записів — це не зміст: у звичайному тексті в нього
            // потрапляє єдина «Частина 1», і переходити нікуди. Кнопка, що
            // відкриває таку порожнечу, гірша за її відсутність.
            if contents.count > 1 {
                toolbarButton("list.bullet", label: "Зміст") { isShowingContents = true }
            }

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
            scrubber

            HStack(spacing: 10) {
                jumpButton("chevron.left.to.line", label: "На початок книги") {
                    await host.goToStart()
                }

                Text(locator?.title ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Text(pageLabel)
                    .monospacedDigit()

                jumpButton("chevron.right.to.line", label: "У кінець книги") {
                    await host.goToEnd()
                }
            }
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(Color(BookAppearance.footerColor))
    }

    /// Смуга переходу на довільне місце книги.
    ///
    /// Гортання по одній сторінці було єдиним способом рухатися: щоб
    /// дістатися кінця тисячосторінкової книги, довелося б клацнути тисячу
    /// разів.
    ///
    /// У спокої це тонка смуга без мітки, щоб не відтягувати увагу від
    /// тексту. Під вказівником вона товщає, зʼявляється мітка з номером
    /// сторінки, і її можна тягнути.
    ///
    /// Висота блоку стала, товщає лише сама смуга — інакше підвал
    /// підстрибував би під вказівником.
    private var scrubber: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let isActive = isHoveringScrubber || isDraggingScrubber || scrubTarget != nil
            let shown = shownProgress
            let trackHeight: CGFloat = isActive ? 9 : 3
            let thumbSize: CGFloat = 17
            let centre = min(max(width * shown, thumbSize / 2), max(width - thumbSize / 2, thumbSize / 2))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color(BookAppearance.paperColor).opacity(0.85))
                    .frame(width: max(0, width * shown), height: trackHeight)

                if isActive {
                    Circle()
                        .fill(Color(BookAppearance.paperColor))
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: centre - thumbSize / 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Ціль наведення й захоплення — уся висота блоку, а не сама
            // смуга: у тонку смугу в 3 pt влучити важко.
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.14), value: isActive)
            .onHover { hovering in
                isHoveringScrubber = hovering
            }
            // Гортаємо вже під час руху, а не після відпускання: інакше
            // вибирати місце доводиться наосліп, за самим лише номером
            // сторінки на мітці.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingScrubber = true
                        let target = Self.position(of: value.location.x, width: width)
                        scrubTarget = target
                        host.scrub(to: target)
                    }
                    .onEnded { value in
                        let target = Self.position(of: value.location.x, width: width)
                        scrubTarget = target
                        isDraggingScrubber = false
                        host.scrub(to: target)

                        Task {
                            await host.finishScrubbing()
                            // Смуга могла вже піти за новим рухом — тоді вона
                            // належить йому, а не цьому переходу.
                            guard !isDraggingScrubber, scrubTarget == target else { return }
                            scrubTarget = nil
                        }
                    }
            )
            .overlay(alignment: .topLeading) {
                if isActive {
                    scrubberLabel
                        .offset(x: labelOffset(centre: centre, width: width), y: -26)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 12)
    }

    /// Мітка з номером сторінки над міткою-повзунком.
    private var scrubberLabel: some View {
        Text(scrubberPageText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color(BookAppearance.voidColor))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color(BookAppearance.paperColor), in: .capsule)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .fixedSize()
    }

    private var scrubberPageText: String {
        let shown = shownProgress
        guard host.totalPositions > 0 else {
            return "\(Int((shown * 100).rounded()))%"
        }
        let page = max(1, Int((shown * Double(host.totalPositions)).rounded()))
        return "\(page) / \(host.totalPositions)"
    }

    /// Мітка йде за повзунком, але не вилазить за краї смуги.
    private func labelOffset(centre: CGFloat, width: CGFloat) -> CGFloat {
        let estimated: CGFloat = 86
        return min(max(centre - estimated / 2, 0), max(width - estimated, 0))
    }

    private func jumpButton(
        _ systemName: String,
        label: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.55))
        .help(label)
        .accessibilityLabel(label)
    }

    private var progress: Double {
        min(max(locator?.locations.totalProgression ?? 0, 0), 1)
    }

    /// Частка, яку показує смуга: ціль користувача має перевагу над
    /// повідомленням навігатора, доки перехід не завершиться.
    private var shownProgress: Double {
        min(max(scrubTarget ?? progress, 0), 1)
    }

    private static func position(of x: CGFloat, width: CGFloat) -> Double {
        min(max(Double(x / max(width, 1)), 0), 1)
    }

    /// Сторінок як таких у reflowable-книзі немає: їх кількість залежить від
    /// шрифту й розміру вікна. Позиції Readium стабільні, тому рахунок ведемо
    /// по них і додаємо відсоток, щоб число мало сенс.
    private var pageLabel: String {
        let shown = shownProgress
        let percent = Int((shown * 100).rounded())

        // Поки повзунок ведуть, показуємо, куди він веде: сторінка вже
        // гортається слідом, але позиція від навігатора приходить із
        // запізненням на один перехід.
        if isDraggingScrubber, host.totalPositions > 0 {
            let target = max(1, Int((shown * Double(host.totalPositions)).rounded()))
            return "→ сторінка \(target) з \(host.totalPositions) · \(percent)%"
        }

        guard host.totalPositions > 0, let position = locator?.locations.position else {
            return "\(percent)%"
        }
        return "Сторінка \(position) з \(host.totalPositions) · \(percent)%"
    }
}
