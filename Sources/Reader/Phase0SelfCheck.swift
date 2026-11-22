import ReadiumNavigator
import ReadiumShared
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
        let forwardAccepted = await navigator.goForward()
        let movedForward = await wait {
            (navigator.currentLocation?.locations.totalProgression ?? 0) > startProgression
        }
        let afterForward = navigator.currentLocation?.locations.totalProgression ?? 0
        log(
            forwardAccepted && movedForward,
            String(format: "goForward: %.5f → %.5f", startProgression, afterForward)
        )

        // 4. Гортання назад.
        let backAccepted = await navigator.goBackward()
        let movedBack = await wait {
            (navigator.currentLocation?.locations.totalProgression ?? 1) <= startProgression
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
                let jumped = await navigator.go(to: target)
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
                let imported = try await BookImportService.importBook(from: provider)
                log(
                    FileManager.default.fileExists(atPath: imported.path),
                    "перетягування: книга в бібліотеці — \(imported.lastPathComponent)"
                )
                try? FileManager.default.removeItem(at: imported)
            } catch {
                log(false, "перетягування: \(error.localizedDescription)")
            }
        } else {
            log(false, "перетягування: не вдалося зібрати провайдера зі зразка")
        }

        log(host.transparentWebViewCount > 0,
            "WKWebView знайдено в ієрархії: \(host.transparentWebViewCount)")

        dumpHierarchy(host.view, depth: 0)

        await diagnoseStyles(navigator: navigator)

        print("[SELFTEST] ===== кінець =====")
    }

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
