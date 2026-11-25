package com.kabuki.chytach.format

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Збирання EPUB із розділів.
 *
 * Конвертери форматів дають метадані й XHTML-розділи, а пакування,
 * маніфест і зміст — тут. Те саме, що робить `EPUBBuilder` у версії для
 * macOS, і з тими самими шаблонами: книга, зібрана на різних системах,
 * має виглядати однаково.
 */
object EpubBuilder {

    data class Chapter(val title: String? = null, val body: String)

    data class Resource(
        /** Шлях усередині теки `EPUB/`. */
        val path: String,
        val mediaType: String,
        val data: ByteArray,
        val isCover: Boolean = false,
    )

    data class Metadata(
        val title: String,
        val authors: List<String> = emptyList(),
        val language: String = "uk",
        val identifier: String = "",
    )

    /** Екранує текст для вставки в XML. */
    fun escape(value: String): String = buildString(value.length) {
        for (ch in value) {
            when (ch) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '"' -> append("&quot;")
                '\'' -> append("&apos;")
                else -> append(ch)
            }
        }
    }

    /**
     * Стилі для розмітки, якої не буває у звичайному EPUB.
     *
     * Вірші, строфи, епіграфи й підписи приходять із FB2, і без цих правил
     * поезія виглядає як низка звичайних абзаців. `!important` обовʼязковий:
     * Readium CSS задає виключку й відступи теж через нього.
     */
    private val STRUCTURAL_CSS = """
        |.poem { margin: 1.1em 0; }
        |.stanza { margin-bottom: 1em; }
        |.stanza:last-child { margin-bottom: 0; }
        |.verse {
        |  margin: 0 !important;
        |  line-height: 1.45;
        }
        |.epigraph {
        |  margin: 1.2em 0 1.4em 12%;
        |  font-style: italic;
        |  border: 0;
        |  padding: 0;
        }
        |.cite { margin: 1.1em 0 1.1em 6%; }
        |.text-author { font-style: italic; margin-top: 0.4em; }
        |.subtitle { font-weight: 600; margin: 1.1em 0 0.7em; }
        |.annotation { margin: 0 0 1.4em; font-style: italic; }
        |.empty-line { margin: 0 !important; }
        |.note { text-decoration: none; }
        |.backref { font-size: 0.85em; margin: 0.3em 0 1em !important; }
        |img { max-width: 100%; height: auto; }
    """.trimMargin()

    private fun containerXML(): String = """
        |<?xml version="1.0" encoding="UTF-8"?>
        |<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        |  <rootfiles>
        |    <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
        |  </rootfiles>
        |</container>
    """.trimMargin()

    private fun chapterXHTML(chapter: Chapter, language: String, fallbackTitle: String): String {
        val title = escape(chapter.title ?: fallbackTitle)
        val lang = escape(language)
        return """
            |<?xml version="1.0" encoding="UTF-8"?>
            |<!DOCTYPE html>
            |<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="$lang" lang="$lang">
            |<head>
            |  <meta charset="UTF-8"/>
            |  <title>$title</title>
            |  <style>$STRUCTURAL_CSS</style>
            |</head>
            |<body>
            |${chapter.body}
            |</body>
            |</html>
        """.trimMargin()
    }

    private fun navXHTML(chapters: List<Chapter>, metadata: Metadata): String {
        val items = chapters.mapIndexed { index, chapter ->
            val title = chapter.title ?: "Частина ${index + 1}"
            """      <li><a href="chapter${index + 1}.xhtml">${escape(title)}</a></li>"""
        }.joinToString("\n")

        val lang = escape(metadata.language)
        return """
            |<?xml version="1.0" encoding="UTF-8"?>
            |<!DOCTYPE html>
            |<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="$lang" lang="$lang">
            |<head>
            |  <meta charset="UTF-8"/>
            |  <title>${escape(metadata.title)}</title>
            |</head>
            |<body>
            |  <nav epub:type="toc" id="toc">
            |    <h1>Зміст</h1>
            |    <ol>
            |$items
            |    </ol>
            |  </nav>
            |</body>
            |</html>
        """.trimMargin()
    }

    private fun packageOPF(
        chapters: List<Chapter>,
        resources: List<Resource>,
        metadata: Metadata,
    ): String {
        val chapterItems = (1..chapters.size).joinToString("\n") {
            """    <item id="ch$it" href="chapter$it.xhtml" media-type="application/xhtml+xml"/>"""
        }
        val resourceItems = resources.mapIndexed { index, resource ->
            val properties = if (resource.isCover) """ properties="cover-image"""" else ""
            """    <item id="res${index + 1}" href="${escape(resource.path)}" """ +
                """media-type="${escape(resource.mediaType)}"$properties/>"""
        }.joinToString("\n")
        val spine = (1..chapters.size).joinToString("\n") { """    <itemref idref="ch$it"/>""" }
        val authors = metadata.authors.joinToString("\n") {
            "    <dc:creator>${escape(it)}</dc:creator>"
        }

        return """
            |<?xml version="1.0" encoding="UTF-8"?>
            |<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
            |  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            |    <dc:identifier id="pub-id">${escape(metadata.identifier)}</dc:identifier>
            |    <dc:title>${escape(metadata.title)}</dc:title>
            |    <dc:language>${escape(metadata.language)}</dc:language>
            |$authors
            |  </metadata>
            |  <manifest>
            |    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            |$chapterItems
            |$resourceItems
            |  </manifest>
            |  <spine>
            |$spine
            |  </spine>
            |</package>
        """.trimMargin()
    }

    /** Збирає EPUB у памʼяті. */
    fun build(
        metadata: Metadata,
        chapters: List<Chapter>,
        resources: List<Resource> = emptyList(),
    ): ByteArray {
        val parts = chapters.ifEmpty { listOf(Chapter(body = "<p></p>")) }

        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zip ->
            // `mimetype` мусить бути першим і без стиснення — так вимагає
            // специфікація EPUB, і за цим файлом формат упізнають.
            val mimetype = "application/epub+zip".toByteArray()
            zip.setMethod(ZipOutputStream.STORED)
            val entry = ZipEntry("mimetype").apply {
                method = ZipEntry.STORED
                size = mimetype.size.toLong()
                compressedSize = mimetype.size.toLong()
                crc = CRC32().apply { update(mimetype) }.value
            }
            zip.putNextEntry(entry)
            zip.write(mimetype)
            zip.closeEntry()

            zip.setMethod(ZipOutputStream.DEFLATED)

            fun put(path: String, data: ByteArray) {
                zip.putNextEntry(ZipEntry(path))
                zip.write(data)
                zip.closeEntry()
            }

            put("META-INF/container.xml", containerXML().toByteArray())
            parts.forEachIndexed { index, chapter ->
                put(
                    "EPUB/chapter${index + 1}.xhtml",
                    chapterXHTML(chapter, metadata.language, metadata.title).toByteArray(),
                )
            }
            for (resource in resources) {
                put("EPUB/${resource.path}", resource.data)
            }
            put("EPUB/nav.xhtml", navXHTML(parts, metadata).toByteArray())
            put("EPUB/package.opf", packageOPF(parts, resources, metadata).toByteArray())
        }
        return bytes.toByteArray()
    }
}
