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
        navigator.publication.metadata.title ?? "Без назви"
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

    private func turnPage(_ move: () async -> Bool) async -> Bool {
        guard !isTurningPage else { return false }
        isTurningPage = true
        defer { isTurningPage = false }

        return await move()
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
            webView.backgroundColor = BookAppearance.paperColor
            webView.scrollView.backgroundColor = BookAppearance.paperColor
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
        // Зберігаємо на кожну зміну позиції: застосунок можуть закрити будь-
        // коли, а чекати на спеціальний момент — втратити останню сторінку.
        ReadingPositionStore.save(locator, for: bookURL)
        onLocationChange?(locator)
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        // Знадобиться у Фазі 1 для стека «повернутися назад».
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        let alert = UIAlertController(
            title: "Помилка читання",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
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
        currentViewport = viewport
        enforceWebViewBackdrop()
        onViewportChange?(viewport)
        resumeViewportWaiters()
    }
}
