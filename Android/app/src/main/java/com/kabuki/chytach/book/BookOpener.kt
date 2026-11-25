package com.kabuki.chytach.book

import android.app.Application
import java.io.File
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.AbsoluteUrl
import org.readium.r2.shared.util.Error
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.toUrl
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser

/**
 * Відкриття книги: файл на диску → `Publication`.
 *
 * Те саме, що робить Swift-версія через `Streamer`: розбір контейнера,
 * метаданих і змісту лишається тулкітові, ми лише даємо йому шлях.
 */
class BookOpener(private val application: Application) {

    private val httpClient = DefaultHttpClient()

    private val assetRetriever =
        AssetRetriever(application.contentResolver, httpClient)

    private val publicationOpener =
        PublicationOpener(
            DefaultPublicationParser(application, httpClient, assetRetriever, null)
        )

    suspend fun open(url: AbsoluteUrl): Try<Publication, Error> {
        val asset = assetRetriever.retrieve(url)
            .getOrElse { return Try.failure(it) }

        val publication = publicationOpener.open(asset, allowUserInteraction = false)
            .getOrElse {
                asset.close()
                return Try.failure(it)
            }

        return Try.success(publication)
    }

    /**
     * Зразок книги зі збірки, скопійований у теку застосунку.
     *
     * Readium читає книгу через `AbsoluteUrl`, а ресурс в `assets` своєї
     * файлової адреси не має — тому копіюємо один раз і далі відкриваємо
     * як звичайний файл. Той самий шлях знадобиться для імпортованих книг.
     */
    fun sampleBookUrl(): AbsoluteUrl {
        val file = File(application.filesDir, "sample.epub")
        if (!file.exists()) {
            application.assets.open("sample.epub").use { input ->
                file.outputStream().use { output -> input.copyTo(output) }
            }
        }
        return file.toUrl(isDirectory = false)
    }
}
