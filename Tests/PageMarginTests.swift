import Testing
@testable import Chytach

/// Бічні поля сторінки: окремо ліворуч і праворуч.
///
/// Перевірки навмисно не чіпають `BookAppearance.leftMargin` та
/// `rightMargin`: це глобальні значення, на яких стоять інші набори тестів,
/// а Swift Testing запускає набори паралельно.
@Suite("Бічні поля")
struct PageMarginTests {
    @Test("Кожен бік потрапляє у свою властивість")
    func declarationsCarryBothSides() {
        let css = BookAppearance.sideMarginDeclarations(left: 90, right: 10)

        #expect(css.contains("padding-left: 90px !important"))
        #expect(css.contains("padding-right: 10px !important"))
    }

    @Test("Значення поза межами підрізаються")
    func declarationsClampOutOfRange() {
        let css = BookAppearance.sideMarginDeclarations(left: -40, right: 10_000)

        #expect(css.contains("padding-left: \(Int(BookAppearance.minimumSideMargin))px"))
        #expect(css.contains("padding-right: \(Int(BookAppearance.maximumSideMargin))px"))
    }

    /// Readium CSS задає поле двічі — простим `body` і правилом полів
    /// користувача зі специфічністю (0,2,1). Перебити обидва можна лише
    /// двома власними правилами такої самої ваги, тож їх має бути рівно два.
    @Test("Поле задане двічі, щоб перебити обидва правила Readium")
    func pageCSSAnswersBothReadiumRules() {
        let css = BookAppearance.pageCSS

        #expect(css.contains(":root[style] body"))
        #expect(css.components(separatedBy: "padding-left:").count - 1 == 2)
        #expect(css.components(separatedBy: "padding-right:").count - 1 == 2)
    }

    /// Якщо поле не їде в налаштування, Readium не перераховує розкладку —
    /// і повернення на місце чекає таймауту замість негайного перемалювання.
    @Test("Поля доходять до налаштувань Readium")
    func preferencesCarryAverageMargin() {
        let expected = (BookAppearance.leftMargin + BookAppearance.rightMargin)
            / (2 * BookAppearance.defaultSideMargin)

        #expect(BookAppearance.preferences(twoColumns: false).pageMargins == expected)
    }
}
