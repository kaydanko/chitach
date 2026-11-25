package com.kabuki.chytach.library

import android.content.Context
import android.net.Uri
import com.kabuki.chytach.reader.BookAppearance
import org.json.JSONArray
import org.json.JSONObject
import org.readium.r2.shared.publication.Locator

/** Книга, яку вже відкривали. */
data class BookRecord(
    val uri: Uri,
    val title: String,
    val author: String,
    val progress: Double,
    val openedAt: Long,
)

/**
 * Памʼять застосунку: бібліотека, місце читання в кожній книзі та
 * обране оформлення.
 *
 * Сховище просте — `SharedPreferences`. Книг у читалці десятки, не
 * тисячі, і база даних тут була б рішенням без задачі.
 */
class BookLibrary(context: Context) {

    private val preferences =
        context.getSharedPreferences("chytach", Context.MODE_PRIVATE)

    // MARK: — Остання книга

    var lastBook: Uri?
        get() = preferences.getString(KEY_LAST_BOOK, null)?.let(Uri::parse)
        set(value) {
            preferences.edit().putString(KEY_LAST_BOOK, value?.toString()).apply()
        }

    // MARK: — Місце читання

    fun locator(book: Uri): Locator? {
        val stored = preferences.getString(locatorKey(book), null) ?: return null
        return runCatching { Locator.fromJSON(JSONObject(stored)) }.getOrNull()
    }

    fun saveLocator(book: Uri, locator: Locator) {
        preferences.edit()
            .putString(locatorKey(book), locator.toJSON().toString())
            .apply()
    }

    // MARK: — Бібліотека

    /** Перелік книг, недавно читані вгорі. */
    fun books(): List<BookRecord> =
        readBooks().sortedByDescending { it.openedAt }

    /** Додає книгу або піднімає наявну вгору. */
    fun noteOpened(book: Uri) {
        val books = readBooks().toMutableList()
        val index = books.indexOfFirst { it.uri == book }
        val now = System.currentTimeMillis()

        if (index >= 0) {
            books[index] = books[index].copy(openedAt = now)
        } else {
            books += BookRecord(
                uri = book,
                // Назва поки невідома: її дасть розбір книги.
                title = book.lastPathSegment?.substringAfterLast('/') ?: book.toString(),
                author = "",
                progress = 0.0,
                openedAt = now,
            )
        }
        writeBooks(books)
        lastBook = book
    }

    /** Доповнює запис тим, що вичитано з книги. */
    fun describe(book: Uri, title: String, author: String, progress: Double) {
        val books = readBooks().toMutableList()
        val index = books.indexOfFirst { it.uri == book }
        if (index < 0) return

        books[index] = books[index].copy(
            title = title.ifBlank { books[index].title },
            author = author,
            progress = progress.coerceIn(0.0, 1.0),
        )
        writeBooks(books)
    }

    fun forget(book: Uri) {
        preferences.edit().remove(locatorKey(book)).apply()
        writeBooks(readBooks().filterNot { it.uri == book })
        if (lastBook == book) lastBook = null
    }

    private fun readBooks(): List<BookRecord> {
        val stored = preferences.getString(KEY_BOOKS, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(stored)
            (0 until array.length()).mapNotNull { index ->
                val json = array.optJSONObject(index) ?: return@mapNotNull null
                val uri = json.optString("uri").takeIf { it.isNotBlank() }
                    ?: return@mapNotNull null
                BookRecord(
                    uri = Uri.parse(uri),
                    title = json.optString("title"),
                    author = json.optString("author"),
                    progress = json.optDouble("progress", 0.0),
                    openedAt = json.optLong("openedAt", 0),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun writeBooks(books: List<BookRecord>) {
        val array = JSONArray()
        for (book in books) {
            array.put(
                JSONObject()
                    .put("uri", book.uri.toString())
                    .put("title", book.title)
                    .put("author", book.author)
                    .put("progress", book.progress)
                    .put("openedAt", book.openedAt)
            )
        }
        preferences.edit().putString(KEY_BOOKS, array.toString()).apply()
    }

    // MARK: — Оформлення

    /**
     * Зберігаємо лише те, що міняє людина: решта значень — константи, і
     * тягнути їх крізь сховище означало б лишити колись підібране число
     * назавжди, навіть коли воно в коді зміниться.
     */
    fun loadAppearance() {
        with(BookAppearance) {
            paperColor = preferences.getInt(KEY_PAPER, DEFAULT_PAPER)
            inkColor = preferences.getInt(KEY_INK, DEFAULT_INK)
            fontSize = preferences.getFloat(KEY_FONT, MINIMUM_FONT_SIZE.toFloat()).toDouble()
            leftMargin = preferences.getFloat(KEY_LEFT, DEFAULT_SIDE_MARGIN.toFloat()).toDouble()
            rightMargin = preferences.getFloat(KEY_RIGHT, DEFAULT_SIDE_MARGIN.toFloat()).toDouble()
            spreadGap = preferences.getFloat(KEY_GAP, DEFAULT_SPREAD_GAP.toFloat()).toDouble()
        }
    }

    fun saveAppearance() {
        with(BookAppearance) {
            preferences.edit()
                .putInt(KEY_PAPER, paperColor)
                .putInt(KEY_INK, inkColor)
                .putFloat(KEY_FONT, fontSize.toFloat())
                .putFloat(KEY_LEFT, leftMargin.toFloat())
                .putFloat(KEY_RIGHT, rightMargin.toFloat())
                .putFloat(KEY_GAP, spreadGap.toFloat())
                .apply()
        }
    }

    private fun locatorKey(book: Uri) = "locator:$book"

    private companion object {
        const val KEY_LAST_BOOK = "lastBook"
        const val KEY_BOOKS = "books"
        const val KEY_PAPER = "paperColor"
        const val KEY_INK = "inkColor"
        const val KEY_FONT = "fontSize"
        const val KEY_LEFT = "leftMargin"
        const val KEY_RIGHT = "rightMargin"
        const val KEY_GAP = "spreadGap"
    }
}
