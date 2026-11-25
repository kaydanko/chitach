package com.kabuki.chytach.format

import java.nio.charset.Charset

/**
 * TXT і Markdown → EPUB.
 *
 * Та сама поведінка, що в `TextToEPUBConverter` на macOS: визначаємо
 * кодування, ріжемо текст на розділи приблизно по 60 тисяч символів і
 * складаємо з абзаців XHTML.
 */
object TextConverter {

    val EXTENSIONS = setOf("txt", "text", "md", "markdown")

    /**
     * Приблизний розмір розділу. Цілий роман одним файлом Readium розбирає
     * помітно довше, ніж десяток частин.
     */
    const val CHARACTERS_PER_CHAPTER = 60_000

    class UnknownEncoding(name: String) : Exception(
        "Не вдалося визначити кодування файлу «$name». Спробуйте зберегти його в UTF-8."
    )

    /**
     * Читає байти, вгадуючи кодування.
     *
     * Порядок той самий, що на macOS: позначка порядку байтів, тоді UTF-8,
     * тоді кирилиця за схожістю на текст.
     */
    fun readText(data: ByteArray, name: String): String {
        decodeByBOM(data)?.let { return it }

        decodeStrictly(data, Charsets.UTF_8)?.let { return it }

        val candidates = listOfNotNull(
            charsetOrNull("windows-1251"),
            charsetOrNull("KOI8-U"),
            charsetOrNull("KOI8-R"),
            Charsets.ISO_8859_1,
        )

        // Строго більше, а не «не менше»: за рівних оцінок перемагає те
        // кодування, що раніше в переліку. Кирилиця, прочитана трьома
        // способами, часто дає однакову оцінку, і без цього вигравав би
        // latin1 — останній у черзі й найменш імовірний.
        var best: Pair<String, Double>? = null
        for (charset in candidates) {
            val text = String(data, charset)
            val score = plausibility(text)
            if (best == null || score > best.second) best = text to score
        }

        val chosen = best ?: throw UnknownEncoding(name)
        if (chosen.second <= 0.9) throw UnknownEncoding(name)
        return chosen.first
    }

    private fun charsetOrNull(name: String): Charset? =
        runCatching { Charset.forName(name) }.getOrNull()

    private fun decodeByBOM(data: ByteArray): String? {
        if (data.size >= 3 &&
            data[0] == 0xEF.toByte() && data[1] == 0xBB.toByte() && data[2] == 0xBF.toByte()
        ) {
            return String(data, 3, data.size - 3, Charsets.UTF_8)
        }
        if (data.size >= 2 && data[0] == 0xFF.toByte() && data[1] == 0xFE.toByte()) {
            return String(data, 2, data.size - 2, Charsets.UTF_16LE)
        }
        if (data.size >= 2 && data[0] == 0xFE.toByte() && data[1] == 0xFF.toByte()) {
            return String(data, 2, data.size - 2, Charsets.UTF_16BE)
        }
        return null
    }

    /**
     * Декодує лише тоді, коли байти справді цього кодування.
     *
     * `String(bytes, UTF_8)` не вміє відмовити: зіпсоване він підмінює
     * знаком заміни, і файл у cp1251 прикидався б UTF-8 із сміттям.
     */
    private fun decodeStrictly(data: ByteArray, charset: Charset): String? = runCatching {
        charset.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(data))
            .toString()
    }.getOrNull()

    /**
     * Наскільки текст схожий на текст, а не на сміття.
     *
     * Рахуємо частку літер, цифр, пробілів і звичайної пунктуації. Рамки
     * псевдографіки до них не належать навмисно: саме ними розсипається
     * кирилиця, прочитана не в тому кодуванні.
     */
    private fun plausibility(text: String): Double {
        val sample = text.take(4000)
        if (sample.isEmpty()) return 0.0

        val punctuation = ".,;:!?-–—()[]{}\"'«»“”‘’…/\\*#№%+=_@&§"
        val good = sample.count { ch ->
            ch.isLetterOrDigit() || ch.isWhitespace() || punctuation.contains(ch)
        }
        return good.toDouble() / sample.length
    }

    /** Ріже текст на розділи з абзаців. */
    fun splitIntoChapters(text: String): List<List<String>> {
        val paragraphs = text
            .replace("\r\n", "\n")
            .replace('\r', '\n')
            .split('\n')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

        if (paragraphs.isEmpty()) return listOf(listOf(""))

        val chapters = mutableListOf<List<String>>()
        var current = mutableListOf<String>()
        var size = 0

        for (paragraph in paragraphs) {
            current += paragraph
            size += paragraph.length
            if (size >= CHARACTERS_PER_CHAPTER) {
                chapters += current
                current = mutableListOf()
                size = 0
            }
        }
        if (current.isNotEmpty()) chapters += current
        return chapters
    }

    /** Перетворює текстовий файл на EPUB. */
    fun convert(data: ByteArray, title: String): ByteArray {
        val text = readText(data, title)

        val chapters = splitIntoChapters(text).map { paragraphs ->
            EpubBuilder.Chapter(
                body = paragraphs.joinToString("\n") { "  <p>${EpubBuilder.escape(it)}</p>" }
            )
        }

        return EpubBuilder.build(
            EpubBuilder.Metadata(
                title = title,
                identifier = "chytach-txt-${title.hashCode()}",
            ),
            chapters,
        )
    }
}
