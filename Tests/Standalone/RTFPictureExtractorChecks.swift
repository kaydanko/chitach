// Перевірки розбірника картинок RTF.
//
// Окремий виконуваний файл, а не XCTest, бо тест-ранер на цій машині поки
// не запускається (див. ризик R4 у плані): тести хостяться в застосунку, і
// WKWebView на старті не дає ранеру приєднатися. Розбірник залежить лише
// від Foundation, тож збирається й запускається без симулятора:
//
//     Scripts/test-rtf.sh
//
// Коли ранер запрацює, це легко переписати на XCTest — перевірки готові.

import Foundation

private var failures = 0

private func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    print((condition ? "  ok   " : "  ПРОВАЛ") + " \(name)" + (condition ? "" : "  \(detail)"))
    if !condition { failures += 1 }
}

private func rtf(_ body: String) -> Data {
    Data(("{\\rtf1\\ansi\\ansicpg1251\n{\\fonttbl\\f0\\fnil Times;}\n\\pard\\f0 " + body + "}").utf8)
}
private let png = "89504e470d0a1a0a"          // сигнатура PNG — досить для перевірки
private func pict(_ wrapper: String = "") -> String { "{\\pict\\pngblip\\picw4\\pich4 \(png)}" }
@main
enum RTFPictureExtractorChecks {
    static func main() {
        print("1. Звичайна група")
        var r = RTFPictureExtractor.extract(from: rtf("До \(pict()) після"))
        check("одна картинка", r.pictures.count == 1, "\(r.pictures.count)")
        check("байти цілі", r.pictures.first?.map { String(format: "%02x", $0) }.joined() == png)
        check("мітка на місці", String(data: r.data, encoding: .utf8)?.contains("[[chytach-image-0]]") == true)

        print("2. Подвійний запис Word")
        r = RTFPictureExtractor.extract(from: rtf("До {\\*\\shppict\(pict())}{\\nonshppict\(pict())} після"))
        check("дублікат відкинуто", r.pictures.count == 1, "\(r.pictures.count)")
        check("мітка одна", String(data: r.data, encoding: .utf8)?.components(separatedBy: "[[chytach-image-").count == 2)

        print("3. Лише nonshppict (старий файл)")
        r = RTFPictureExtractor.extract(from: rtf("До {\\nonshppict\(pict())} після"))
        check("картинку взято", r.pictures.count == 1, "\(r.pictures.count)")

        print("4. Дві різні картинки поспіль")
        r = RTFPictureExtractor.extract(from: rtf("\(pict()) текст \(pict())"))
        check("обидві", r.pictures.count == 2, "\(r.pictures.count)")
        check("різні номери", String(data: r.data, encoding: .utf8)?.contains("[[chytach-image-1]]") == true)

        print("5. Двійкові дані \\bin")
        let binary = Data([0xFF, 0xD8, 0xFF, 0x7D, 0x7B, 0x5C])   // навмисне з } { \ усередині
        var doc = Data("{\\rtf1\\ansi\\pard До {\\pict\\jpegblip\\picw4\\pich4\\bin6 ".utf8)
        doc.append(binary)
        doc.append(Data("} після}".utf8))
        r = RTFPictureExtractor.extract(from: doc)
        check("двійковий блок прочитано", r.pictures.first == binary, "\(r.pictures.first?.count ?? -1) байт")

        print("6. Екрановані дужки в тексті")
        r = RTFPictureExtractor.extract(from: rtf("Текст \\{ у дужках \\} і \(pict())"))
        check("картинка знайдена", r.pictures.count == 1, "\(r.pictures.count)")

        print("7. Файл без картинок")
        let plain = rtf("Просто текст")
        r = RTFPictureExtractor.extract(from: plain)
        check("нічого не знайдено", r.pictures.isEmpty)
        check("байти не змінено", r.data == plain)

        print("8. Обрізана група (пошкоджений файл)")
        r = RTFPictureExtractor.extract(from: Data("{\\rtf1 До {\\pict\\pngblip \(png)".utf8))
        check("без аварії", r.pictures.count <= 1)

        print("9. Підстановка міток")
        let out = RTFPictureExtractor.replacingMarkers(in: "а[[chytach-image-0]]б[[chytach-image-5]]в") { i in
            i == 0 ? "<img/>" : nil
        }
        check("замінено й прибрано", out == "а<img/>бв", out)
        let kept = RTFPictureExtractor.replacingMarkers(in: "ціна [[chytach-image-x]] тут") { _ in "!" }
        check("чужий текст не зіпсовано", kept == "ціна [[chytach-image-x]] тут", kept)

        print(failures == 0 ? "\nУсі перевірки пройдено" : "\nПровалів: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
