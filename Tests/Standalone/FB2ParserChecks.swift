// Перевірки розбірника FB2 і розпакування .fb2.zip.
//
// Окремий виконуваний файл, а не XCTest, з тієї самої причини, що й
// RTFPictureExtractorChecks: тест-ранер на цій машині не запускається
// (ризик R4). Розбірник залежить лише від Foundation, тож перевіряється без
// симулятора:
//
//     Scripts/test-fb2.sh
//
// Скрипт передає шляхи до фікстури та похідних від неї файлів: копії у
// windows-1251 і двох архівів — стиснутого й нестиснутого.

import Foundation

private var failures = 0

private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    print((condition ? "  ok   " : "  ПРОВАЛ") + " \(name)" + (condition ? "" : "  \(detail())"))
    if !condition { failures += 1 }
}

private func load(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("Не вдалося прочитати \(path)")
        exit(2)
    }
    return data
}

/// Чи розбирається розділ як XML. Readium читає розділи як XHTML, і одна
/// незакрита мітка робить розділ порожнім — тож це головна перевірка.
private func isWellFormed(_ body: String) -> Bool {
    let wrapped = "<div xmlns=\"http://www.w3.org/1999/xhtml\">\(body)</div>"
    return XMLParser(data: Data(wrapped.utf8)).parse()
}

private func fb2(_ body: String, description: String = "") -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
    <description><title-info>\(description)</title-info></description>
    <body>\(body)</body>
    </FictionBook>
    """.utf8)
}

@main
enum FB2ParserChecks {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 else {
            print("Використання: checks <utf8.fb2> <cp1251.fb2> <deflate.fb2.zip> <stored.fb2.zip>")
            exit(2)
        }

        print("1. Фікстура UTF-8: опис книги")
        let document: FB2Parser.Document
        do {
            document = try FB2Parser.parse(data: load(arguments[1]))
        } catch {
            check("розбір", false, "\(error)")
            exit(1)
        }
        check("назва", document.title == "Пробна книжка: «Ґанок і м’ята»", document.title)
        check("автори з title-info, а не з document-info",
              document.authors == ["Леся Українка", "Тарас Григорович Шевченко"], "\(document.authors)")
        check("мова з title-info", document.language == "uk", document.language)

        print("2. Розділи")
        let chapters = document.chapters
        check("два розділи й примітки", chapters.count == 3, "\(chapters.count)")
        guard chapters.count == 3 else { exit(1) }
        check("назва першого з двох абзаців заголовка",
              chapters[0].title == "Розділ перший Накреслення", chapters[0].title ?? "nil")
        check("назва розділу приміток", chapters[2].title == "Примітки", chapters[2].title ?? "nil")
        for (index, chapter) in chapters.enumerated() {
            check("розділ \(index + 1) — коректний XML", isWellFormed(chapter.bodyXHTML))
            check("розділ \(index + 1) — без нерозв'язаних міток",
                  !chapter.bodyXHTML.contains("\u{1}"), chapter.bodyXHTML)
        }

        let first = chapters[0].bodyXHTML
        let second = chapters[1].bodyXHTML
        let notes = chapters[2].bodyXHTML

        print("3. Те, що стоїть до першої секції")
        check("назва тіла не загубилась", first.contains("<h1>") && first.contains("для Chytach"))
        check("епіграф тіла не загубився", first.contains("Хто не йде вперед"))

        print("4. Накреслення")
        check("emphasis → em", first.contains("<em>курсивом</em>"))
        check("strong", first.contains("<strong>грубим</strong>"))
        check("strikethrough → s", first.contains("<s>закресленим</s>"))
        check("sub і sup", first.contains("H<sub>2</sub>O") && first.contains("mc<sup>2</sup>"))
        check("апострофи збережено", first.contains("м’ята, п'ять, з’їсти; ґудзик"))
        check("екранування", first.contains("&lt;кутові&gt; й &amp;"))
        check("subtitle", first.contains("class=\"subtitle\""))
        check("empty-line", first.contains("class=\"empty-line\""))
        check("cite → blockquote", first.contains("<blockquote class=\"cite\""))
        check("text-author", first.contains("class=\"text-author\""))

        print("5. Вірш")
        check("poem і stanza", second.contains("class=\"poem\"") && second.components(separatedBy: "class=\"stanza\"").count == 3)
        check("кожен рядок — окремий абзац",
              second.components(separatedBy: "class=\"verse\"").count == 5)
        check("рядок вірша без виключки", second.contains("text-align:left !important"))
        check("епіграф до розділу", second.contains("class=\"epigraph\"") && second.contains("Епіграф до вірша"))
        check("вкладена секція — h3", second.contains("<h3>Підрозділ</h3>"))

        print("6. Картинки")
        check("дві картинки", document.images.count == 2, "\(document.images.count)")
        let cover = document.images.first { $0.isCover }
        check("обкладинку позначено", cover != nil)
        check("лише одна обкладинка", document.images.filter(\.isCover).count == 1)
        check("тип PNG", document.images.allSatisfy { $0.mediaType == "image/png" })
        check("байти PNG цілі", document.images.allSatisfy { $0.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) })
        if let flag = document.images.first(where: { !$0.isCover }) {
            check("картинка в тексті посилається на свій файл", first.contains("<img src=\"\(flag.path)\""), first)
        }
        if let cover {
            check("обкладинку не вставлено в текст",
                  !chapters.contains { $0.bodyXHTML.contains("src=\"\(cover.path)\"") })
        }

        print("7. Зноски")
        check("посилання веде в розділ приміток", first.contains("href=\"chapter3.xhtml#n1\""), first)
        check("посилання має своє місце", first.contains("id=\"fb2-ref-1\""))
        check("зноска має якір", notes.contains("id=\"n1\"") && notes.contains("id=\"n2\""))
        check("зворотний перехід із першої зноски — до першого посилання",
              notes.contains("href=\"chapter1.xhtml#fb2-ref-1\""), notes)
        check("зворотний перехід із другої — у другий розділ",
              notes.contains("href=\"chapter2.xhtml#fb2-ref-2\""), notes)
        check("по одному зворотному переходу на зноску",
              notes.components(separatedBy: "class=\"backref\"").count == 3)

        print("8. Windows-1251")
        do {
            let cp = try FB2Parser.parse(data: load(arguments[2]))
            check("назва", cp.title == document.title, cp.title)
            check("текст", cp.chapters.first?.bodyXHTML.contains("м’ята, п'ять, з’їсти; ґудзик") == true)
            check("картинки", cp.images.count == 2)
        } catch {
            check("розбір", false, "\(error)")
        }

        print("9. .fb2.zip")
        for (label, path) in [("deflate", arguments[3]), ("без стиснення", arguments[4])] {
            do {
                let book = try FB2ZipExtractor.extractBook(from: load(path))
                check("\(label): байт у байт як оригінал", book == load(arguments[1]), "\(book.count) байт")
            } catch {
                check("\(label): розпакування", false, "\(error)")
            }
        }
        check("розпізнавання імені", FB2ZipExtractor.handles(URL(fileURLWithPath: "/x/Книга.FB2.ZIP")))
        check("звичайний zip — ні", !FB2ZipExtractor.handles(URL(fileURLWithPath: "/x/архів.zip")))
        check("назва з імені файлу",
              FB2ToEPUBConverter.displayName(of: URL(fileURLWithPath: "/x/Кобзар.fb2.zip")) == "Кобзар")

        print("10. Пошкоджені архіви не кладуть застосунок")
        let zip = load(arguments[3])
        for cut in [10, zip.count / 2, zip.count - 5] {
            let result = Result { try FB2ZipExtractor.extractBook(from: zip.prefix(cut)) }
            check("обрізано до \(cut) байт — помилка", (try? result.get()) == nil)
        }
        check("не ZIP — помилка", (try? FB2ZipExtractor.extractBook(from: Data("hello".utf8))) == nil)
        // Розмір у каталозі підмінено на велетенський: має бути відмова, а не
        // спроба виділити пам'ять.
        var bomb = [UInt8](zip)
        if let central = findCentral(bomb) {
            for i in 0 ..< 4 { bomb[central + 24 + i] = 0xFF }
            check("підмінений розмір — відмова",
                  (try? FB2ZipExtractor.extractBook(from: Data(bomb))) == nil)
        }

        print("11. Крайні випадки розмітки")
        check("зламаний XML — помилка, не падіння",
              (try? FB2Parser.parse(data: Data("<FictionBook><body><p>текст".utf8))) == nil)
        check("порожня книга — помилка",
              (try? FB2Parser.parse(data: fb2(""))) == nil)
        if let plain = try? FB2Parser.parse(data: fb2("<p>Без секцій</p>")) {
            check("тіло без секцій — один розділ", plain.chapters.count == 1)
            check("без назви — порожньо (візьметься ім'я файлу)", plain.title.isEmpty)
            check("мова за замовчуванням", plain.language == "uk")
        } else {
            check("тіло без секцій", false)
        }
        if let quoted = try? FB2Parser.parse(data: fb2("<section id='a\"b'><p>x</p></section>")) {
            check("лапка в id не ламає атрибут", isWellFormed(quoted.chapters[0].bodyXHTML), quoted.chapters[0].bodyXHTML)
        }
        if let dangling = try? FB2Parser.parse(data: fb2(
            "<section><p>x<a l:href=\"#nowhere\" type=\"note\">1</a><image l:href=\"#missing\"/></p></section>"
        )) {
            let body = dangling.chapters[0].bodyXHTML
            check("посилання в нікуди лишається якорем", body.contains("href=\"#nowhere\""), body)
            check("відсутня картинка не дає порожнього img", !body.contains("<img"), body)
        }
        if let empty = try? FB2Parser.parse(data: fb2("<section><title><p>Порожній</p></title></section><section><p>Текст</p></section>")) {
            check("секція лише із заголовком — теж розділ", empty.chapters.count == 2, "\(empty.chapters.count)")
        }

        print("12. Ідентифікатори як чужі дані")
        // Раніше ідентифікатор ішов у мітку сирим: `@@` усередині обривав її,
        // і хвіст лягав у XHTML без екранування.
        let hostile = "x@@<script>alert(1)</script>\\"
        let escapedID = hostile.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if let evil = try? FB2Parser.parse(data: fb2("""
            <section><p>x<a l:href="#\(escapedID)" type="note">1</a><image l:href="#\(escapedID)"/></p></section>
            <section id="\(escapedID)"><p>@@fb2-link:0@@ і @@fb2-image:0@@</p></section>
            """)) {
            let all = evil.chapters.map(\.bodyXHTML).joined()
            check("жодного сирого <script>", !all.contains("<script"), all)
            check("усе ще коректний XML", evil.chapters.allSatisfy { isWellFormed($0.bodyXHTML) }, all)
            check("текст, схожий на мітку, лишається текстом",
                  all.contains("@@fb2-link:0@@ і @@fb2-image:0@@"), all)
        } else {
            check("розбір книги з підступними id", false)
        }

        print(failures == 0 ? "\nУсе гаразд." : "\nПровалів: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func findCentral(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0 ..< bytes.count - 4 where bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 1 && bytes[i + 3] == 2 {
            return i
        }
        return nil
    }
}
