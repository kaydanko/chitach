package com.kabuki.chytach.book

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import com.kabuki.chytach.format.Fb2Converter
import com.kabuki.chytach.format.RtfConverter
import com.kabuki.chytach.format.TextConverter
import java.io.File
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.AbsoluteUrl
import org.readium.r2.shared.util.Error
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.toAbsoluteUrl
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

    /**
     * Відкриває книгу за адресою, яку дала система.
     *
     * Формати, яких Readium не знає, спершу стають EPUB: конвертер читає
     * байти, складає архів і кладе його в кеш. Далі книга відкривається
     * звичайним шляхом — окремої гілки для конвертованих форматів немає.
     */
    suspend fun open(book: Uri): Try<Publication, Error> {
        val name = displayName(book)
        val extension = name.substringAfterLast('.', "").lowercase()

        if (extension in TextConverter.EXTENSIONS ||
            extension in Fb2Converter.EXTENSIONS ||
            extension in Fb2Converter.ZIP_EXTENSIONS ||
            extension in RtfConverter.EXTENSIONS
        ) {
            return when (val converted = convert(book, name, extension)) {
                is Try.Success -> open(converted.value)
                is Try.Failure -> Try.failure(converted.value)
            }
        }

        val url = book.toAbsoluteUrl()
            ?: return Try.failure(org.readium.r2.shared.util.DebugError("Незрозуміла адреса книги"))
        return open(url)
    }

    /** Читає файл, конвертує його в EPUB і лишає архів у кеші. */
    private fun convert(book: Uri, name: String, extension: String): Try<AbsoluteUrl, Error> {
        return try {
            val data = application.contentResolver.openInputStream(book)?.use { it.readBytes() }
                ?: return Try.failure(
                    org.readium.r2.shared.util.DebugError("Не вдалося прочитати $name")
                )

            val title = name.substringBeforeLast('.', name)
            val epub = when (extension) {
                in TextConverter.EXTENSIONS -> TextConverter.convert(data, title)
                in Fb2Converter.EXTENSIONS -> Fb2Converter.convert(data, title)
                in Fb2Converter.ZIP_EXTENSIONS -> Fb2Converter.convertZip(data, title)
                in RtfConverter.EXTENSIONS -> RtfConverter.convert(data, title)
                else -> return Try.failure(
                    org.readium.r2.shared.util.DebugError("Формат $extension поки не підтримується")
                )
            }

            val cache = File(application.cacheDir, "converted").apply { mkdirs() }
            // Імʼя з хеша шляху: та сама книга не конвертується двічі, а
            // різні книги з однаковою назвою не перетирають одна одну.
            val file = File(cache, "${book.toString().hashCode()}.epub")
            file.writeBytes(epub)

            Try.success(file.toUrl(isDirectory = false))
        } catch (error: Exception) {
            Try.failure(
                org.readium.r2.shared.util.DebugError(error.message ?: "Не вдалося конвертувати")
            )
        }
    }

    /** Імʼя файлу так, як його показує система. */
    private fun displayName(book: Uri): String {
        application.contentResolver
            .query(book, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst() && cursor.columnCount > 0) {
                    cursor.getString(0)?.let { return it }
                }
            }
        return book.lastPathSegment?.substringAfterLast('/') ?: book.toString()
    }

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
