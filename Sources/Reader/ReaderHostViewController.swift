import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

/// Контейнер, у якому живе Readium Navigator.
///
/// Скопійовано з docs/Guides/Navigator/SwiftUI.md @ 3.11.0.
///
/// Хост-контролер обовʼязковий, а не зручність: без нього не працюють кастомні
/// `EditingAction` (меню виділення, Фаза 3) і перехоплення подій у responder
/// chain. Тут же живуть `prefersStatusBarHidden` і
/// `prefersHomeIndicatorAutoHidden` — SwiftUI-модифікатори до UIKit-навігатора
/// не дістають.
final class ReaderHostViewController: UIViewController {
    let navigator: EPUBNavigatorViewController

    /// Зміна позиції. Запис у БД зʼявиться у Фазі 2.
    var onLocationChange: ((Locator) -> Void)?

    /// Зміна видимої області. Сигнал, за яким ми дізнаємося, що перепагінація
    /// завершилась і можна безпечно повертатися до збереженого `Locator`.
    /// `nil` означає, що навігатор ще ініціалізується.
    var onViewportChange: ((NavigatorViewport?) -> Void)?

    private(set) var currentViewport: NavigatorViewport?

    /// Загальна кількість позицій у книзі — знаменник для «сторінка N з M».
    ///
    /// Readium не оперує сторінками: вони залежать від шрифту й розміру
    /// екрана. Позиції стабільні, тому рахуємо їх.
    private(set) var totalPositions = 0

    /// Назва книги для шапки.
    var bookTitle: String {
        navigator.publication.metadata.title ?? String(localized: "Без назви", bundle: AppLanguage.bundle)
    }

    /// Крайові тапи та стрілки клавіатури для гортання.
    ///
    /// Штатний компонент Readium — власний `UITapGestureRecognizer` писати не
    /// треба. Тримаємо сильне посилання: адаптер володіє токенами підписки на
    /// події навігатора і при звільненні їх знімає.
    /// `animatedTransition: true` вмикає анімацію перегортання.
    private let directionalNavigation = DirectionalNavigationAdapter(animatedTransition: true)

    /// Поточний режим розвороту. Міняється зі зміною ширини вікна.
    private var isTwoColumns: Bool
    private var isRelayouting = false

    /// Очікувачі найближчої зміни viewport.
    private var viewportWaiters: [CheckedContinuation<Void, Never>] = []

    /// Книга, яку читаємо. Потрібна, щоб зберігати позицію під правильним
    /// ключем.
    private let bookURL: URL

    init(navigator: EPUBNavigatorViewController, bookURL: URL, startsTwoColumns: Bool) {
        self.navigator = navigator
        self.bookURL = bookURL
        isTwoColumns = startsTwoColumns
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init?(coder:) не підтримується")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigator.delegate = self
        // bg=nil при isOpaque=true малює білим.
        view.backgroundColor = BookAppearance.paperColor
        // Readium відсуває webview на висоту безпечної області, і в цій
        // щілині видно шар під ним. Вимикаємо врахування безпечної області:
        // вертикальні поля дають власні панелі, дублювати їх немає потреби.
        view.insetsLayoutMarginsFromSafeArea = false
        viewRespectsSystemMinimumLayoutMargins = false
        additionalSafeAreaInsets = .zero

        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        clearNavigatorBackground()
        directionalNavigation.bind(to: navigator)
        installScrollWheelZoom()

        // Найяскравіший спалах — не при гортанні, а при відкритті книги:
        // webview створюється білим, а підкладку ми ставили аж за першим
        // повідомленням про сторінку. Вікно між цими двома моментами й
        // випалювало очі, тому фарбуємо з самого початку і триваліше:
        // перше завантаження довше за перехід між сторінками.
        paintBackdropWhileLoading(for: .seconds(3))

        Task { [weak self] in
            guard let self else { return }
            totalPositions = (try? await navigator.publication.positions().get().count) ?? 0
        }
    }

    // MARK: - Гортання

    /// Чи триває перехід між сторінками.
    ///
    /// Накладені анімовані переходи лишають прокрутку між сторінками: видно
    /// край попередньої, а поточна зрізана. Поки один триває, наступні запити
    /// ігноруємо — це звичайна поведінка читалок і надійніше, ніж намагатися
    /// зшивати два переходи.
    private var isTurningPage = false

    @discardableResult
    func goForward() async -> Bool {
        await turnPage { await navigator.goForward(options: NavigatorGoOptions(animated: true)) }
    }

    @discardableResult
    func goBackward() async -> Bool {
        await turnPage { await navigator.goBackward(options: NavigatorGoOptions(animated: true)) }
    }

    /// Переходить на задану частку книги (0…1).
    ///
    /// Потрібно для повзунка в підвалі: гортати по одній сторінці до кінця
    /// тисячосторінкової книги неможливо.
    @discardableResult
    func go(toProgression progression: Double) async -> Bool {
        let clamped = min(max(progression, 0), 1)
        guard let locator = await navigator.publication.locate(progression: clamped) else {
            return false
        }
        paintBackdropWhileLoading()
        return await turnPage {
            await navigator.go(to: locator, options: NavigatorGoOptions(animated: false))
        }
    }

    /// Фарбує webview, доки Readium збирає нову сторінку.
    ///
    /// Підкладка ставиться за подією про зміну сторінки, але webview для
    /// нового розділу створюється раніше — і до першої такої події його
    /// видно білим. Тому під час переходу коротко повторюємо, щоб застати
    /// новостворений вид.
    ///
    /// Саме під час переходу, а не постійно: обхід ієрархії на кожному
    /// проході верстки колись уже лишав сторінку зсунутою посеред анімації
    /// гортання. Переходи зі смуги та змісту неанімовані, тож тут безпечно.
    private func paintBackdropWhileLoading(for duration: Duration = .milliseconds(400)) {
        showLoadingCover()
        enforceWebViewBackdrop()

        Task { [weak self] in
            let deadline = ContinuousClock.now + duration
            while ContinuousClock.now < deadline {
                // Пʼятдесят мілісекунд, а не кожен кадр: колір новий webview
                // має вже від народження (проксі вигляду в AppDelegate), тож
                // тут лишилося дотягнути решту — прозорість і підкладку під
                // документом. Обхід ієрархії на кожному кадрі протягом трьох
                // секунд був би сотнею зайвих проходів заради того, що не
                // змінюється так часто.
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                enforceWebViewBackdrop()
            }
        }
    }

    /// Непрозорий шар, яким накриваємо читалку, поки вантажиться сторінка.
    ///
    /// Чому не досить пофарбувати webview. Біле малює сам процес WebKit
    /// усередині свого шару — вище за тло `UIView`, — і ззовні туди не
    /// дістатися: перевірено `backgroundColor`, `underPageBackgroundColor`
    /// і проксі вигляду. У симуляторі це спрацьовувало, на Mac проблиск
    /// лишався, бо там інший шлях складання шарів.
    ///
    /// Власний шар від нутрощів WebKit не залежить зовсім: він просто лежить
    /// зверху, доки сторінка не готова.
    private lazy var loadingCover: UIView = {
        let cover = UIView()
        cover.backgroundColor = BookAppearance.loadingBackdropColor
        cover.isUserInteractionEnabled = false
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.alpha = 0
        return cover
    }()

    /// Чи накрито читалку просто зараз. Для діагностики: застряглий шар
    /// означав би чорний екран замість книги, і помітити це треба машинно.
    var isLoadingCoverVisible: Bool {
        loadingCover.superview != nil && loadingCover.alpha > 0.01
    }

    private func showLoadingCover() {
        loadingCover.frame = view.bounds
        view.addSubview(loadingCover)
        view.bringSubviewToFront(loadingCover)
        loadingCover.layer.removeAllAnimations()
        loadingCover.alpha = 1
    }

    /// Прибирає шар, коли сторінку вже розкладено.
    ///
    /// Не миттєво, а коротким згасанням: воно саме й перекриває ту мить,
    /// коли WebKit домальовує сторінку. Різкий зріз лишав би шанс побачити
    /// недомальоване.
    private func hideLoadingCover() {
        guard loadingCover.alpha > 0 else { return }
        UIView.animate(withDuration: 0.18) {
            self.loadingCover.alpha = 0
        } completion: { finished in
            if finished { self.loadingCover.removeFromSuperview() }
        }
    }

    // MARK: Перемотування смугою

    /// Остання запитана частка книги.
    ///
    /// Під час перетягування запитів десятки на секунду, а сенс має лише
    /// найсвіжіший: решта вже застаріла, доки виконувався попередній перехід.
    private var pendingScrub: Double?
    private var scrubTask: Task<Void, Never>?

    /// Частка, на яку перемотували востаннє, — щоб знати, чого чекати.
    private var lastScrubTarget: Double?

    /// Остання частка, **віддана інтерфейсу** через ``onLocationChange``.
    ///
    /// Саме вона, а не `navigator.currentLocation`: між оновленням позиції
    /// всередині навігатора й викликом делегата є проміжок, і якби смуга
    /// оживала за внутрішнім значенням, вона встигла б показати стару
    /// сторінку на один кадр.
    private var lastReportedProgression: Double?

    /// Наскільки близько до цілі вважаємо, що прибули.
    ///
    /// Навігатор стає на межу сторінки, а не рівно на запитану частку, тож
    /// допуск має бути в масштабі сторінки. Півтори сторінки — щоб округлення
    /// в обидва боки не лишало нас у нескінченному очікуванні.
    private var scrubSettleTolerance: Double {
        totalPositions > 0 ? max(1.5 / Double(totalPositions), 0.004) : 0.02
    }

    /// Просить перейти на задану частку книги, не чекаючи завершення.
    ///
    /// Окремо від ``go(toProgression:)`` саме через поведінку під
    /// перетягуванням. Якби запити йшли прямо, вони або шикувалися б у чергу
    /// — і повзунок відставав би на секунди, — або їх відкидав би запобіжник
    /// `turnPage`, який не пускає другий перехід поверх першого. Тут замість
    /// черги й відкидання одна комірка: новий запит витісняє невиконаний
    /// старий, і жодне натискання не губиться.
    func scrub(to progression: Double) {
        pendingScrub = min(max(progression, 0), 1)
        guard scrubTask == nil else { return }
        scrubTask = Task { @MainActor [weak self] in
            await self?.drainScrubRequests()
        }
    }

    /// Чекає, доки перемотування дійде до останньої запитаної частки.
    ///
    /// Потрібне інтерфейсу: поки воно триває, смуга показує, куди веде
    /// користувач, а не де стоїть навігатор. Повернути їй звичайну поведінку
    /// можна лише тоді, коли сторінка справді стала на місце, — інакше
    /// повзунок блимне старою позицією.
    func finishScrubbing() async {
        while let task = scrubTask {
            await task.value
            if pendingScrub == nil { break }
        }
        await waitForScrubToSettle()
    }

    /// Чекає, доки навігатор повідомить, що вже на місці.
    ///
    /// `navigator.go(to:)` повертає керування раніше, ніж спрацьовує делегат
    /// із новою позицією. Якщо віддати смугу навігаторові одразу після
    /// переходу, вона встигне блимнути попередньою сторінкою — те саме
    /// смикання, лише коротше. Обмежено за часом: якщо навігатор із якоїсь
    /// причини не доповість, смуга все одно оживе.
    private func waitForScrubToSettle(timeout: Duration = .seconds(2)) async {
        guard let target = lastScrubTarget else { return }
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if let now = lastReportedProgression, abs(now - target) <= scrubSettleTolerance {
                return
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func drainScrubRequests() async {
        defer {
            scrubTask = nil
            // Запис позиції під час перемотування пропускався — зберігаємо ту,
            // на якій зупинилися.
            if let locator = navigator.currentLocation {
                ReadingPositionStore.save(locator, for: bookURL)
            }
        }

        while let target = pendingScrub {
            pendingScrub = nil
            lastScrubTarget = target
            await waitWhilePageTurns()
            _ = await go(toProgression: target)
        }
    }

    /// Пережидає анімований перехід від кнопок гортання.
    ///
    /// Без цього `turnPage` відкинув би запит перемотування, і смуга
    /// «не спрацювала б» — саме так це й виглядає збоку. Обмежено за часом:
    /// зависнути тут не можна.
    private func waitWhilePageTurns(timeout: Duration = .milliseconds(600)) async {
        let deadline = ContinuousClock.now + timeout
        while isTurningPage, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // MARK: Зміст

    /// Зміст книги. Порожній, якщо його немає.
    ///
    /// Запитуємо щоразу, а не кешуємо: Readium сам тримає розібрану
    /// публікацію, виклик дешевий, а кеш довелося б скидати при зміні книги.
    func tableOfContents() async -> [ReadiumShared.Link] {
        (try? await navigator.publication.tableOfContents().get()) ?? []
    }

    @discardableResult
    func go(to link: ReadiumShared.Link) async -> Bool {
        paintBackdropWhileLoading()
        return await turnPage {
            await navigator.go(to: link, options: NavigatorGoOptions(animated: false))
        }
    }

    @discardableResult
    func goToStart() async -> Bool {
        await go(toProgression: 0)
    }

    @discardableResult
    func goToEnd() async -> Bool {
        await go(toProgression: 1)
    }

    private func turnPage(_ move: () async -> Bool) async -> Bool {
        guard !isTurningPage else { return false }
        isTurningPage = true
        defer { isTurningPage = false }

        await waitUntilLaidOut()

        // Readium відмовляє гортати, поки не доклав першу сторінку. Найчастіше
        // це перші секунди після запуску, коли застосунок відновлює місце з
        // минулого разу, — і саме тоді людина тисне гортати. Відмова там
        // означала «нічого не сталося», і дотик зникав безслідно.
        //
        // Тому коротко пробуємо ще. Якщо позиція тим часом змінилася,
        // вважаємо, що перехід усе ж відбувся: повторювати його означало б
        // перегорнути двічі.
        let startedAt = navigator.currentLocation?.locations.totalProgression
        // Вікно повторів рахуємо від миті, коли сторінку вперше розклали, а
        // не від натискання. Так повтори живуть лише в ті перші секунди,
        // коли навігатор ще не готовий, і не додають затримки потім — бо
        // пізніша відмова означає вже справжню межу книги.
        let grace = (firstLayoutAt ?? .now) + Self.layoutGrace

        while true {
            if await move() { return true }
            // Позиція все ж змінилася — перехід відбувся попри відповідь;
            // повторювати означало б перегорнути двічі.
            if navigator.currentLocation?.locations.totalProgression != startedAt {
                return true
            }
            guard ContinuousClock.now < grace else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Скільки після першої верстки ще варто перепитувати навігатор.
    ///
    /// Виміряно: після відновлення збереженої позиції він відмовляє гортати
    /// близько двох секунд. Беремо із запасом.
    private static let layoutGrace: Duration = .seconds(3)

    /// Чекає, доки навігатор розкладе першу сторінку.
    ///
    /// Ознака — перший `viewportDidChange`: доти в книзі ще немає ні сторінок,
    /// ні меж, від яких рахувати наступну. Обмежено за часом, щоб гортання не
    /// зависло, якщо повідомлення не прийде.
    /// Коли навігатор уперше повідомив, що сторінку розкладено.
    private var firstLayoutAt: ContinuousClock.Instant?

    private func waitUntilLaidOut(timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while currentViewport == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Перефарбовує підкладку webview після завантаження сторінки.
    ///
    /// `underPageBackgroundColor` — це колір, яким WebKit малює площу під
    /// вмістом сторінки. Якщо задати його до завантаження, WebKit перерахує
    /// його з тла документа й поверне своє — на практиці біле. Саме тому всі
    /// попередні спроби не діяли: колір ставився зарано.
    ///
    /// Ця сама підкладка дає і спалах при запуску (поки документ не
    /// відмальовано, видно всю її площу), і смугу у 24 pt над текстом, де
    /// документ не починається. Одне джерело — одне виправлення.
    private func enforceWebViewBackdrop() {
        Self.applyBackdrop(to: navigator.view)
    }

    private static func applyBackdrop(to view: UIView) {
        if let webView = view as? WKWebView {
            webView.isOpaque = false
            // Тло самого webview видно, доки документ не відмальовано, —
            // саме воно й блимало білим при переході на іншу сторінку.
            webView.backgroundColor = BookAppearance.loadingBackdropColor
            webView.scrollView.backgroundColor = BookAppearance.loadingBackdropColor
            // А це — площа під уже відмальованим документом. Тут потрібен
            // колір паперу: з нього складається смуга над текстом, якщо
            // документ не починається від самого верху.
            webView.underPageBackgroundColor = BookAppearance.paperColor
        }
        for subview in view.subviews {
            applyBackdrop(to: subview)
        }
    }

    /// Знімає з навігатора успадковану безпечну область.
    ///
    /// Смуги рівно у 24 pt зверху й 25 pt знизу — це безпечна область вікна
    /// (статус-бар і домашній індикатор). Readium відсуває на неї webview, і
    /// в утвореній щілині видно шар під документом. Власне
    /// `additionalSafeAreaInsets = .zero` не допомагає: нуль нічого не
    /// віднімає, він лише не додає. Компенсуємо відʼємним відступом — так
    /// `safeAreaInsets` дочірнього контролера стає нульовим.
    ///
    /// Вертикальні поля дає шапка й підвал, тож нічого не перекривається.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let inherited = view.safeAreaInsets
        navigator.additionalSafeAreaInsets = UIEdgeInsets(
            top: -inherited.top,
            left: -inherited.left,
            bottom: -inherited.bottom,
            right: -inherited.right
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Обхід ієрархії тут більше не робимо. Він писав `isOpaque` і
        // `backgroundColor` на кожному проході верстки, а під час анімації
        // гортання проходів багато — перемальовування посеред анімації
        // прокрутки лишало сторінку зсунутою. Підкладка оновлюється за подією
        // `locationDidChange`, цього достатньо.
        if navigator.view.backgroundColor != BookAppearance.paperColor {
            navigator.view.backgroundColor = BookAppearance.paperColor
        }
        updateColumnsIfNeeded()
    }

    /// Readium перемальовує фон навігатора з `effectiveBackgroundColor` при
    /// кожній зміні налаштувань (`EPUBNavigatorViewController.swift:923`).
    /// Оскільки ми не задаємо `backgroundColor` у преференціях, значення
    /// відкочується до `theme.backgroundColor` — для `.light` це білий, і він
    /// повністю ховає паперову текстуру. Тому фон треба знімати після кожної
    /// зміни налаштувань і на кожному проході верстки.
    private func clearNavigatorBackground() {
        // Колір паперу, а не .clear: сторінка малює своє тло сама, а цей вид
        // лишається видимим вузькими смугами в зоні contentInset. Прозорий
        // він показував біле від WebKit.
        navigator.view.backgroundColor = BookAppearance.paperColor
        Self.makeTransparent(navigator.view)
    }

    /// Знімає непрозорі підкладки з усієї ієрархії навігатора.
    ///
    /// Readium прозорить `EPUBSpreadView`, сам `webView`, його `scrollView` —
    /// але не `WKWebView.underPageBackgroundColor`. Ця властивість зʼявилася в
    /// iOS 15, за замовчуванням біла, і малюється **під** вмістом сторінки,
    /// тому прозорий `--RS__backgroundColor` її не прибирає. Саме вона ховала
    /// паперову текстуру.
    ///
    /// Обходимо ієрархію, бо webview-и в навігаторі приватні й іншого доступу
    /// до них немає. Якщо Readium колись почне робити це сам, метод можна буде
    /// прибрати без наслідків.
    @discardableResult
    private static func makeTransparent(_ view: UIView) -> Int {
        var found = 0
        // Непрозорий вид без кольору (або з повністю прозорим) малює сміття,
        // на практиці — біле. У ієрархії навігатора таких кілька:
        // PaginationView має bg альфи 0 при isOpaque = true, UIScrollView —
        // bg = nil. Саме вони давали білі смуги в зонах, де webview ще не
        // починається. Знімаємо саме прапорець непрозорості, а не фарбуємо:
        // так ці види чесно пропускають папір знизу.
        let hasNoFill = view.backgroundColor == nil
            || (view.backgroundColor?.cgColor.alpha ?? 0) < 0.01
        if hasNoFill, view.isOpaque, !(view is WKWebView) {
            view.isOpaque = false
        }

        if let webView = view as? WKWebView {
            found += 1
            // Пишемо лише те, що справді відрізняється: зайвий запис змушує
            // вид перемальовуватися, а під час анімації це збиває прокрутку.
            if webView.isOpaque { webView.isOpaque = false }
            if webView.backgroundColor != BookAppearance.paperColor {
                webView.backgroundColor = BookAppearance.paperColor
            }
            if webView.scrollView.backgroundColor != BookAppearance.paperColor {
                webView.scrollView.backgroundColor = BookAppearance.paperColor
            }
            // Не .clear, а колір паперу. Прозорість WebKit ігнорує й
            // підмальовує білим; задати колір напряму — єдине, що працює.
            // Ця підкладка видно в зоні contentInset, поза полем документа.
            if webView.underPageBackgroundColor != BookAppearance.paperColor {
                webView.underPageBackgroundColor = BookAppearance.paperColor
            }
        }
        for subview in view.subviews {
            found += makeTransparent(subview)
        }
        return found
    }

    /// Кольори тла всіх `WKWebView` просто зараз.
    ///
    /// Потрібне, щоб довести, що під час завантаження сторінки не видно
    /// білого: сам спалах триває частки секунди й у знімок екрана не
    /// потрапляє, а колір виду зчитати можна будь-коли.
    var webViewBackdrops: [String] {
        Self.collectBackdrops(from: navigator.view)
    }

    private static func collectBackdrops(from view: UIView) -> [String] {
        var result: [String] = []
        if let webView = view as? WKWebView {
            result.append(describe(webView.backgroundColor))
        }
        for subview in view.subviews {
            result += collectBackdrops(from: subview)
        }
        return result
    }

    private static func describe(_ color: UIColor?) -> String {
        guard let color else { return "немає" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Скільки `WKWebView` зараз у ієрархії навігатора. Для діагностики.
    var transparentWebViewCount: Int {
        Self.makeTransparent(navigator.view)
    }

    // MARK: - Розворот і перепагінація

    private func updateColumnsIfNeeded() {
        let wanted = BookAppearance.shouldUseTwoColumns(width: view.bounds.width)
        // Перебудова посеред переходу — ще одне джерело зсуву прокрутки.
        guard wanted != isTwoColumns, !isRelayouting, !isTurningPage else { return }
        isTwoColumns = wanted
        Task { await applyColumns(twoColumns: wanted) }
    }

    // MARK: - Кегль коліщатком миші

    /// Колесо миші з ⌘ змінює розмір тексту.
    ///
    /// На Mac Catalyst події колеса приходять як `UIPanGestureRecognizer` з
    /// `allowedScrollTypesMask`, іншого шляху їх перехопити немає.
    /// `modifierFlags` розпізнавача каже, чи затиснутий ⌘.
    private func installScrollWheelZoom() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollWheel(_:)))
        pan.allowedScrollTypesMask = [.discrete, .continuous]
        pan.allowedTouchTypes = []  // лише вказівник, не дотики
        view.addGestureRecognizer(pan)
    }

    /// Накопичувач: одне «клацання» колеса дає кілька дрібних подій, і без
    /// порогу кегль стрибав би ривками.
    private var wheelAccumulator: CGFloat = 0

    @objc private func handleScrollWheel(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.modifierFlags.contains(.command) else {
            wheelAccumulator = 0
            return
        }

        let delta = recognizer.translation(in: view).y
        recognizer.setTranslation(.zero, in: view)
        wheelAccumulator += delta

        let threshold: CGFloat = 12
        guard abs(wheelAccumulator) >= threshold else { return }

        let steps = Int(wheelAccumulator / threshold)
        wheelAccumulator -= CGFloat(steps) * threshold
        // Прокрутка вгору (додатне зміщення) збільшує кегль.
        onFontSizeStep?(steps)
    }

    /// Повідомляє нагору, на скільки кроків змінити кегль.
    var onFontSizeStep: ((Int) -> Void)?

    /// Міняє кількість колонок, не втрачаючи місце в тексті.
    ///
    /// Порядок критичний і саме такий, як у плані: зберегти `Locator` →
    /// змінити стан → дочекатися нового viewport → повернутися до локатора.
    /// Без очікування текст зʼїжджає на кілька рядків або на сторінку, бо
    /// `go(to:)` відпрацьовує по старій пагінації.
    /// Застосовує поточне оформлення (кегль, кольори), не втрачаючи місце
    /// в тексті. Викликати після зміни налаштувань.
    func refreshAppearance() async {
        view.backgroundColor = BookAppearance.paperColor
        await applyPageStyle()
        await applyColumns(twoColumns: isTwoColumns, force: true)
    }

    /// Оновлює інжектований стиль у вже завантажених сторінках.
    ///
    /// User script спрацьовує лише при завантаженні ресурсу, тому зміну
    /// кольору треба донести окремо — інакше вона проявиться лише після
    /// переходу в інший розділ.
    private func applyPageStyle() async {
        let css = BookAppearance.pageCSS
        let script = """
        (function () {
            var style = document.getElementById("\(BookAppearance.styleElementID)");
            if (!style) {
                style = document.createElement("style");
                style.id = "\(BookAppearance.styleElementID)";
                (document.head || document.documentElement).appendChild(style);
            }
            style.textContent = `\(css)`;
            return true;
        })();
        """
        _ = await navigator.evaluateJavaScript(script)
    }

    private func applyColumns(twoColumns: Bool, force: Bool = false) async {
        _ = force
        isRelayouting = true
        defer { isRelayouting = false }

        let saved = navigator.currentLocation

        navigator.submitPreferences(BookAppearance.preferences(twoColumns: twoColumns))
        clearNavigatorBackground()

        await waitForViewportChange()

        if let saved {
            _ = await navigator.go(to: saved)
        }
    }

    /// Чекає на найближчий `viewportDidChange`, але не довше за таймаут.
    ///
    /// Таймаут — не «магічна затримка», а запобіжник: якщо Readium із якоїсь
    /// причини не повідомить про зміну, ми все одно повернемо користувача на
    /// місце, нехай і менш точно, замість зависнути назавжди.
    private func waitForViewportChange(timeout: Duration = .seconds(2)) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            viewportWaiters.append(continuation)

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeViewportWaiters()
            }
        }
    }

    private func resumeViewportWaiters() {
        let waiters = viewportWaiters
        viewportWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - EPUBNavigatorDelegate
//
// EPUBNavigatorViewController.delegate вимагає саме EPUBNavigatorDelegate, а не
// базовий NavigatorDelegate. Він успадковує VisualNavigatorDelegate,
// SelectableNavigatorDelegate і ViewportObservingNavigatorDelegate — усі їхні
// вимоги мають default-реалізації, тож обовʼязкові лише методи NavigatorDelegate.

extension ReaderHostViewController: EPUBNavigatorDelegate {
    // MARK: VisualNavigatorDelegate

    /// Прибирає відступ, на який Readium зсуває webview.
    ///
    /// Без цього методу Readium бере відступ із
    /// `view.window?.safeAreaInsets` — саме з вікна, а не з вигляду
    /// (`EPUBNavigatorViewController.spreadViewContentInset`). Тому жодні
    /// налаштування безпечної області на рівні контролера не діяли: webview
    /// усе одно починався на 24 pt нижче, і в цій щілині було видно підкладку
    /// без зерна.
    ///
    /// Нуль тут безпечний: вертикальні поля дають власні панелі зверху й
    /// знизу, а відступ від краю до тексту задається всередині документа
    /// (`BookAppearance.pageCSS`).
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        .zero
    }

    // MARK: NavigatorDelegate

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        enforceWebViewBackdrop()
        lastReportedProgression = locator.locations.totalProgression
        // Зберігаємо на кожну зміну позиції: застосунок можуть закрити будь-
        // коли, а чекати на спеціальний момент — втратити останню сторінку.
        // Виняток — перемотування смугою: там позиція міняється десятки
        // разів поспіль, і записувати варто лише ту, на якій зупинилися.
        if scrubTask == nil {
            ReadingPositionStore.save(locator, for: bookURL)
        }
        onLocationChange?(locator)
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        // Знадобиться у Фазі 1 для стека «повернутися назад».
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        let alert = UIAlertController(
            title: String(localized: "Помилка читання", bundle: AppLanguage.bundle),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        // Схема перевіряється навмисно. Посилання приходить із вмісту книги,
        // тобто з файлу, який застосунок не контролює: EPUB може містити
        // `file://`, `tel:` або власну схему іншого застосунку. Передавати
        // таке в систему без перевірки — віддавати чужому файлу право
        // відкривати що завгодно на машині користувача.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            print("[Reader] посилання з непідтримуваною схемою відхилено: \(url.scheme ?? "—")")
            return
        }
        UIApplication.shared.open(url)
    }

    func navigator(
        _ navigator: Navigator,
        shouldNavigateToNoteAt link: Link,
        content: String,
        referrer: String?
    ) -> Bool {
        // Власне подання зносок — Фаза 4 (FB2 їх активно використовує).
        true
    }

    func navigator(
        _ navigator: Navigator,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        print("[Reader] не вдалося завантажити ресурс \(href): \(error)")
    }

    // MARK: WebView Customization

    /// Робить `body` прозорим, щоб крізь документ проступала паперова текстура.
    ///
    /// Чому саме так, а не через налаштування: діагностика обчислених стилів
    /// показала `htmlBg = rgba(0,0,0,0)`, але `bodyBg = rgb(255,255,255)`.
    /// Тобто `--RS__backgroundColor: transparent` коректно прозорить `html`,
    /// а білим малює `body` — його фон задає власна таблиця стилів публікації,
    /// і жодна змінна Readium CSS на нього не впливає.
    ///
    /// `setupUserScripts` — штатна точка розширення `EPUBNavigatorDelegate`.
    /// Стиль додається в кінці документа, тож перебиває правила публікації за
    /// порядком каскаду, а `!important` закриває питання зі специфічністю.
    func navigator(
        _ navigator: EPUBNavigatorViewController,
        setupUserScripts userContentController: WKUserContentController
    ) {
        let css = BookAppearance.pageCSS

        // Ідентифікатор потрібен, щоб потім оновлювати стиль наживо при
        // зміні кольорів, а не перестворювати навігатор.
        let source = """
        (function () {
            var style = document.getElementById("\(BookAppearance.styleElementID)")
                || document.createElement("style");
            style.id = "\(BookAppearance.styleElementID)";
            style.textContent = `\(css)`;
            (document.head || document.documentElement).appendChild(style);
        })();
        """

        userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    // MARK: ViewportObservingNavigatorDelegate

    func navigator(
        _ navigator: any ViewportObservingNavigator,
        viewportDidChange viewport: NavigatorViewport?
    ) {
        if currentViewport == nil, viewport != nil, firstLayoutAt == nil {
            firstLayoutAt = .now
        }
        currentViewport = viewport
        enforceWebViewBackdrop()
        hideLoadingCover()
        onViewportChange?(viewport)
        resumeViewportWaiters()
    }
}
