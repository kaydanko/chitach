package com.kabuki.chytach

import android.app.Application
import com.kabuki.chytach.book.BookOpener

class ChytachApplication : Application() {

    /// Одне на застосунок: AssetRetriever і парсери тримають власні кеші,
    /// і створювати їх на кожне відкриття книги немає сенсу.
    val bookOpener: BookOpener by lazy { BookOpener(this) }
}
