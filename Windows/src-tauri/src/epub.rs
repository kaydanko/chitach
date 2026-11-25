//! Збирання EPUB із розділів.
//!
//! Конвертери форматів дають метадані й XHTML-розділи, а пакування,
//! маніфест і зміст — тут. Те саме, що робить `EPUBBuilder` у версії для
//! macOS, і з тими самими шаблонами: книга, зібрана на різних системах,
//! має виглядати однаково.

use std::io::{Cursor, Write};

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

pub struct Chapter {
    pub title: Option<String>,
    /// Вміст `<body>` у вигляді XHTML.
    pub body: String,
}

pub struct Resource {
    /// Шлях усередині теки `EPUB/`.
    pub path: String,
    pub media_type: String,
    pub data: Vec<u8>,
    pub is_cover: bool,
}

pub struct Metadata {
    pub title: String,
    pub authors: Vec<String>,
    pub language: String,
    pub identifier: String,
}

impl Default for Metadata {
    fn default() -> Self {
        Self {
            title: String::new(),
            authors: Vec::new(),
            language: "uk".to_string(),
            identifier: String::new(),
        }
    }
}

/// Екранує текст для вставки в XML.
pub fn escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Стилі для розмітки, якої не буває у звичайному EPUB.
///
/// Вірші, строфи, епіграфи й підписи приходять із FB2, і без цих правил
/// поезія виглядає як низка звичайних абзаців. `!important` обовʼязковий:
/// Readium CSS задає виключку й відступи теж через нього.
const STRUCTURAL_CSS: &str = r#".poem { margin: 1.1em 0; }
.stanza { margin-bottom: 1em; }
.stanza:last-child { margin-bottom: 0; }
.verse {
  margin: 0 !important;
  line-height: 1.45;
}
.epigraph {
  margin: 1.2em 0 1.4em 12%;
  font-style: italic;
  border: 0;
  padding: 0;
}
.cite { margin: 1.1em 0 1.1em 6%; }
.text-author { font-style: italic; margin-top: 0.4em; }
.subtitle { font-weight: 600; margin: 1.1em 0 0.7em; }
.annotation { margin: 0 0 1.4em; font-style: italic; }
.empty-line { margin: 0 !important; }
.note { text-decoration: none; }
.backref { font-size: 0.85em; margin: 0.3em 0 1em !important; }
img { max-width: 100%; height: auto; }"#;

fn container_xml() -> String {
    r#"<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"#
        .to_string()
}

fn chapter_xhtml(chapter: &Chapter, language: &str, fallback_title: &str) -> String {
    let title = escape(chapter.title.as_deref().unwrap_or(fallback_title));
    let language = escape(language);
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="{language}" lang="{language}">
<head>
  <meta charset="UTF-8"/>
  <title>{title}</title>
  <style>{STRUCTURAL_CSS}</style>
</head>
<body>
{}
</body>
</html>"#,
        chapter.body
    )
}

fn nav_xhtml(chapters: &[Chapter], metadata: &Metadata) -> String {
    let items: Vec<String> = chapters
        .iter()
        .enumerate()
        .map(|(index, chapter)| {
            let title = chapter
                .title
                .clone()
                .unwrap_or_else(|| format!("Частина {}", index + 1));
            format!(
                r#"      <li><a href="chapter{}.xhtml">{}</a></li>"#,
                index + 1,
                escape(&title)
            )
        })
        .collect();

    let language = escape(&metadata.language);
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{language}" lang="{language}">
<head>
  <meta charset="UTF-8"/>
  <title>{}</title>
</head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>Зміст</h1>
    <ol>
{}
    </ol>
  </nav>
</body>
</html>"#,
        escape(&metadata.title),
        items.join("\n")
    )
}

fn package_opf(chapters: &[Chapter], resources: &[Resource], metadata: &Metadata) -> String {
    let chapter_items: Vec<String> = (1..=chapters.len())
        .map(|index| {
            format!(
                r#"    <item id="ch{index}" href="chapter{index}.xhtml" media-type="application/xhtml+xml"/>"#
            )
        })
        .collect();

    let resource_items: Vec<String> = resources
        .iter()
        .enumerate()
        .map(|(index, resource)| {
            let properties = if resource.is_cover {
                r#" properties="cover-image""#
            } else {
                ""
            };
            format!(
                r#"    <item id="res{}" href="{}" media-type="{}"{properties}/>"#,
                index + 1,
                escape(&resource.path),
                escape(&resource.media_type)
            )
        })
        .collect();

    let spine: Vec<String> = (1..=chapters.len())
        .map(|index| format!(r#"    <itemref idref="ch{index}"/>"#))
        .collect();

    let authors: Vec<String> = metadata
        .authors
        .iter()
        .map(|author| format!("    <dc:creator>{}</dc:creator>", escape(author)))
        .collect();

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">{}</dc:identifier>
    <dc:title>{}</dc:title>
    <dc:language>{}</dc:language>
{}
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{}
{}
  </manifest>
  <spine>
{}
  </spine>
</package>"#,
        escape(&metadata.identifier),
        escape(&metadata.title),
        escape(&metadata.language),
        authors.join("\n"),
        chapter_items.join("\n"),
        resource_items.join("\n"),
        spine.join("\n")
    )
}

/// Збирає EPUB у памʼяті.
///
/// Віддаємо байти архіву, а не теку на диску: далі їх однаково розбирає
/// той самий код, що й звичайну книгу, тож конвертовані формати не
/// потребують жодного окремого шляху.
pub fn build(
    metadata: &Metadata,
    chapters: &[Chapter],
    resources: &[Resource],
) -> Result<Vec<u8>, String> {
    let fallback = Chapter {
        title: None,
        body: "<p></p>".to_string(),
    };
    let chapters: &[Chapter] = if chapters.is_empty() {
        std::slice::from_ref(&fallback)
    } else {
        chapters
    };

    let mut buffer = Vec::new();
    {
        let mut zip = ZipWriter::new(Cursor::new(&mut buffer));

        // `mimetype` мусить бути першим і без стиснення — так вимагає
        // специфікація EPUB, і за цим файлом формат упізнають.
        zip.start_file(
            "mimetype",
            SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
        )
        .map_err(|e| e.to_string())?;
        zip.write_all(b"application/epub+zip")
            .map_err(|e| e.to_string())?;

        let deflated =
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);

        let mut put = |path: &str, data: &[u8]| -> Result<(), String> {
            zip.start_file(path, deflated).map_err(|e| e.to_string())?;
            zip.write_all(data).map_err(|e| e.to_string())
        };

        put("META-INF/container.xml", container_xml().as_bytes())?;

        for (index, chapter) in chapters.iter().enumerate() {
            put(
                &format!("EPUB/chapter{}.xhtml", index + 1),
                chapter_xhtml(chapter, &metadata.language, &metadata.title).as_bytes(),
            )?;
        }

        for resource in resources {
            put(&format!("EPUB/{}", resource.path), &resource.data)?;
        }

        put("EPUB/nav.xhtml", nav_xhtml(chapters, metadata).as_bytes())?;
        put(
            "EPUB/package.opf",
            package_opf(chapters, resources, metadata).as_bytes(),
        )?;

        zip.finish().map_err(|e| e.to_string())?;
    }

    Ok(buffer)
}
