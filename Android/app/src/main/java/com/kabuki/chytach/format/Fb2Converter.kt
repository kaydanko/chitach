package com.kabuki.chytach.format

import android.util.Base64
import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

/**
 * FB2 і FB2.ZIP → EPUB.
 *
 * FB2 — це XML, у якому текст лежить у `<body>`, а картинки наприкінці
 * файлу в `<binary>` у вигляді base64. Розмітка там своя: вірші, строфи,
 * епіграфи, підписи, зноски. Завдання конвертера — перекласти її в XHTML
 * так, щоб усе це лишилося видимим, а не перетворилося на низку
 * однакових абзаців.
 *
 * Відповідності тегів і класів ті самі, що у версіях для macOS і Windows.
 */
object Fb2Converter {

    val EXTENSIONS = setOf("fb2")
    val ZIP_EXTENSIONS = setOf("fb2z", "zip")

    /**
     * Вбудовані стилі замість класів для вирівнювання.
     *
     * Readium CSS нав'язує виключку користувача правилом виду
     * `:root[style*="--USER__textAlign"] p { … !important }`. Воно
     * специфічніше за будь-який наш клас, тож рядок вірша розтягувало б
     * по ширині, а підпис під епіграфом стояв би ліворуч.
     */
    private const val FLUSH_LEFT = "text-indent:0 !important;text-align:left !important"
    private const val FLUSH_RIGHT = "text-indent:0 !important;text-align:right !important"
    private const val CENTERED = "text-indent:0 !important;text-align:center !important"
    private const val NO_INDENT = "text-indent:0 !important"

    private val INLINE = mapOf(
        "emphasis" to "em",
        "strong" to "strong",
        "strikethrough" to "s",
        "sub" to "sub",
        "sup" to "sup",
        "code" to "code",
    )

    private data class Block(val tag: String, val cssClass: String?, val style: String?)

    private val BLOCKS = mapOf(
        "p" to Block("p", null, null),
        "subtitle" to Block("p", "subtitle", CENTERED),
        "cite" to Block("blockquote", "cite", null),
        "epigraph" to Block("blockquote", "epigraph", null),
        "poem" to Block("div", "poem", null),
        "stanza" to Block("div", "stanza", null),
        "v" to Block("p", "verse", FLUSH_LEFT),
        "text-author" to Block("p", "text-author", FLUSH_RIGHT),
        "table" to Block("table", null, null),
        "tr" to Block("tr", null, null),
        "td" to Block("td", null, null),
        "th" to Block("th", null, null),
        "annotation" to Block("div", "annotation", null),
    )

    private class Book {
        var title = ""
        var language = "uk"
        val authors = mutableListOf<String>()
        var coverId: String? = null
        val chapters = mutableListOf<EpubBuilder.Chapter>()
        val notes = mutableListOf<Pair<String, String>>()
        val binaries = mutableListOf<Triple<String, String, ByteArray>>()
    }

    private enum class Region { OUTSIDE, DESCRIPTION, BODY, NOTES, BINARY }

    /** `l:href` і `xlink:href` — те саме посилання з різними просторами. */
    private fun XmlPullParser.attr(name: String): String? {
        for (index in 0 until attributeCount) {
            if (getAttributeName(index).substringAfterLast(':') == name) {
                return getAttributeValue(index)
            }
        }
        return null
    }

    /**
     * Ідентифікатор, яким безпечно заповнювати атрибут.
     *
     * Усе це пише той, хто зібрав книгу: і `id` у зносці, і адреса
     * картинки. Без перевірки туди можна вкласти лапку й дописати свій
     * атрибут, а розділ книги малюється в кадрі зі скриптами.
     */
    private fun safeId(raw: String): String =
        raw.take(128).map { if (it.isLetterOrDigit() && it.code < 128 || it in ".-_") it else '_' }
            .joinToString("")

    private fun mediaExtension(mediaType: String): String = when (mediaType) {
        "image/png" -> "png"
        "image/gif" -> "gif"
        "image/svg+xml" -> "svg"
        "image/webp" -> "webp"
        else -> "jpg"
    }

    private fun parse(data: ByteArray): Book {
        val parser = XmlPullParserFactory.newInstance().apply {
            isNamespaceAware = false
        }.newPullParser()
        parser.setInput(ByteArrayInputStream(data), null)

        val book = Book()
        var region = Region.OUTSIDE
        val descriptionPath = mutableListOf<String>()
        val authorParts = mutableListOf<String>()
        var inAuthor = false

        val output = StringBuilder()
        val noteOutput = StringBuilder()
        var sectionDepth = 0
        var titleDepth = 0
        var quoteDepth = 0
        var currentTitle: String? = null
        val titleText = StringBuilder()

        var noteId = ""
        val noteBack = mutableMapOf<String, String>()
        var referenceCount = 0

        var binaryId = ""
        var binaryType = "image/jpeg"
        val binaryBuffer = StringBuilder()

        fun target(): StringBuilder = if (region == Region.NOTES) noteOutput else output

        while (parser.eventType != XmlPullParser.END_DOCUMENT) {
            when (parser.eventType) {
                XmlPullParser.START_TAG -> {
                    val name = parser.name.substringAfterLast(':')
                    when (name) {
                        "description" -> region = Region.DESCRIPTION
                        "binary" -> {
                            region = Region.BINARY
                            binaryId = parser.attr("id").orEmpty()
                            binaryType = parser.attr("content-type") ?: "image/jpeg"
                            binaryBuffer.setLength(0)
                        }
                        "body" -> region =
                            if (parser.attr("name") == "notes") Region.NOTES else Region.BODY
                        else -> when (region) {
                            Region.DESCRIPTION -> {
                                descriptionPath += name
                                if (name == "author") {
                                    inAuthor = true
                                    authorParts.clear()
                                }
                                if (name == "image" && descriptionPath.contains("coverpage")) {
                                    book.coverId = parser.attr("href")?.removePrefix("#")?.let(::safeId)
                                }
                            }

                            Region.BODY, Region.NOTES -> when (name) {
                                "section" -> if (region == Region.NOTES) {
                                    noteId = safeId(parser.attr("id").orEmpty())
                                    noteOutput.setLength(0)
                                } else {
                                    sectionDepth++
                                }

                                "title" -> {
                                    titleDepth++
                                    titleText.setLength(0)
                                    target().append("<h2>")
                                }

                                "empty-line" ->
                                    target().append("""<p class="empty-line"><br/></p>""")

                                "image" -> parser.attr("href")?.let { href ->
                                    val id = safeId(href.removePrefix("#"))
                                    target().append("""<img src="@@IMG:$id@@"/>""")
                                }

                                "a" -> {
                                    val targetId = safeId(parser.attr("href").orEmpty().removePrefix("#"))
                                    var extra = ""
                                    if (parser.attr("type") == "note") {
                                        extra = """ class="note""""
                                        // Своє місце в тексті посилання
                                        // отримує лише в основному тексті:
                                        // саме сюди веде перехід зі зноски.
                                        if (region == Region.BODY) {
                                            referenceCount++
                                            val id = "fb2-ref-$referenceCount"
                                            extra += """ id="$id""""
                                            noteBack.putIfAbsent(targetId, id)
                                        }
                                    }
                                    target().append("""<a href="@@LINK:$targetId@@"$extra>""")
                                }

                                else -> {
                                    val inline = INLINE[name]
                                    val block = BLOCKS[name]
                                    if (inline != null) {
                                        target().append("<$inline>")
                                    } else if (block != null) {
                                        if (name == "epigraph" || name == "cite") quoteDepth++
                                        val css = block.cssClass?.let { """ class="$it"""" } ?: ""
                                        // Абзац усередині епіграфа чи цитати
                                        // теж без червоного рядка.
                                        val style = block.style
                                            ?: if (name == "p" && quoteDepth > 0) NO_INDENT else null
                                        val inlineStyle = style?.let { """ style="$it"""" } ?: ""
                                        target().append("<${block.tag}$css$inlineStyle>")
                                    }
                                }
                            }

                            else -> Unit
                        }
                    }
                }

                XmlPullParser.TEXT -> {
                    val value = parser.text ?: ""
                    when (region) {
                        Region.BINARY -> binaryBuffer.append(value.trim())
                        Region.DESCRIPTION -> {
                            val trimmed = value.trim()
                            if (trimmed.isNotEmpty()) {
                                val current = descriptionPath.lastOrNull().orEmpty()
                                val inTitleInfo = descriptionPath.contains("title-info")
                                when {
                                    current == "book-title" && inTitleInfo -> book.title = trimmed
                                    current == "lang" && inTitleInfo -> book.language = trimmed
                                    inAuthor && current in setOf(
                                        "first-name", "middle-name", "last-name", "nickname"
                                    ) -> authorParts += trimmed
                                }
                            }
                        }
                        Region.BODY, Region.NOTES -> {
                            if (titleDepth > 0) titleText.append(value.trim())
                            target().append(EpubBuilder.escape(value))
                        }
                        else -> Unit
                    }
                }

                XmlPullParser.END_TAG -> {
                    val name = parser.name.substringAfterLast(':')
                    when {
                        name == "description" && region == Region.DESCRIPTION -> {
                            region = Region.OUTSIDE
                            descriptionPath.clear()
                        }

                        name == "binary" && region == Region.BINARY -> {
                            val cleaned = binaryBuffer.filter { !it.isWhitespace() }.toString()
                            runCatching { Base64.decode(cleaned, Base64.DEFAULT) }
                                .getOrNull()
                                ?.takeIf { it.isNotEmpty() && binaryId.isNotEmpty() }
                                ?.let { book.binaries += Triple(safeId(binaryId), binaryType, it) }
                            binaryBuffer.setLength(0)
                            region = Region.OUTSIDE
                        }

                        name == "body" && (region == Region.BODY || region == Region.NOTES) -> {
                            if (region == Region.BODY && output.isNotBlank()) {
                                book.chapters += EpubBuilder.Chapter(currentTitle, output.toString())
                                currentTitle = null
                                output.setLength(0)
                            }
                            region = Region.OUTSIDE
                        }

                        region == Region.DESCRIPTION -> {
                            if (name == "author") {
                                inAuthor = false
                                val full = authorParts.joinToString(" ").trim()
                                if (full.isNotEmpty()) book.authors += full
                            }
                            if (descriptionPath.isNotEmpty()) descriptionPath.removeAt(descriptionPath.size - 1)
                        }

                        region == Region.BODY || region == Region.NOTES -> {
                            val inNotes = region == Region.NOTES
                            when (name) {
                                "section" -> if (inNotes) {
                                    if (noteId.isNotEmpty()) {
                                        book.notes += noteId to noteOutput.toString()
                                        noteOutput.setLength(0)
                                        noteId = ""
                                    }
                                } else {
                                    sectionDepth = (sectionDepth - 1).coerceAtLeast(0)
                                    // Кожна секція верхнього рівня —
                                    // окремий розділ книги.
                                    if (sectionDepth == 0 && output.isNotBlank()) {
                                        book.chapters +=
                                            EpubBuilder.Chapter(currentTitle, output.toString())
                                        currentTitle = null
                                        output.setLength(0)
                                    }
                                }

                                "title" -> {
                                    titleDepth = (titleDepth - 1).coerceAtLeast(0)
                                    target().append("</h2>")
                                    if (!inNotes && currentTitle == null) {
                                        val trimmed = titleText.toString().trim()
                                        if (trimmed.isNotEmpty()) currentTitle = trimmed
                                    }
                                }

                                "a" -> target().append("</a>")

                                else -> {
                                    val inline = INLINE[name]
                                    val block = BLOCKS[name]
                                    if (inline != null) {
                                        target().append("</$inline>")
                                    } else if (block != null) {
                                        if (name == "epigraph" || name == "cite") {
                                            quoteDepth = (quoteDepth - 1).coerceAtLeast(0)
                                        }
                                        target().append("</${block.tag}>")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            parser.next()
        }

        // Зноски йдуть окремим розділом наприкінці книги, з переходом назад
        // до того місця, звідки на них послалися.
        if (book.notes.isNotEmpty()) {
            val body = StringBuilder()
            for ((id, html) in book.notes) {
                body.append("""<div id="fb2-note-$id">$html""")
                noteBack[id]?.let {
                    body.append("""<p class="backref"><a href="@@LINK:$it@@">↩</a></p>""")
                }
                body.append("</div>")
            }
            book.chapters += EpubBuilder.Chapter("Примітки", body.toString())
        }

        return book
    }

    /** Перетворює FB2 на EPUB. */
    fun convert(data: ByteArray, fallbackTitle: String): ByteArray {
        val book = parse(data)

        val resources = mutableListOf<EpubBuilder.Resource>()
        val imagePaths = mutableMapOf<String, String>()
        for ((id, mediaType, bytes) in book.binaries) {
            // Ідентифікатор у FB2 часто вже схожий на імʼя файлу
            // («cover.png»), і додавати розширення вдруге ні до чого.
            val safe = id.map { if (it.isLetterOrDigit() || it in ".-_") it else '_' }.joinToString("")
            val extension = mediaExtension(mediaType)
            val path = if (safe.lowercase().endsWith(".$extension")) "images/$safe"
            else "images/$safe.$extension"

            imagePaths[id] = path
            resources += EpubBuilder.Resource(
                path = path,
                mediaType = mediaType,
                data = bytes,
                isCover = book.coverId == id,
            )
        }

        val noteIds = book.notes.map { it.first }
        val notesChapter = book.chapters.size

        val chapters = book.chapters.mapIndexed { index, chapter ->
            var body = chapter.body
            for ((id, path) in imagePaths) {
                body = body.replace("@@IMG:$id@@", path)
            }
            // Посилання, які нікуди не ведуть, лишати не можна: Readium
            // спіткнеться на невідомій адресі.
            body = Regex("@@LINK:([^@]*)@@").replace(body) { match ->
                val id = match.groupValues[1]
                when {
                    id in noteIds -> "chapter$notesChapter.xhtml#fb2-note-$id"
                    id.startsWith("fb2-ref-") -> "chapter${index + 1}.xhtml#$id"
                    else -> "#$id"
                }
            }
            chapter.copy(body = body)
        }

        val title = book.title.ifBlank { fallbackTitle }
        return EpubBuilder.build(
            EpubBuilder.Metadata(
                title = title,
                authors = book.authors,
                language = book.language,
                identifier = "chytach-fb2-${title.hashCode()}",
            ),
            chapters,
            resources,
        )
    }

    /** Стеля на розпакований файл усередині архіву. */
    private const val MAX_ENTRY_BYTES = 64L * 1024 * 1024

    /**
     * Дістає FB2 із архіву й конвертує.
     *
     * Читаємо з обмеженням: заявлений розмір усередині архіву пише той,
     * хто його зібрав, і книга з сотнею гігабайтів у заголовку поклала б
     * застосунок просто на відкритті.
     */
    fun convertZip(data: ByteArray, fallbackTitle: String): ByteArray {
        ZipInputStream(ByteArrayInputStream(data)).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                if (!entry.isDirectory && entry.name.lowercase().endsWith(".fb2")) {
                    val out = java.io.ByteArrayOutputStream()
                    val chunk = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = zip.read(chunk)
                        if (read <= 0) break
                        total += read
                        if (total > MAX_ENTRY_BYTES) {
                            throw IllegalArgumentException("Файл усередині архіву завеликий")
                        }
                        out.write(chunk, 0, read)
                    }
                    return convert(out.toByteArray(), fallbackTitle)
                }
                entry = zip.nextEntry
            }
        }
        throw IllegalArgumentException("В архіві немає файлу FB2")
    }
}
