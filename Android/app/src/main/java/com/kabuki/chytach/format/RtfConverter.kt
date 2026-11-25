package com.kabuki.chytach.format

/**
 * RTF → EPUB.
 *
 * На macOS цей формат розбирає системний `NSAttributedString`. На Android
 * такого немає, тож розбирач тут свій — той самий, що й у Windows-версії.
 * Він свідомо не повний: з RTF нас цікавить те, що впливає на читання —
 * абзаци, накреслення, вирівнювання, кирилиця й вбудовані картинки.
 * Таблиці, колонтитули й поля лишаються поза увагою.
 */
object RtfConverter {

    val EXTENSIONS = setOf("rtf")

    private const val CHARACTERS_PER_CHAPTER = 60_000

    private enum class Align { LEFT, CENTER, RIGHT, JUSTIFY }

    private data class Style(
        val bold: Boolean = false,
        val italic: Boolean = false,
        val underline: Boolean = false,
        val strike: Boolean = false,
    )

    private class Picture(val data: ByteArray, val mediaType: String, val extension: String)

    private class Paragraph(val html: String, val align: Align, val picture: Int? = null)

    /** Таблиця cp1251 для `\'hh`, коли шрифт кириличний. */
    private val CP1251_HIGH = (
        "ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—�™љ›њќћџ ЎўЈ¤Ґ¦§Ё©Є«¬­®Ї" +
            "°±Ііґµ¶·ё№є»јЅѕїАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ" +
            "абвгдежзийклмнопрстуфхцчшщъыьэюя"
        ).toCharArray()

    /** Таблиця cp1252 — типова для англомовних RTF. */
    private val CP1252_HIGH =
        "€�‚ƒ„…†‡ˆ‰Š‹Œ�Ž��‘’“”•–—˜™š›œ�žŸ".toCharArray()

    private fun decodeByte(byte: Int, cyrillic: Boolean): Char {
        val value = byte and 0xFF
        if (value < 0x80) return value.toChar()
        if (cyrillic) return CP1251_HIGH[value - 0x80]
        if (value < 0xA0) return CP1252_HIGH[value - 0x80]
        return value.toChar()
    }

    /**
     * Відкидає все, крім картинок, які браузер уміє показати.
     *
     * У RTF часто лежать метафайли Windows; показати їх ніяк, і краще
     * пропустити картинку, ніж поставити порожню рамку.
     */
    private fun webSafe(data: ByteArray): Pair<String, String>? = when {
        data.size > 4 && data[0] == 0x89.toByte() && data[1] == 'P'.code.toByte() ->
            "image/png" to "png"
        data.size > 3 && data[0] == 0xFF.toByte() && data[1] == 0xD8.toByte() ->
            "image/jpeg" to "jpg"
        data.size > 4 && data[0] == 'G'.code.toByte() && data[1] == 'I'.code.toByte() ->
            "image/gif" to "gif"
        else -> null
    }

    private class Reader(val bytes: ByteArray) {
        var position = 0

        /** Читає керівне слово після зворотної скісної. */
        fun controlWord(): Pair<String, Int?> {
            val start = position
            while (position < bytes.size && (bytes[position].toInt().toChar()).isLetter()) {
                position++
            }
            val word = String(bytes, start, position - start, Charsets.US_ASCII)

            var number: Int? = null
            if (position < bytes.size &&
                (bytes[position] == '-'.code.toByte() ||
                    (bytes[position].toInt().toChar()).isDigit())
            ) {
                val numberStart = position
                if (bytes[position] == '-'.code.toByte()) position++
                while (position < bytes.size && (bytes[position].toInt().toChar()).isDigit()) {
                    position++
                }
                number = String(bytes, numberStart, position - numberStart, Charsets.US_ASCII)
                    .toIntOrNull()
            }

            // Пробіл після слова — роздільник, а не текст.
            if (position < bytes.size && bytes[position] == ' '.code.toByte()) position++
            return word to number
        }
    }

    private fun parse(data: ByteArray): Triple<List<Paragraph>, List<Picture>, String> {
        val reader = Reader(data)

        val paragraphs = mutableListOf<Paragraph>()
        val pictures = mutableListOf<Picture>()
        val title = StringBuilder()

        val text = StringBuilder()
        var style = Style()
        val open = mutableListOf<String>()
        var align = Align.JUSTIFY

        // Стек станів: група відновлює те, що було до неї.
        val stack = mutableListOf<Triple<Style, Align, Pair<Boolean, Int>>>()
        var cyrillic = false
        var skipChars = 0

        var skipDepth: Int? = null
        var depth = 0

        var inPicture = false
        val pictureHex = StringBuilder()
        var inTitle = false

        fun closeAll() {
            while (open.isNotEmpty()) text.append("</${open.removeAt(open.size - 1)}>")
        }

        fun apply(current: Style) {
            closeAll()
            listOf(
                current.bold to "strong",
                current.italic to "em",
                current.underline to "u",
                current.strike to "s",
            ).forEach { (flag, tag) ->
                if (flag) {
                    text.append("<$tag>")
                    open += tag
                }
            }
        }

        while (reader.position < reader.bytes.size) {
            val byte = reader.bytes[reader.position]

            when (byte) {
                '{'.code.toByte() -> {
                    reader.position++
                    depth++
                    stack += Triple(style, align, cyrillic to open.size)
                }

                '}'.code.toByte() -> {
                    reader.position++
                    if (inPicture && skipDepth == depth) {
                        val hex = pictureHex.toString()
                        val bytes = ByteArray(hex.length / 2) { index ->
                            hex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
                        }
                        webSafe(bytes)?.let { (mediaType, extension) ->
                            pictures += Picture(bytes, mediaType, extension)
                            paragraphs += Paragraph("", Align.CENTER, pictures.size - 1)
                        }
                        pictureHex.setLength(0)
                        inPicture = false
                    }
                    if (skipDepth == depth) skipDepth = null
                    if (inTitle && skipDepth == null) inTitle = false
                    depth = (depth - 1).coerceAtLeast(0)

                    if (stack.isNotEmpty()) {
                        val (previousStyle, previousAlign, rest) = stack.removeAt(stack.size - 1)
                        val (previousCyrillic, openSize) = rest
                        while (open.size > openSize) {
                            text.append("</${open.removeAt(open.size - 1)}>")
                        }
                        style = previousStyle
                        align = previousAlign
                        cyrillic = previousCyrillic
                    }
                }

                '\\'.code.toByte() -> {
                    reader.position++
                    if (reader.position >= reader.bytes.size) break
                    val next = reader.bytes[reader.position]

                    when {
                        next == '\\'.code.toByte() || next == '{'.code.toByte() ||
                            next == '}'.code.toByte() -> {
                            reader.position++
                            if (skipDepth == null) text.append(next.toInt().toChar())
                        }

                        next == '\''.code.toByte() -> {
                            reader.position++
                            val available = minOf(2, reader.bytes.size - reader.position)
                            val hex = String(reader.bytes, reader.position, available, Charsets.US_ASCII)
                            reader.position += available
                            // Назва книги теж пишеться екранованими
                            // байтами; без перевірки на заголовок вона
                            // лягала б і в назву, і в текст першого абзацу.
                            when {
                                skipChars > 0 -> skipChars--
                                inTitle -> hex.toIntOrNull(16)?.let {
                                    title.append(decodeByte(it, cyrillic))
                                }
                                // Екрануємо так само, як звичайні байти:
                                // кутову дужку в RTF можна записати через
                                // \'3c, і без цього вона потрапила б у
                                // розмітку як розмітка.
                                skipDepth == null -> hex.toIntOrNull(16)?.let {
                                    text.append(
                                        EpubBuilder.escape(decodeByte(it, cyrillic).toString())
                                    )
                                }
                            }
                        }

                        next == '*'.code.toByte() -> {
                            // `\*\destination` — те, чого читач не бачить.
                            reader.position++
                            skipDepth = depth
                        }

                        else -> {
                            val (word, number) = reader.controlWord()
                            when (word) {
                                "par", "line" -> if (skipDepth == null) {
                                    closeAll()
                                    paragraphs += Paragraph(text.toString(), align)
                                    text.setLength(0)
                                    apply(style)
                                }
                                "pard" -> {
                                    align = Align.JUSTIFY
                                    style = Style()
                                    closeAll()
                                }
                                "b" -> { style = style.copy(bold = number != 0); apply(style) }
                                "i" -> { style = style.copy(italic = number != 0); apply(style) }
                                "ul" -> { style = style.copy(underline = number != 0); apply(style) }
                                "ulnone" -> { style = style.copy(underline = false); apply(style) }
                                "strike" -> { style = style.copy(strike = number != 0); apply(style) }
                                "plain" -> { style = Style(); closeAll() }
                                "qc" -> align = Align.CENTER
                                "qr" -> align = Align.RIGHT
                                "ql" -> align = Align.LEFT
                                "qj" -> align = Align.JUSTIFY
                                "fcharset" -> cyrillic = number == 204
                                "ansicpg" -> cyrillic = number == 1251
                                "uc" -> skipChars = (number ?: 1).coerceAtLeast(0)
                                "u" -> if (number != null) {
                                    // Відʼємні значення — те саме число,
                                    // записане зі знаком.
                                    val code = if (number < 0) number + 65536 else number
                                    if (skipDepth == null && code in 1..0x10FFFF) {
                                        text.append(
                                            EpubBuilder.escape(String(Character.toChars(code)))
                                        )
                                    }
                                    // Далі йде запасний запис того самого
                                    // символу — його пропускаємо.
                                    skipChars = 1
                                }
                                "pict" -> {
                                    inPicture = true
                                    skipDepth = depth
                                    pictureHex.setLength(0)
                                }
                                "title" -> inTitle = true
                                "fonttbl", "colortbl", "stylesheet", "header", "footer",
                                "footnote", "listtable", "generator" -> skipDepth = depth
                                "tab" -> if (skipDepth == null) text.append('\t')
                                "emdash" -> if (skipDepth == null) text.append('—')
                                "endash" -> if (skipDepth == null) text.append('–')
                                "ldblquote" -> if (skipDepth == null) text.append('«')
                                "rdblquote" -> if (skipDepth == null) text.append('»')
                                "lquote" -> if (skipDepth == null) text.append('‘')
                                "rquote" -> if (skipDepth == null) text.append('’')
                            }
                        }
                    }
                }

                '\r'.code.toByte(), '\n'.code.toByte() -> reader.position++

                else -> {
                    reader.position++
                    when {
                        inPicture -> {
                            val ch = byte.toInt().toChar()
                            if (ch.isDigit() || ch in 'a'..'f' || ch in 'A'..'F') {
                                pictureHex.append(ch)
                            }
                        }
                        skipDepth != null -> if (inTitle) {
                            title.append(decodeByte(byte.toInt(), cyrillic))
                        }
                        skipChars > 0 -> skipChars--
                        inTitle -> title.append(decodeByte(byte.toInt(), cyrillic))
                        else -> text.append(
                            EpubBuilder.escape(decodeByte(byte.toInt(), cyrillic).toString())
                        )
                    }
                }
            }
        }

        closeAll()
        if (text.isNotBlank()) paragraphs += Paragraph(text.toString(), align)

        return Triple(paragraphs, pictures, title.toString().trim())
    }

    /** Перетворює RTF на EPUB. */
    fun convert(data: ByteArray, fallbackTitle: String): ByteArray {
        val (paragraphs, pictures, parsedTitle) = parse(data)

        val resources = mutableListOf<EpubBuilder.Resource>()
        val paths = mutableMapOf<Int, String>()
        pictures.forEachIndexed { index, picture ->
            val path = "images/rtf-${index + 1}.${picture.extension}"
            paths[index] = path
            resources += EpubBuilder.Resource(path, picture.mediaType, picture.data)
        }

        val chapters = mutableListOf<EpubBuilder.Chapter>()
        val body = StringBuilder()
        var size = 0

        for (paragraph in paragraphs) {
            val html = if (paragraph.picture != null) {
                val path = paths[paragraph.picture] ?: continue
                """<p style="text-align:center !important"><img src="$path"/></p>"""
            } else {
                val content = paragraph.html.trim()
                if (content.isEmpty()) {
                    """<p class="empty-line"><br/></p>"""
                } else {
                    // Вирівнювання вбудованим стилем: класу Readium не слухає.
                    val style = when (paragraph.align) {
                        Align.CENTER -> """ style="text-indent:0 !important;text-align:center !important""""
                        Align.RIGHT -> """ style="text-indent:0 !important;text-align:right !important""""
                        Align.LEFT -> """ style="text-indent:0 !important;text-align:left !important""""
                        Align.JUSTIFY -> ""
                    }
                    "<p$style>$content</p>"
                }
            }

            size += html.length
            body.append(html).append('\n')

            if (size >= CHARACTERS_PER_CHAPTER) {
                chapters += EpubBuilder.Chapter(body = body.toString())
                body.setLength(0)
                size = 0
            }
        }
        if (body.isNotBlank()) chapters += EpubBuilder.Chapter(body = body.toString())

        val title = parsedTitle.ifBlank { fallbackTitle }
        return EpubBuilder.build(
            EpubBuilder.Metadata(title = title, identifier = "chytach-rtf-${title.hashCode()}"),
            chapters,
            resources,
        )
    }
}
