import Foundation
import ReadiumShared
import Testing
@testable import Chytach

@Suite("Відкриття EPUB")
struct ReadiumPublicationServiceTests {
    /// Фікстури взяті з Readium `Tests/Publications` @ 3.11.0.
    private func fixture(_ name: String) throws -> URL {
        let url = Bundle(for: BundleToken.self)
            .url(forResource: name, withExtension: "epub")
        return try #require(url, "фікстура \(name).epub не потрапила в бандл тестів")
    }

    @Test("Метадані EPUB парсяться")
    func parsesMetadata() async throws {
        let service = ReadiumPublicationService()
        let opened = try await service.open(fileURL: fixture("childrens-literature"))

        #expect(opened.publication.metadata.title == "Children's Literature")
        #expect(opened.mediaType == .epub)
    }

    @Test("Публікація відповідає профілю EPUB")
    func conformsToEPUB() async throws {
        let service = ReadiumPublicationService()
        let opened = try await service.open(fileURL: fixture("childrens-literature"))

        #expect(opened.publication.conforms(to: .epub))
    }

    /// Позиції — основа для `Locator`. Якщо їх нуль, уся Фаза 0.5 не має сенсу.
    @Test("Публікація має ненульову кількість позицій")
    func hasPositions() async throws {
        let service = ReadiumPublicationService()
        let opened = try await service.open(fileURL: fixture("childrens-literature"))

        let positions = try await opened.publication.positions().get()
        #expect(positions.count > 0)
    }

    @Test("Зміст не порожній")
    func hasTableOfContents() async throws {
        let service = ReadiumPublicationService()
        let opened = try await service.open(fileURL: fixture("childrens-literature"))

        let toc = try await opened.publication.tableOfContents().get()
        #expect(!toc.isEmpty)
    }

    /// Передача відомого media type має давати той самий результат — це шлях,
    /// яким піде бібліотека після першого імпорту.
    @Test("Відкриття з відомим media type дає той самий результат")
    func openWithKnownMediaType() async throws {
        let service = ReadiumPublicationService()
        let opened = try await service.open(
            fileURL: fixture("childrens-literature"),
            knownMediaType: .epub
        )

        #expect(opened.publication.metadata.title == "Children's Literature")
    }

    @Test("Не-файловий URL відхиляється")
    func rejectsNonFileURL() async throws {
        let service = ReadiumPublicationService()

        await #expect(throws: PublicationOpenFailure.self) {
            _ = try await service.open(fileURL: URL(string: "https://example.com/a.epub")!)
        }
    }
}

private final class BundleToken {}
