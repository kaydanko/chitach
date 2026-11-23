import ReadiumNavigator
// Чому `@preconcurrency` — див. Sources/Reader/ReaderHostViewController.swift.
@preconcurrency import ReadiumShared
import Testing
import UIKit
@testable import Chytach

/// Інтеграційні тести навігатора.
///
/// Навігатор живе у WKWebView, тож йому потрібні вікно і працюючий run loop —
/// звідси реальне `UIWindow` і очікування за умовою.
///
/// `waitUntil` опитує стан із таймаутом. Це не та сама річ, що заборонений
/// планом `asyncAfter` з магічною затримкою в Sources/Reader: тут є явна умова
/// виходу і явний провал по таймауту. У продакшн-коді Фази 0.5 чекатимемо на
/// `viewportDidChange`, а не опитуванням.
@MainActor
@Suite("Навігатор", .serialized)
struct NavigatorIntegrationTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(
            Bundle(for: BundleToken.self).url(forResource: name, withExtension: "epub"),
            "фікстура \(name).epub не потрапила в бандл тестів"
        )
    }

    /// Вікно прив'язане до живої сцени застосунку.
    ///
    /// Це не дрібниця. `UIWindow(frame:)` без сцени ніхто не відмальовує, і
    /// `PaginationView.layoutSubviews` не виконується після додавання
    /// розворотів: вони лишаються розміром 0×0. Тоді сторінка не має ширини,
    /// відновлення позиції дає нуль, а гортати нікуди — тест міряє артефакт,
    /// а не навігатор. З живою сценою розвороти 390×844, як у застосунку.
    private func makeWindow() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        return window
    }

    /// Піднімає навігатор у вікні й чекає, доки з'явиться перша позиція.
    ///
    /// Увага: після відновлення (`restoringTo`) `currentLocation` не `nil` від
    /// самого початку — Readium виставляє її з `initialLocation` в `init`. Тож
    /// ця перевірка не доводить, що книга відкрилась.
    ///
    /// `beforeShow` — щоб підписатися на події до того, як вікно з'явилось: без
    /// відновлення перша подія приходить ще всередині очікування нижче, і
    /// обробник, поставлений після повернення, її б не побачив.
    private func makeReader(
        restoringTo restored: Locator? = nil,
        waitsForPosition: Bool = true,
        beforeShow: (ReaderHostViewController) -> Void = { _ in }
    ) async throws -> (host: ReaderHostViewController, window: UIWindow) {
        let opened = try await ReadiumPublicationService()
            .open(fileURL: fixture("childrens-literature"))

        let bookURL = try fixture("childrens-literature")
        let navigator = try EPUBNavigatorViewController(
            publication: opened.publication,
            initialLocation: restored,
            config: BookAppearance.navigatorConfiguration(twoColumns: false)
        )
        let host = ReaderHostViewController(
            navigator: navigator,
            bookURL: bookURL,
            startsTwoColumns: false
        )

        beforeShow(host)

        let window = makeWindow()
        window.rootViewController = host
        window.makeKeyAndVisible()

        if waitsForPosition {
            try await waitUntil("навігатор віддав першу позицію") {
                navigator.currentLocation != nil
            }
        }

        return (host, window)
    }

    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(15),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("таймаут \(timeout): \(what)")
        throw CancellationError()
    }

    /// Перший звітований viewport поблизу цілі відновлення й останній.
    ///
    /// «Поблизу» — у межах 2% книги: початок розділу (0,033) від цілі (0,8)
    /// відрізняється на порядок більше. Допуск не точний навмисно: відновлена
    /// сторінка не збігається з ціллю до пікселя.
    private final class ViewportLog {
        var restored: NavigatorViewport?
        var latest: NavigatorViewport?
        let target: Double
        init(target: Double) { self.target = target }

        func record(_ viewport: NavigatorViewport) {
            latest = viewport
            if restored == nil, abs(viewport.progression.lowerBound - target) < 0.02 {
                restored = viewport
            }
        }
    }

    /// Гортання має зсунути саме відновлену сторінку на одну вперед: нижня
    /// межа попередньої — верхня наступної. Просте «позиція змінилась» тут не
    /// годиться: хибна відновлена позиція теж не збігається з ціллю.
    private func expectPageTurned(_ log: ViewportLog) throws {
        let before = try #require(log.restored, "книга не відкрилась на відновленій позиції")
        let after = try #require(log.latest)
        #expect(
            after.progression.lowerBound >= before.progression.upperBound - 0.0005,
            "сторінка не перегорнулась: \(before.progression) → \(after.progression)"
        )
    }

    /// Виміряна причина вади, яку довго шукали.
    ///
    /// Readium відкриває розворот і лише потім виконує початкову прокрутку:
    /// у `spreadDidLoad` він чекає 0,2 с «поки верстка осяде», тоді йде до
    /// `pendingLocation`, і тільки після цього показує розворот (`alpha = 1`).
    /// Усе, що хост зробив до цього, перекривається прокруткою.
    ///
    /// Звідси два прояви.
    /// - Відкрито посеред розділу: навігатор спершу звітує про початок розділу
    ///   (прогрес 0), через 100–700 мс — про відновлену позицію. Гортання між
    ///   цими подіями приймалося (`true`) і губилося.
    /// - Відкрито на початку розділу або книги: подія одна, і вона вірна, але
    ///   прокрутка «до нуля» все одно виконується ще 0,2 с і вбиває гортання,
    ///   не лишаючи жодної події.
    ///
    /// Гортаємо в ту мить, коли навігатор уперше повідомив позицію. Тест
    /// керується подіями, а не таймером: від холодного старту WebKit він не
    /// залежить.
    @Test(
        "гортання, видане щойно навігатор звітував позицію, не губиться",
        // 0,8 — посеред розділу; 0,034 — на першій сторінці розділу `s04`, тобто
        // прокрутка «майже до нуля» всередині багатосторінкового розділу (на
        // початку книги розділ — одна сторінка, і гортання там стрибає в інший
        // ресурс, а не прокручує, тож цей випадок вади не виявляє); nil — книга
        // без збереженої позиції.
        arguments: [0.8, 0.034, nil] as [Double?]
    )
    func pageTurnSurvivesRestore(restoringToProgression progression: Double?) async throws {
        let publication = try await ReadiumPublicationService()
            .open(fileURL: fixture("childrens-literature")).publication
        var restored: Locator?
        if let progression {
            restored = await publication.locate(progression: progression)
            try #require(restored != nil, "локатор для прогресу \(progression) не знайдено")
        }
        let target = restored?.locations.totalProgression ?? 0

        let log = ViewportLog(target: target)
        var turned = false
        var turnResult: Bool?
        let (_, window) = try await makeReader(restoringTo: restored, waitsForPosition: false) { host in
            host.onViewportChange = { [unowned host] viewport in
                guard let viewport else { return }
                log.record(viewport)
                guard !turned else { return }
                turned = true
                Task { turnResult = await host.goForward() }
            }
        }
        defer { window.isHidden = true }

        try await waitUntil("прийшла перша позиція") { turned }
        try await waitUntil("гортання завершилось") { turnResult != nil }
        #expect(turnResult == true, "гортання має бути прийняте")
        // Дати анімації гортання закінчитись.
        try await Task.sleep(for: .seconds(2))

        try expectPageTurned(log)
    }

    /// Той самий сценарій, але гортання просять ще до появи першої позиції —
    /// як користувач, що торкнувся екрана, поки книга вантажиться. Тут важливо,
    /// що очікування готовності не закінчується завчасно: на холодному старті
    /// WebKit перша позиція приходить пізніше за три секунди.
    @Test("гортання, видане під час вантаження, не губиться")
    func pageTurnRequestedWhileLoadingSurvivesRestore() async throws {
        let publication = try await ReadiumPublicationService()
            .open(fileURL: fixture("childrens-literature")).publication
        let restored = try #require(await publication.locate(progression: 0.8))
        let target = try #require(restored.locations.totalProgression)

        let log = ViewportLog(target: target)
        let (host, window) = try await makeReader(restoringTo: restored, waitsForPosition: false) { host in
            host.onViewportChange = { viewport in
                if let viewport { log.record(viewport) }
            }
        }
        defer { window.isHidden = true }

        #expect(await host.goForward(), "гортання має бути прийняте")
        try await waitUntil("книга відкрилась на відновленій позиції") { log.restored != nil }
        try await Task.sleep(for: .seconds(2))

        try expectPageTurned(log)
    }

    /// Та сама причина б'є по збереженому місцю читання. Хост пише позицію на
    /// кожну зміну, і проміжна позиція (початок розділу) затирала справжню на
    /// ті 100–700 мс. Якби застосунок закрили саме тоді, книга відкрилась би на
    /// початку розділу.
    @Test("проміжна позиція не затирає збережене місце читання")
    func storedPositionSurvivesRestore() async throws {
        let bookURL = try fixture("childrens-literature")
        let publication = try await ReadiumPublicationService().open(fileURL: bookURL).publication
        let restored = try #require(await publication.locate(progression: 0.8))
        let target = try #require(restored.locations.totalProgression)

        ReadingPositionStore.save(restored, for: bookURL)
        defer { ReadingPositionStore.forget(bookURL) }

        var reachedRestored = false
        let (_, window) = try await makeReader(restoringTo: restored, waitsForPosition: false) { host in
            host.onViewportChange = { viewport in
                if let viewport, abs(viewport.progression.lowerBound - target) < 0.02 {
                    reachedRestored = true
                }
            }
        }
        defer { window.isHidden = true }

        // Опитуємо сховище густо: вікно, коли там лежить хибне значення, —
        // сотні мілісекунд, але не нескінченні.
        var lowest = 1.0
        let deadline = ContinuousClock.now + .seconds(15)
        var settledAt: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if let stored = ReadingPositionStore.locator(for: bookURL)?.locations.totalProgression {
                lowest = min(lowest, stored)
            }
            if reachedRestored, settledAt == nil { settledAt = .now + .milliseconds(500) }
            if let settledAt, ContinuousClock.now >= settledAt { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(reachedRestored, "книга не відкрилась на відновленій позиції")
        #expect(lowest > 0.5, "у сховищі побувала проміжна позиція \(lowest) замість \(target)")
    }

    @Test("goForward просуває позицію, goBackward повертає")
    func pageTurning() async throws {
        let (host, _) = try await makeReader()
        let navigator = host.navigator

        let start = try #require(navigator.currentLocation)
        let startProgression = start.locations.totalProgression ?? 0

        #expect(await navigator.goForward(options: NavigatorGoOptions()))
        try await waitUntil("позиція зросла після goForward") {
            (navigator.currentLocation?.locations.totalProgression ?? 0) > startProgression
        }

        let afterForward = try #require(navigator.currentLocation?.locations.totalProgression)
        #expect(afterForward > startProgression)

        #expect(await navigator.goBackward(options: NavigatorGoOptions()))
        try await waitUntil("позиція повернулась після goBackward") {
            (navigator.currentLocation?.locations.totalProgression ?? 1) <= startProgression
        }

        let afterBack = try #require(navigator.currentLocation?.locations.totalProgression)
        #expect(afterBack <= startProgression)
    }

    @Test("locationDidChange повідомляє хост про зміну позиції")
    func locationDelegateFires() async throws {
        let (host, _) = try await makeReader()

        var received: [Locator] = []
        host.onLocationChange = { received.append($0) }

        #expect(await host.navigator.goForward(options: NavigatorGoOptions()))
        try await waitUntil("прийшов колбек зміни позиції") { !received.isEmpty }

        #expect(!received.isEmpty)
    }

    /// Головний інструмент Фази 0.5. Якщо viewport не приходить — чекати
    /// завершення перепагінації не буде на чому.
    @Test("viewportDidChange приходить і несе діапазон прогресу")
    func viewportIsReported() async throws {
        let (host, _) = try await makeReader()

        try await waitUntil("viewport заповнився") { host.currentViewport != nil }

        let viewport = try #require(host.currentViewport)
        #expect(viewport.progression.lowerBound >= 0)
        #expect(viewport.progression.upperBound <= 1)
        #expect(!viewport.resources.isEmpty)
    }

    @Test("перехід за локатором зі змісту потрапляє в той самий ресурс")
    func goToTableOfContentsEntry() async throws {
        let (host, _) = try await makeReader()
        let navigator = host.navigator

        let toc = try await navigator.publication.tableOfContents().get()
        let target = try #require(toc.dropFirst(2).first ?? toc.last)

        #expect(await navigator.go(to: target, options: NavigatorGoOptions()))
        try await waitUntil("навігатор перейшов у цільовий ресурс") {
            navigator.currentLocation?.href.string.contains(
                target.url().removingQuery().removingFragment().lastPathSegment ?? "\u{0}"
            ) ?? false
        }
    }
}

private final class BundleToken {}
