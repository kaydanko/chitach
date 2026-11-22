import Foundation
import ReadiumShared
import ReadiumStreamer

/// Помилки, специфічні для нашого шару. Помилки самого Readium
/// (`AssetRetrieveURLError`, `PublicationOpenError`) пробрасуються як є —
/// загортати їх немає сенсу, вони й так типізовані.
enum PublicationOpenFailure: Error {
    /// URL не файловий. Мережеві джерела з'являться не раніше Фази 7 (OPDS).
    case notAFileURL(URL)
}

/// Результат відкриття: розпарсена публікація та визначений формат.
///
/// `format.mediaType` варто зберегти в бібліотеці й передавати назад у
/// `AssetRetriever.retrieve(url:mediaType:)`, щоб пропустити сніфінг при
/// повторному відкритті. Весь `Format` тримаємо, бо він несе ще
/// `specifications` і `fileExtension` — знадобиться у Фазі 2 (дублікати) і
/// Фазі 4 (FB2).
struct OpenedPublication {
    let publication: Publication
    let format: Format

    /// `nil`, якщо сніфер не визначив тип.
    var mediaType: MediaType? { format.mediaType }
}

/// Перетворює файл на Readium `Publication`.
///
/// Скопійовано з офіційного рецепта Readium
/// `Playground/Sources/Recipes/A01-OpenPublication.swift` @ 3.11.0.
///
/// `AssetRetriever` і `PublicationOpener` створюються **всередині методу**, а не
/// зберігаються в полях. Це не недогляд: обидва не `Sendable`, і як властивості
/// `@MainActor`-типу вони спричиняють `SendingRisksDataRace` при виклику
/// nonisolated async методів. Локально створене значення region-based isolation
/// відправити дозволяє. Так само зроблено в рецепті. Вартість створення
/// незначна на тлі парсингу самої книги.
///
/// Клас, а не free function, — щоб у Фазі 2 його можна було підмінити в тестах
/// бібліотеки.
///
/// ⚠️ Класу `Streamer` у Readium 3.x не існує — це API 2.x.
final class ReadiumPublicationService {
    init() {}

    /// Відкриває публікацію за абсолютним URL.
    ///
    /// - Parameters:
    ///   - knownMediaType: збережений із попереднього відкриття тип. Якщо
    ///     заданий, сніфінг формату пропускається.
    ///   - allowUserInteraction: `true`, коли публікація йде в Navigator і
    ///     користувач може ввести пароль до DRM. Для фонового імпорту — `false`,
    ///     інакше Readium покаже діалог посеред пакетної обробки.
    func open(
        url: AbsoluteURL,
        knownMediaType: MediaType? = nil,
        allowUserInteraction: Bool = false,
        sender: Any? = nil
    ) async throws -> OpenedPublication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        let asset = try await {
            if let knownMediaType {
                await assetRetriever.retrieve(url: url, mediaType: knownMediaType)
            } else {
                await assetRetriever.retrieve(url: url)
            }
        }().get()

        let publication = try await publicationOpener
            .open(asset: asset, allowUserInteraction: allowUserInteraction, sender: sender)
            .get()

        return OpenedPublication(publication: publication, format: asset.format)
    }

    /// Відкриває вже підготовлений каталог EPUB (розпакований).
    ///
    /// Використовується для форматів, які Readium не знає й які ми спершу
    /// конвертуємо: TXT, Markdown і RTF сьогодні, FB2 у Фазі 4. Пакувати
    /// результат у ZIP не треба — `DirectoryContainer` подає каталог як
    /// звичайний контейнер.
    func openDirectory(_ directoryURL: URL) async throws -> OpenedPublication {
        guard let fileURL = FileURL(url: directoryURL) else {
            throw PublicationOpenFailure.notAFileURL(directoryURL)
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        let container = try await DirectoryContainer(directory: fileURL)
        let asset = try await assetRetriever
            .retrieve(container: container, hints: FormatHints(mediaType: .epub))
            .get()

        let publication = try await publicationOpener
            .open(asset: asset, allowUserInteraction: false)
            .get()

        return OpenedPublication(publication: publication, format: asset.format)
    }

    /// Зручна обгортка для локальних файлів.
    func open(
        fileURL: URL,
        knownMediaType: MediaType? = nil,
        allowUserInteraction: Bool = false,
        sender: Any? = nil
    ) async throws -> OpenedPublication {
        // Формати, яких Readium не знає, спершу конвертуємо в EPUB.
        if TextToEPUBConverter.handles(fileURL.pathExtension) {
            return try await openDirectory(TextToEPUBConverter.convert(fileURL: fileURL))
        }
        if RTFToEPUBConverter.handles(fileURL.pathExtension) {
            return try await openDirectory(RTFToEPUBConverter.convert(fileURL: fileURL))
        }

        guard let url = FileURL(url: fileURL) else {
            throw PublicationOpenFailure.notAFileURL(fileURL)
        }
        return try await open(
            url: url,
            knownMediaType: knownMediaType,
            allowUserInteraction: allowUserInteraction,
            sender: sender
        )
    }
}
