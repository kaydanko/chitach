package com.kabuki.chytach.library

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import org.readium.r2.shared.publication.Locator

/**
 * Пам'ять про книги: яка була відкрита востаннє і на якому місці.
 *
 * Поки що це не бібліотека, а дві речі, без яких читалка не читалка:
 * застосунок має відкриватися там, де його закрили.
 */
class BookLibrary(context: Context) {

    private val preferences =
        context.getSharedPreferences("chytach", Context.MODE_PRIVATE)

    /** Книга, яку читали востаннє. */
    var lastBook: Uri?
        get() = preferences.getString(KEY_LAST_BOOK, null)?.let(Uri::parse)
        set(value) {
            preferences.edit()
                .putString(KEY_LAST_BOOK, value?.toString())
                .apply()
        }

    fun forget(book: Uri) {
        preferences.edit()
            .remove(locatorKey(book))
            .apply()
        if (lastBook == book) lastBook = null
    }

    /** Місце, на якому зупинилися в цій книзі. */
    fun locator(book: Uri): Locator? {
        val stored = preferences.getString(locatorKey(book), null) ?: return null
        return runCatching { Locator.fromJSON(JSONObject(stored)) }.getOrNull()
    }

    fun saveLocator(book: Uri, locator: Locator) {
        preferences.edit()
            .putString(locatorKey(book), locator.toJSON().toString())
            .apply()
    }

    private fun locatorKey(book: Uri) = "locator:$book"

    private companion object {
        const val KEY_LAST_BOOK = "lastBook"
    }
}
