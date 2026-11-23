import ReadiumNavigator
// Чому `@preconcurrency` — див. ReaderHostViewController.swift.
@preconcurrency import ReadiumShared
import UIKit

/// Самодіагностика Фази 0.
///
/// Тимчасовий інструмент. Існує тому, що тест-ранер на цій машині не
/// запускається: `xcodebuild` резолвить `xcrun` через `xcode-select`, який
/// вказує на CommandLineTools без `simctl`. Доки це не виправлено
/// (`sudo xcode-select -s …`), це єдиний спосіб отримати машинний доказ, що
/// гортання і viewport працюють на пристрої.
///
/// Запуск:
///     xcrun simctl launch --console-pty booted com.kabuki.chytach --selftest
///
/// ВИДАЛИТИ разом із `Sources/Resources/sample.epub`, коли запрацюють тести
/// (Фаза 1).
enum Phase0SelfCheck {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    private static func log(_ ok: Bool, _ message: String) {
        print("[SELFTEST] \(ok ? "PASS" : "FAIL") — \(message)")
    }

    /// Чекає на умову з таймаутом. Повертає `false`, якщо не дочекалась.
    private static func wait(
        _ seconds: Double = 10,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    static func run(host: ReaderHostViewController) async {
        let navigator = host.navigator
        print("[SELFTEST] ===== Фаза 0 =====")

        // 1. Навігатор віддав першу позицію.
        let gotLocation = await wait { navigator.currentLocation != nil }
        log(gotLocation, "перша позиція отримана: \(navigator.currentLocation?.href.string ?? "—")")
        guard let start = navigator.currentLocation else { return }
        let startProgression = start.locations.totalProgression ?? 0

        // 2. viewport приходить — інструмент Фази 0.5.
        let gotViewport = await wait { host.currentViewport != nil }
        if let viewport = host.currentViewport {
            log(gotViewport, String(
                format: "viewport: progression %.4f…%.4f, ресурсів %d",
                viewport.progression.lowerBound,
                viewport.progression.upperBound,
                viewport.resources.count
            ))
        } else {
            log(false, "viewport не прийшов")
        }

        // 3. Гортання вперед.
        //
        // Дві спроби навмисно. Одна не дає відрізнити «гортання зламане» від
        // «навігатор ще не готовий»: на старті з відновленої позиції перша
        // спроба зникала безслідно, і з одного виміру причину було не видно.
        let began = ContinuousClock.now
        var forwardAccepted = false
        var movedForward = false
        var attempts = 0

        while attempts < 20, !movedForward {
            attempts += 1
            // Саме `host`, а не `navigator`: кнопки гортання в застосунку
            // ходять через обгортку, і перевіряти треба її, а не сирий
            // навігатор. На сирому перше гортання після відновлення позиції
            // приймається, але не відбувається.
            forwardAccepted = await host.goForward()
            movedForward = await wait(1) {
                (navigator.currentLocation?.locations.totalProgression ?? 0) > startProgression
            }
            if !movedForward { try? await Task.sleep(for: .milliseconds(250)) }
        }

        let afterForward = navigator.currentLocation?.locations.totalProgression ?? 0
        let readyAfter = Double((ContinuousClock.now - began).components.seconds) * 1000
            + Double((ContinuousClock.now - began).components.attoseconds) / 1e15

        // Вимагаємо успіху з ПЕРШОЇ спроби. Колись тут було «відома вада»:
        // гортання, видане щойно з'явилась перша позиція, приймалося, але
        // губилося — Readium виконує початкову прокрутку лише через 0,2 с
        // після завантаження й перекриває ним усе, що хост зробив до цього.
        // Хост тепер чекає на відновлену позицію й на показ розвороту, тож
        // друга спроба не потрібна; цикл лишається як вимірювач, і якщо
        // вада повернеться, рядок знову стане FAIL із числом спроб.
        log(
            forwardAccepted && movedForward && attempts == 1,
            String(
                format: "goForward: %.5f → %.5f (спроб %d, рух через %.0f мс)",
                startProgression, afterForward, attempts, readyAfter
            )
        )

        // 4. Гортання назад. Вимагаємо саме руху: умова «не далі, ніж було»
        // проходила б і тоді, коли сторінка взагалі не змінилася.
        let backAccepted = await host.goBackward()
        let movedBack = await wait(6) {
            (navigator.currentLocation?.locations.totalProgression ?? 1) < afterForward
        }
        let afterBack = navigator.currentLocation?.locations.totalProgression ?? 0
        log(
            backAccepted && movedBack,
            String(format: "goBackward: %.5f → %.5f", afterForward, afterBack)
        )

        // 5. Перехід за змістом.
        do {
            let toc = try await navigator.publication.tableOfContents().get()
            if let target = toc.dropFirst(2).first ?? toc.last {
                let jumped = await navigator.go(to: target, options: NavigatorGoOptions())
                _ = await wait { navigator.currentLocation?.href.string != start.href.string }
                log(
                    jumped,
                    "перехід за змістом «\(target.title ?? "—")» → \(navigator.currentLocation?.href.string ?? "—")"
                )
            } else {
                log(false, "зміст порожній")
            }
        } catch {
            log(false, "не вдалося прочитати зміст: \(error)")
        }

        // 6. Кількість позицій у книзі.
        do {
            let positions = try await navigator.publication.positions().get()
            log(positions.count > 0, "позицій у книзі: \(positions.count)")
        } catch {
            log(false, "positions(): \(error)")
        }

        // 7. Перемотування смугою: багато запитів підряд, як від миші.
        //
        // Перевіряє дві речі, що раніше були зламані: сторінки мають
        // гортатися вже під час ведення, а останній запит — не губитися
        // через запобіжник, що не пускав другий перехід поверх першого.
        let previousHandler = host.onLocationChange
        var seenDuringScrub: [Double] = []
        host.onLocationChange = { locator in
            seenDuringScrub.append(locator.locations.totalProgression ?? 0)
            previousHandler?(locator)
        }

        // Спершу поодинокий перехід — щоб відрізнити ваду черги від вади
        // самого переходу на частку книги.
        let probe = await navigator.publication.locate(progression: 0.5)
        log(probe != nil, String(
            format: "locate(0.5) → %@ progression=%.4f total=%.4f",
            probe?.href.string ?? "nil",
            probe?.locations.progression ?? -1,
            probe?.locations.totalProgression ?? -1
        ))
        let single = await host.go(toProgression: 0.5)
        let singleMoved = await wait(5) {
            abs((navigator.currentLocation?.locations.totalProgression ?? 0) - 0.5) < 0.06
        }
        log(single && singleMoved, String(
            format: "go(toProgression: 0.5): прийнято %@, дочекались %@, позиція %.4f",
            single ? "так" : "ні",
            singleMoved ? "так" : "ні",
            navigator.currentLocation?.locations.totalProgression ?? -1
        ))

        let scrubTarget = 0.8
        for step in 1 ... 15 {
            host.scrub(to: 0.1 + (scrubTarget - 0.1) * Double(step) / 15)
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Без додаткового очікування: `finishScrubbing` зобовʼязана повертати
        // керування лише тоді, коли сторінка вже стала на місце. Саме на це
        // спирається смуга, вирішуючи, коли віддати повзунок навігаторові.
        await host.finishScrubbing()
        host.onLocationChange = previousHandler

        let landed = navigator.currentLocation?.locations.totalProgression ?? 0
        log(
            abs(landed - scrubTarget) < 0.06,
            String(format: "перемотування: ціль %.4f, зупинились на %.4f", scrubTarget, landed)
        )
        log(
            seenDuringScrub.count > 1,
            "позицій змінено під час ведення: \(seenDuringScrub.count) (якщо 1 — гортання лише після відпускання)"
        )

        // 8. Приймання перетягнутого файлу.
        //
        // Перевіряє ту половину, яку можна перевірити без миші: чи
        // дістається книга з `NSItemProvider` — того самого, що його
        // віддає система при кидку. Чи доходить сам кидок до вікна, видно
        // лише руками.
        if let sample = Bundle.main.url(forResource: "sample", withExtension: "epub"),
           let provider = NSItemProvider(contentsOf: sample) {
            do {
                // Запамʼятовуємо, що було до імпорту: якщо зразок збігся з
                // книгою, яка вже лежить у бібліотеці, видаляти її потім не
                // можна. Саме так перевірка й знищувала чужу фікстуру.
                // За іменами, а не URL: шлях теки може йти крізь символьне
                // посилання, і тоді файл, що вже лежав, «не впізнається» —
                // а перевірка видалила б чужу книгу.
                let before = Set(
                    ((try? FileManager.default.contentsOfDirectory(
                        at: BookImportService.booksDirectory,
                        includingPropertiesForKeys: nil
                    )) ?? []).map(\.lastPathComponent)
                )

                let imported = try await BookImportService.importBook(from: provider)
                log(
                    FileManager.default.fileExists(atPath: imported.path),
                    "перетягування: книга в бібліотеці — \(imported.lastPathComponent)"
                )

                // Та сама книга вдруге не має лягти другою копією: інакше
                // перелік засмічується, а книга ще й губить місце читання,
                // бо копія приходить із нульовим.
                if let again = NSItemProvider(contentsOf: sample) {
                    let second = try await BookImportService.importBook(from: again)
                    log(second == imported, "повторне додавання: \(second.lastPathComponent)")
                    // Провал означає, що в бібліотеку лягла зайва копія. На
                    // Mac бібліотека — справжня тека «Документи», тож
                    // прибираємо за собою навіть тоді.
                    if second != imported, !before.contains(second.lastPathComponent) {
                        try? FileManager.default.removeItem(at: second)
                    }
                } else {
                    log(false, "повторне додавання: провайдера не зібрати")
                }

                // Той самий вміст під іншою назвою — теж та сама книга:
                // звіряємо вміст, а не імена.
                let renamed = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Зовсім інша назва.epub")
                try? FileManager.default.removeItem(at: renamed)
                try FileManager.default.copyItem(at: sample, to: renamed)
                let third = try BookImportService.importBook(from: renamed)
                log(third == imported, "інша назва, той самий вміст: \(third.lastPathComponent)")
                try? FileManager.default.removeItem(at: renamed)
                if third != imported, !before.contains(third.lastPathComponent) {
                    try? FileManager.default.removeItem(at: third)
                }

                if !before.contains(imported.lastPathComponent) {
                    try? FileManager.default.removeItem(at: imported)
                }
            } catch {
                log(false, "перетягування: \(error.localizedDescription)")
            }
        } else {
            log(false, "перетягування: не вдалося зібрати провайдера зі зразка")
        }

        // 9. Зміст: чи є він і чи переходить перехід.
        let toc = await host.tableOfContents()
        let entries = TableOfContentsEntry.flatten(toc)
        log(entries.count > 1, "зміст: записів \(entries.count), рівнів \((entries.map(\.depth).max() ?? 0) + 1)")

        if let target = entries.last {
            let before = navigator.currentLocation?.locations.totalProgression ?? 0
            let jumped = await host.go(to: target.link)
            let moved = await wait(5) {
                abs((navigator.currentLocation?.locations.totalProgression ?? 0) - before) > 0.01
            }
            log(
                jumped && moved,
                String(
                    format: "зміст: перехід до «%@» — %.4f → %.4f",
                    target.title, before,
                    navigator.currentLocation?.locations.totalProgression ?? -1
                )
            )
        } else {
            log(false, "зміст: порожній, перехід перевірити нема на чому")
        }

        // 10. Прибирання копій, що вже лежать у бібліотеці.
        //
        // Саме «вже лежать»: повторне додавання тепер упізнається, але
        // бібліотеки, зібрані раніше, повні копій із номерами в назві.
        // Вміст беремо унікальний, щоб група складалася лише з наших файлів.
        let books = BookImportService.booksDirectory
        let payload = Data("Перевірка дублікатів \(UUID().uuidString)\n".utf8)
        let copies = ["Дубль.txt", "Дубль 2.txt", "Дубль 3.txt", "Дубль 4.txt"]
            .map { books.appendingPathComponent($0) }

        for copy in copies {
            try? FileManager.default.removeItem(at: copy)
            try? payload.write(to: copy)
        }

        // Поступ позначаємо не в першій копії, а в третій: лишитися має та,
        // у якій читач просунувся найдалі, а не та, що трапилася першою.
        let survivor = copies[2]
        if let locator = navigator.currentLocation {
            ReadingPositionStore.save(locator, for: survivor)
        }

        // Прибираємо лише свої копії. Загальне прибирання зачепило б і
        // решту бібліотеки: у теці перевірок лежать книги з однаковим
        // вмістом під різними назвами, і одна з них щоразу зникала.
        // Звіряємо за іменем файлу, як і сам застосунок (`LibraryBook.id`,
        // ключ місця читання). Повний URL не годиться: перелік теки віддає
        // справжній шлях, а `booksDirectory` може йти крізь символьне
        // посилання (`/tmp` → `/private/tmp`), і тоді жодна копія «не
        // наша», хоч знайдено їх правильно.
        let copyNames = Set(copies.map(\.lastPathComponent))
        let ourCopies = await LibraryStore.redundantCopies()
            .filter { copyNames.contains($0.url.lastPathComponent) }
        for copy in ourCopies { try? LibraryStore.remove(copy) }
        let removed = ourCopies.count
        let left = copies.filter { FileManager.default.fileExists(atPath: $0.path) }
        log(removed == 3 && left.count == 1, "прибирання копій: вилучено \(removed), лишилось \(left.count)")
        log(
            left.first?.lastPathComponent == survivor.lastPathComponent,
            "лишилася саме читана копія — \(left.first?.lastPathComponent ?? "жодної")"
        )
        left.forEach { try? FileManager.default.removeItem(at: $0) }
        ReadingPositionStore.forget(survivor)

        // 11. Чи не видно білого, поки вантажиться нова сторінка.
        //
        // Міряємо під час самого переходу: спалах триває частки секунди й у
        // знімок екрана не потрапляє, а колір виду зчитується будь-коли.
        let jump = Task { await host.go(toProgression: 0.15) }
        var samples: [String] = []
        for _ in 0 ..< 16 {
            try? await Task.sleep(for: .milliseconds(25))
            samples += host.webViewBackdrops
        }
        _ = await jump.value

        // Шар, яким накриваємо читалку на час завантаження, мусить зникати.
        // Застряглий — це чорний екран замість книги.
        log(!host.isLoadingCoverVisible, "шар завантаження прибрано після переходу")

        let whites = samples.filter { $0 == "#FFFFFF" }
        log(
            whites.isEmpty && !samples.isEmpty,
            "тло webview під час переходу: \(Set(samples).sorted().joined(separator: ", "))"
                + (whites.isEmpty ? "" : " — білого разів: \(whites.count)")
        )

        log(host.transparentWebViewCount > 0,
            "WKWebView знайдено в ієрархії: \(host.transparentWebViewCount)")

        dumpHierarchy(host.view, depth: 0)

        await diagnoseStyles(navigator: navigator)

        await checkFB2()

        print("[SELFTEST] ===== кінець =====")
    }

    /// FB2 від файлу до `Publication`.
    ///
    /// Розбірник окремо перевіряє `Scripts/test-fb2.sh`; тут — те, чого без
    /// застосунку не перевірити: що зібраний EPUB приймає сам Readium, з
    /// обкладинкою, змістом і всіма розділами, і що друге відкриття бере кеш.
    @MainActor
    private static func checkFB2() async {
        print("[SELFTEST] ----- FB2 -----")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-\(UUID().uuidString).fb2")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try Data(sampleFB2.utf8).write(to: url)

            let started = Date()
            let directory = try FB2ToEPUBConverter.convert(fileURL: url)
            let firstTime = Date().timeIntervalSince(started)
            defer { try? FileManager.default.removeItem(at: directory) }

            let restarted = Date()
            let again = try FB2ToEPUBConverter.convert(fileURL: url)
            let secondTime = Date().timeIntervalSince(restarted)
            log(again == directory, String(
                format: "FB2: повторне відкриття з кешу (%.1f мс проти %.1f мс)",
                secondTime * 1000, firstTime * 1000
            ))

            let publication = try await ReadiumPublicationService().openDirectory(directory).publication
            let metadata = publication.metadata
            log(metadata.title == "Самоперевірка FB2", "FB2: назва — \(metadata.title ?? "nil")")
            log(metadata.authors.map(\.name) == ["Леся Українка"],
                "FB2: автори — \(metadata.authors.map(\.name))")
            log(publication.readingOrder.count == 2,
                "FB2: розділів у readingOrder — \(publication.readingOrder.count) (очікуємо текст і примітки)")

            let toc = (try? await publication.tableOfContents().get()) ?? []
            log(toc.map(\.title) == ["Перший розділ", "Примітки"],
                "FB2: зміст — \(toc.map { $0.title ?? "—" })")

            let cover = try? await publication.cover().get()
            log(cover != nil, "FB2: обкладинка — \(cover.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "немає")")
        } catch {
            log(false, "FB2: \(error.localizedDescription)")
        }
    }

    /// Найменша книга, де є все, що Readium мусить прийняти: обкладинка,
    /// картинка в тексті, зноска з окремим тілом. Картинка — PNG 2×2.
    private static let sampleFB2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
    <description><title-info>
      <author><first-name>Леся</first-name><last-name>Українка</last-name></author>
      <book-title>Самоперевірка FB2</book-title>
      <coverpage><image l:href="#c"/></coverpage>
      <lang>uk</lang>
    </title-info></description>
    <body>
      <section id="s1"><title><p>Перший розділ</p></title>
        <p><emphasis>Текст</emphasis> зі зноскою<a l:href="#n1" type="note">[1]</a>.</p>
        <poem><stanza><v>Рядок перший</v><v>Рядок другий</v></stanza></poem>
        <image l:href="#c"/>
      </section>
    </body>
    <body name="notes"><section id="n1"><p>Зноска.</p></section></body>
    <binary id="c" content-type="image/png">iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR42mNgCN8OQv+vgxAAI54FyapE9b4AAAAASUVORK5CYII=</binary>
    </FictionBook>
    """

    /// Друкує ієрархію видів із кольорами — щоб знайти, хто малює біле.
    @MainActor
    private static func dumpHierarchy(_ view: UIView, depth: Int) {
        guard depth < 6 else { return }
        let pad = String(repeating: "  ", count: depth)
        let bg = view.backgroundColor.map { color -> String in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X α%.2f", Int(r * 255), Int(g * 255), Int(b * 255), a)
        } ?? "nil"
        let f = view.frame
        print(String(
            format: "[SELFTEST]   %@%@ bg=%@ opaque=%@ frame=(%.0f,%.0f %.0f×%.0f)",
            pad, String(describing: type(of: view)), bg,
            view.isOpaque ? "так" : "ні", f.origin.x, f.origin.y, f.width, f.height
        ))
        for sub in view.subviews {
            dumpHierarchy(sub, depth: depth + 1)
        }
    }

    /// Читає реальні обчислені стилі з документа.
    ///
    /// Потрібна, бо здогадки про джерело білого тла й геометрію колонок двічі
    /// виявилися хибними. Замість припущень — факти з самого WebKit.
    @MainActor
    private static func diagnoseStyles(navigator: EPUBNavigatorViewController) async {
        let script = """
        (function () {
          var h = document.documentElement, b = document.body;
          var ch = getComputedStyle(h), cb = getComputedStyle(b);
          function v(n) { return ch.getPropertyValue(n).trim() || "—"; }
          return JSON.stringify({
            inlineStyle: (h.getAttribute("style") || "—").slice(0, 400),
            htmlBg: ch.backgroundColor,
            bodyBg: cb.backgroundColor,
            htmlBgImage: ch.backgroundImage,
            varRsBg: v("--RS__backgroundColor"),
            varUserBg: v("--USER__backgroundColor"),
            varColCount: v("--RS__colCount"),
            varColWidth: v("--RS__colWidth"),
            varColGap: v("--RS__colGap"),
            varMaxLine: v("--RS__maxLineLength"),
            varPageGutter: v("--RS__pageGutter"),
            computedColCount: ch.columnCount,
            computedColWidth: ch.columnWidth,
            computedColGap: ch.columnGap,
            htmlClientWidth: h.clientWidth,
            bodyWidth: b.getBoundingClientRect().width,
            bodyMaxWidth: cb.maxWidth,
            bodyPadding: cb.paddingLeft + " / " + cb.paddingRight,
            bodyMargin: cb.marginLeft + " / " + cb.marginRight
          });
        })();
        """

        switch await navigator.evaluateJavaScript(script) {
        case let .success(value):
            guard
                let json = value as? String,
                let data = json.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("[SELFTEST] діагностика: несподіваний результат \(value)")
                return
            }
            print("[SELFTEST] ----- обчислені стилі -----")
            for key in dict.keys.sorted() {
                print("[SELFTEST]   \(key) = \(dict[key] ?? "nil")")
            }
        case let .failure(error):
            print("[SELFTEST] діагностика не вдалася: \(error)")
        }
    }
}
