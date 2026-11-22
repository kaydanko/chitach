import Testing
@testable import Chytach

@Suite("Каркас")
struct SmokeTests {
    @Test("Тестовий таргет зібраний і бачить модуль застосунку")
    func appModuleIsLinked() {
        _ = ContentView()
    }
}
