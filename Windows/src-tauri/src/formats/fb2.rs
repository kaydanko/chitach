//! FB2 і FB2.ZIP → EPUB.
//!
//! FB2 — це XML, у якому текст лежить у `<body>`, а картинки наприкінці
//! файлу в `<binary>` у вигляді base64. Розмітка там своя: вірші,
//! строфи, епіграфи, підписи, зноски. Завдання конвертера — перекласти
//! її в XHTML так, щоб усе це лишилося видимим, а не перетворилося на
//! низку однакових абзаців.
//!
//! Відповідності тегів і класів ті самі, що у версії для macOS.

use std::collections::HashMap;

use base64::Engine;
use quick_xml::events::Event;
use quick_xml::Reader;

use crate::epub::{self, Chapter, Metadata, Resource};

pub const EXTENSIONS: &[&str] = &["fb2"];
pub const ZIP_EXTENSIONS: &[&str] = &["fb2z", "zip"];

/// Вбудовані стилі замість класів для вирівнювання.
///
/// Readium CSS нав'язує виключку користувача правилом виду
/// `:root[style*="--USER__textAlign"] p { … !important }`. Воно
/// специфічніше за будь-який наш клас, тож рядок вірша розтягувало б по
/// ширині, а підпис під епіграфом стояв би ліворуч.
const FLUSH_LEFT: &str = "text-indent:0 !important;text-align:left !important";
const FLUSH_RIGHT: &str = "text-indent:0 !important;text-align:right !important";
const CENTERED: &str = "text-indent:0 !important;text-align:center !important";
const NO_INDENT: &str = "text-indent:0 !important";

fn inline_tag(name: &str) -> Option<&'static str> {
    Some(match name {
        "emphasis" => "em",
        "strong" => "strong",
        "strikethrough" => "s",
        "sub" => "sub",
        "sup" => "sup",
        "code" => "code",
        _ => return None,
    })
}

/// Блок: тег, клас і вбудований стиль.
fn block_tag(name: &str) -> Option<(&'static str, Option<&'static str>, Option<&'static str>)> {
    Some(match name {
        "p" => ("p", None, None),
        "subtitle" => ("p", Some("subtitle"), Some(CENTERED)),
        "cite" => ("blockquote", Some("cite"), None),
        "epigraph" => ("blockquote", Some("epigraph"), None),
        "poem" => ("div", Some("poem"), None),
        "stanza" => ("div", Some("stanza"), None),
        "v" => ("p", Some("verse"), Some(FLUSH_LEFT)),
        "text-author" => ("p", Some("text-author"), Some(FLUSH_RIGHT)),
        "table" => ("table", None, None),
        "tr" => ("tr", None, None),
        "td" => ("td", None, None),
        "th" => ("th", None, None),
        "annotation" => ("div", Some("annotation"), None),
        _ => return None,
    })
}

#[derive(Default)]
struct Book {
    title: String,
    authors: Vec<String>,
    language: String,
    cover_id: Option<String>,
    /// Готові розділи основного тексту.
    chapters: Vec<Chapter>,
    /// Зноски: ідентифікатор розділу → XHTML.
    notes: Vec<(String, String)>,
    binaries: Vec<(String, String, Vec<u8>)>,
}

/// Де саме ми зараз у файлі.
#[derive(PartialEq, Clone, Copy)]
enum Region {
    Outside,
    Description,
    Body,
    Notes,
    Binary,
}

fn attribute(event: &quick_xml::events::BytesStart, name: &str) -> Option<String> {
    event.attributes().flatten().find_map(|attr| {
        let key = String::from_utf8_lossy(attr.key.as_ref()).to_string();
        // `l:href` і `xlink:href` — те саме посилання з різними просторами.
        let key = key.rsplit(':').next().unwrap_or(&key).to_string();
        if key == name {
            Some(String::from_utf8_lossy(&attr.value).to_string())
        } else {
            None
        }
    })
}

/// Ідентифікатор, яким безпечно заповнювати атрибут.
///
/// Усе це пише той, хто зібрав книгу: і `id` у зносці, і адреса картинки.
/// Без перевірки туди можна вкласти лапку й дописати свій атрибут, а
/// розділ книги малюється в кадрі зі скриптами. Тому лишаємо рівно те, з
/// чого складаються справжні ідентифікатори.
fn safe_id(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .take(128)
        .collect();
    cleaned
}

fn media_extension(media_type: &str) -> &str {
    match media_type {
        "image/png" => "png",
        "image/gif" => "gif",
        "image/svg+xml" => "svg",
        "image/webp" => "webp",
        _ => "jpg",
    }
}

/// Розбирає FB2 у книгу.
fn parse(data: &[u8]) -> Result<Book, String> {
    let mut reader = Reader::from_reader(data);
    reader.config_mut().trim_text(false);
    reader.config_mut().check_end_names = false;

    let mut book = Book {
        language: "uk".to_string(),
        ..Default::default()
    };

    let mut region = Region::Outside;
    let mut description_path: Vec<String> = Vec::new();
    let mut author_parts: Vec<String> = Vec::new();
    let mut in_author = false;

    // Поточний розділ основного тексту.
    let mut output = String::new();
    let mut section_depth = 0usize;
    let mut title_depth = 0usize;
    let mut quote_depth = 0usize;
    let mut current_title: Option<String> = None;
    let mut title_text = String::new();

    // Зноски.
    let mut note_id = String::new();
    let mut note_output = String::new();
    let mut note_back: HashMap<String, String> = HashMap::new();
    let mut reference_count = 0usize;

    let mut binary_id = String::new();
    let mut binary_type = String::new();
    let mut binary_buffer = String::new();

    let mut buffer = Vec::new();

    loop {
        let event = reader
            .read_event_into(&mut buffer)
            .map_err(|e| format!("розбір FB2: {e}"))?;

        match event {
            Event::Eof => break,

            Event::Start(ref start) => {
                let raw = String::from_utf8_lossy(start.name().as_ref()).to_string();
                let name = raw.rsplit(':').next().unwrap_or(&raw).to_string();

                match name.as_str() {
                    "description" => region = Region::Description,
                    "binary" => {
                        region = Region::Binary;
                        binary_id = attribute(start, "id").unwrap_or_default();
                        binary_type = attribute(start, "content-type")
                            .unwrap_or_else(|| "image/jpeg".to_string());
                        binary_buffer.clear();
                    }
                    "body" => {
                        // `<body name="notes">` — це зноски, а не текст.
                        region = if attribute(start, "name").as_deref() == Some("notes") {
                            Region::Notes
                        } else {
                            Region::Body
                        };
                    }
                    _ => match region {
                        Region::Description => {
                            description_path.push(name.clone());
                            if name == "author" {
                                in_author = true;
                                author_parts.clear();
                            }
                            if name == "image" {
                                if description_path.iter().any(|p| p == "coverpage") {
                                    book.cover_id = attribute(start, "href")
                                        .map(|href| safe_id(href.trim_start_matches('#')));
                                }
                            }
                        }
                        Region::Body | Region::Notes => {
                            let target = if region == Region::Notes {
                                &mut note_output
                            } else {
                                &mut output
                            };

                            match name.as_str() {
                                "section" => {
                                    if region == Region::Notes {
                                        note_id = attribute(start, "id").map(|id| safe_id(&id)).unwrap_or_default();
                                        note_output.clear();
                                    } else {
                                        section_depth += 1;
                                    }
                                }
                                "title" => {
                                    title_depth += 1;
                                    title_text.clear();
                                    target.push_str("<h2>");
                                }
                                "empty-line" => {
                                    target.push_str(r#"<p class="empty-line"><br/></p>"#);
                                }
                                "image" => {
                                    if let Some(href) = attribute(start, "href") {
                                        let id = safe_id(href.trim_start_matches('#'));
                                        target.push_str(&format!("<img src=\"@@IMG:{id}@@\"/>"));
                                    }
                                }
                                "a" => {
                                    let href = attribute(start, "href").unwrap_or_default();
                                    let target_id = safe_id(href.trim_start_matches('#'));
                                    let is_note =
                                        attribute(start, "type").as_deref() == Some("note");

                                    let mut extra = String::new();
                                    if is_note {
                                        extra.push_str(" class=\"note\"");
                                        // Своє місце в тексті посилання отримує
                                        // лише в основному тексті: саме сюди
                                        // веде зворотний перехід зі зноски.
                                        if region == Region::Body {
                                            reference_count += 1;
                                            let id = format!("fb2-ref-{reference_count}");
                                            extra.push_str(&format!(" id=\"{id}\""));
                                            note_back.entry(target_id.clone()).or_insert(id);
                                        }
                                    }
                                    target.push_str(&format!(
                                        "<a href=\"@@LINK:{target_id}@@\"{extra}>"
                                    ));
                                }
                                other => {
                                    if let Some(tag) = inline_tag(other) {
                                        target.push_str(&format!("<{tag}>"));
                                    } else if let Some((tag, class, style)) = block_tag(other) {
                                        if other == "epigraph" || other == "cite" {
                                            quote_depth += 1;
                                        }
                                        let class = class
                                            .map(|c| format!(" class=\"{c}\""))
                                            .unwrap_or_default();
                                        // Абзац усередині епіграфа чи цитати
                                        // теж без червоного рядка.
                                        let style = style.or(if other == "p" && quote_depth > 0 {
                                            Some(NO_INDENT)
                                        } else {
                                            None
                                        });
                                        let style = style
                                            .map(|s| format!(" style=\"{s}\""))
                                            .unwrap_or_default();
                                        target.push_str(&format!("<{tag}{class}{style}>"));
                                    }
                                }
                            }
                        }
                        _ => {}
                    },
                }
            }

            Event::Empty(ref start) => {
                let raw = String::from_utf8_lossy(start.name().as_ref()).to_string();
                let name = raw.rsplit(':').next().unwrap_or(&raw).to_string();

                match region {
                    Region::Description if name == "image" => {
                        if description_path.iter().any(|p| p == "coverpage") {
                            book.cover_id = attribute(start, "href")
                                .map(|href| safe_id(href.trim_start_matches('#')));
                        }
                    }
                    Region::Body | Region::Notes => {
                        let target = if region == Region::Notes {
                            &mut note_output
                        } else {
                            &mut output
                        };
                        match name.as_str() {
                            "empty-line" => {
                                target.push_str(r#"<p class="empty-line"><br/></p>"#)
                            }
                            "image" => {
                                if let Some(href) = attribute(start, "href") {
                                    let id = safe_id(href.trim_start_matches('#'));
                                    target.push_str(&format!("<img src=\"@@IMG:{id}@@\"/>"));
                                }
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }

            Event::Text(ref text) => {
                let value = text.decode().map_err(|e| e.to_string())?.into_owned();
                match region {
                    Region::Binary => binary_buffer.push_str(value.trim()),
                    Region::Description => {
                        let trimmed = value.trim();
                        if trimmed.is_empty() {
                            continue;
                        }
                        let current = description_path.last().map(String::as_str).unwrap_or("");
                        let in_title_info = description_path.iter().any(|p| p == "title-info");
                        match current {
                            "book-title" if in_title_info => book.title = trimmed.to_string(),
                            "lang" if in_title_info => book.language = trimmed.to_string(),
                            "first-name" | "middle-name" | "last-name" | "nickname"
                                if in_author =>
                            {
                                author_parts.push(trimmed.to_string())
                            }
                            _ => {}
                        }
                    }
                    Region::Body | Region::Notes => {
                        let escaped = epub::escape(&value);
                        if title_depth > 0 {
                            title_text.push_str(value.trim());
                        }
                        if region == Region::Notes {
                            note_output.push_str(&escaped);
                        } else {
                            output.push_str(&escaped);
                        }
                    }
                    Region::Outside => {}
                }
            }

            Event::End(ref end) => {
                let raw = String::from_utf8_lossy(end.name().as_ref()).to_string();
                let name = raw.rsplit(':').next().unwrap_or(&raw).to_string();

                match name.as_str() {
                    "description" if region == Region::Description => {
                        region = Region::Outside;
                        description_path.clear();
                    }
                    "binary" if region == Region::Binary => {
                        let cleaned: String =
                            binary_buffer.chars().filter(|c| !c.is_whitespace()).collect();
                        if let Ok(bytes) =
                            base64::engine::general_purpose::STANDARD.decode(cleaned)
                        {
                            if !bytes.is_empty() && !binary_id.is_empty() {
                                book.binaries.push((
                                    safe_id(&binary_id),
                                    binary_type.clone(),
                                    bytes,
                                ));
                            }
                        }
                        binary_buffer.clear();
                        region = Region::Outside;
                    }
                    "body" if region == Region::Body || region == Region::Notes => {
                        if region == Region::Body && !output.trim().is_empty() {
                            book.chapters.push(Chapter {
                                title: current_title.take(),
                                body: std::mem::take(&mut output),
                            });
                        }
                        region = Region::Outside;
                    }
                    _ => match region {
                        Region::Description => {
                            if name == "author" {
                                in_author = false;
                                let full = author_parts.join(" ");
                                if !full.trim().is_empty() {
                                    book.authors.push(full.trim().to_string());
                                }
                            }
                            description_path.pop();
                        }
                        Region::Body | Region::Notes => {
                            let in_notes = region == Region::Notes;

                            match name.as_str() {
                                "section" => {
                                    if in_notes {
                                        if !note_id.is_empty() {
                                            book.notes.push((
                                                note_id.clone(),
                                                std::mem::take(&mut note_output),
                                            ));
                                            note_id.clear();
                                        }
                                    } else {
                                        section_depth = section_depth.saturating_sub(1);
                                        // Кожна секція верхнього рівня —
                                        // окремий розділ книги.
                                        if section_depth == 0 && !output.trim().is_empty() {
                                            book.chapters.push(Chapter {
                                                title: current_title.take(),
                                                body: std::mem::take(&mut output),
                                            });
                                        }
                                    }
                                }
                                "title" => {
                                    title_depth = title_depth.saturating_sub(1);
                                    let target = if in_notes {
                                        &mut note_output
                                    } else {
                                        &mut output
                                    };
                                    target.push_str("</h2>");
                                    if !in_notes && current_title.is_none() {
                                        let trimmed = title_text.trim();
                                        if !trimmed.is_empty() {
                                            current_title = Some(trimmed.to_string());
                                        }
                                    }
                                }
                                "a" => {
                                    let target = if in_notes {
                                        &mut note_output
                                    } else {
                                        &mut output
                                    };
                                    target.push_str("</a>");
                                }
                                other => {
                                    let target = if in_notes {
                                        &mut note_output
                                    } else {
                                        &mut output
                                    };
                                    if let Some(tag) = inline_tag(other) {
                                        target.push_str(&format!("</{tag}>"));
                                    } else if let Some((tag, _, _)) = block_tag(other) {
                                        if other == "epigraph" || other == "cite" {
                                            quote_depth = quote_depth.saturating_sub(1);
                                        }
                                        target.push_str(&format!("</{tag}>"));
                                    }
                                }
                            }
                        }
                        _ => {}
                    },
                }
            }

            _ => {}
        }
        buffer.clear();
    }

    // Зноски йдуть окремим розділом наприкінці книги, з переходом назад
    // до того місця, звідки на них послалися.
    if !book.notes.is_empty() {
        let mut body = String::new();
        for (id, html) in &book.notes {
            body.push_str(&format!("<div id=\"fb2-note-{id}\">{html}"));
            if let Some(back) = note_back.get(id) {
                body.push_str(&format!(
                    "<p class=\"backref\"><a href=\"@@LINK:{back}@@\">↩</a></p>"
                ));
            }
            body.push_str("</div>");
        }
        book.chapters.push(Chapter {
            title: Some("Примітки".to_string()),
            body,
        });
    }

    Ok(book)
}

/// Перетворює FB2 на EPUB.
pub fn convert(data: &[u8], fallback_title: &str) -> Result<Vec<u8>, String> {
    let book = parse(data)?;

    // Картинки стають файлами книги, а мітки в тексті — посиланнями на них.
    let mut resources = Vec::new();
    let mut image_paths: HashMap<String, String> = HashMap::new();
    for (id, media_type, bytes) in &book.binaries {
        // Ідентифікатор у FB2 часто вже схожий на імʼя файлу («cover.png»),
        // і додавати розширення вдруге ні до чого. Небезпечні для шляху
        // символи прибираємо: ідентифікатор пише той, хто зібрав книгу.
        let safe: String = id
            .chars()
            .map(|c| if c.is_alphanumeric() || c == '.' || c == '-' || c == '_' { c } else { '_' })
            .collect();
        let extension = media_extension(media_type);
        let path = if safe.to_ascii_lowercase().ends_with(&format!(".{extension}")) {
            format!("images/{safe}")
        } else {
            format!("images/{safe}.{extension}")
        };
        image_paths.insert(id.clone(), path.clone());
        resources.push(Resource {
            path,
            media_type: media_type.clone(),
            data: bytes.clone(),
            is_cover: book.cover_id.as_deref() == Some(id.as_str()),
        });
    }

    // Куди веде кожен ідентифікатор: зноска має свій розділ, решта —
    // якір усередині книги.
    let note_ids: Vec<String> = book.notes.iter().map(|(id, _)| id.clone()).collect();
    let notes_chapter = book.chapters.len(); // номер розділу зі зносками

    let mut chapters = book.chapters;
    for (index, chapter) in chapters.iter_mut().enumerate() {
        let mut body = std::mem::take(&mut chapter.body);

        // Картинки.
        for (id, path) in &image_paths {
            body = body.replace(&format!("@@IMG:{id}@@"), path);
        }
        // Посилання, які нікуди не ведуть, лишати не можна: Readium
        // спіткнеться на невідомій адресі.
        while let Some(start) = body.find("@@LINK:") {
            let Some(end) = body[start..].find("@@").and_then(|_| {
                body[start + 7..].find("@@").map(|offset| start + 7 + offset)
            }) else {
                break;
            };
            let id = body[start + 7..end].to_string();
            let replacement = if note_ids.contains(&id) {
                format!("chapter{}.xhtml#fb2-note-{id}", notes_chapter)
            } else if id.starts_with("fb2-ref-") {
                format!("chapter{}.xhtml#{id}", index + 1)
            } else {
                format!("#{id}")
            };
            body.replace_range(start..end + 2, &replacement);
        }

        chapter.body = body;
    }

    let title = if book.title.trim().is_empty() {
        fallback_title.to_string()
    } else {
        book.title.clone()
    };

    epub::build(
        &Metadata {
            title: title.clone(),
            authors: book.authors,
            language: book.language,
            identifier: format!("chytach-fb2-{}", crate::book_id(&title)),
        },
        &chapters,
        &resources,
    )
}

/// Дістає FB2 із архіву й конвертує.
pub fn convert_zip(data: &[u8], fallback_title: &str) -> Result<Vec<u8>, String> {
    use std::io::Read;

    let mut archive =
        zip::ZipArchive::new(std::io::Cursor::new(data)).map_err(|e| e.to_string())?;

    for index in 0..archive.len() {
        let mut file = archive.by_index(index).map_err(|e| e.to_string())?;
        if file.is_dir() {
            continue;
        }
        let name = file.name().to_ascii_lowercase();
        if !name.ends_with(".fb2") {
            continue;
        }
        // Стеля та сама, що й для звичайної книги: заявлений розмір
        // усередині архіву пише той, хто його зібрав.
        let mut bytes = Vec::new();
        file.take(crate::MAX_ENTRY_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > crate::MAX_ENTRY_BYTES {
            return Err("Файл усередині архіву завеликий".to_string());
        }
        return convert(&bytes, fallback_title);
    }

    Err("В архіві немає файлу FB2".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r##"<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns:l="http://www.w3.org/1999/xlink">
  <description>
    <title-info>
      <book-title>Проба пера</book-title>
      <lang>uk</lang>
      <author><first-name>Леся</first-name><last-name>Українка</last-name></author>
    </title-info>
  </description>
  <body>
    <section>
      <title><p>Перший розділ</p></title>
      <p>Звичайний абзац з <emphasis>похилим</emphasis> словом.</p>
      <poem><stanza><v>Рядок перший</v><v>Рядок другий</v></stanza></poem>
      <epigraph><p>Цитата</p><text-author>Хтось</text-author></epigraph>
      <p>Слово зі зноскою<a l:href="#n1" type="note">1</a>.</p>
    </section>
  </body>
  <body name="notes">
    <section id="n1"><p>Пояснення.</p></section>
  </body>
</FictionBook>"##;

    #[test]
    fn метадані_читаються() {
        let book = parse(SAMPLE.as_bytes()).unwrap();
        assert_eq!(book.title, "Проба пера");
        assert_eq!(book.language, "uk");
        assert_eq!(book.authors, vec!["Леся Українка"]);
    }

    #[test]
    fn вірші_не_стають_абзацами() {
        let book = parse(SAMPLE.as_bytes()).unwrap();
        let body = &book.chapters[0].body;
        assert!(body.contains(r#"<div class="poem">"#));
        assert!(body.contains(r#"<div class="stanza">"#));
        assert!(body.contains(r#"<p class="verse""#));
        // Рядок вірша мусить мати вбудований стиль: класу Readium не слухає.
        assert!(body.contains("text-align:left !important"));
    }

    #[test]
    fn епіграф_і_підпис_на_місці() {
        let book = parse(SAMPLE.as_bytes()).unwrap();
        let body = &book.chapters[0].body;
        assert!(body.contains(r#"<blockquote class="epigraph">"#));
        assert!(body.contains(r#"<p class="text-author""#));
        assert!(body.contains("text-align:right !important"));
    }

    #[test]
    fn зноска_отримує_свій_розділ_і_перехід_назад() {
        let book = parse(SAMPLE.as_bytes()).unwrap();
        // Основний текст плюс розділ приміток.
        assert_eq!(book.chapters.len(), 2);
        assert_eq!(book.notes.len(), 1);
        assert!(book.chapters[1].body.contains("fb2-note-n1"));
        assert!(book.chapters[1].body.contains("backref"));
    }

    #[test]
    fn чужий_атрибут_із_книги_не_потрапляє_в_розмітку() {
        // Ідентифікатор із лапкою — спроба дописати свій атрибут у тег.
        let evil = r##"<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns:l="http://www.w3.org/1999/xlink">
  <description><title-info><book-title>Проба</book-title></title-info></description>
  <body><section><p>Текст<a l:href="#x&quot; onload=&quot;alert(1)" type="note">1</a></p></section></body>
  <body name="notes"><section id="x"><p>Нота</p></section></body>
</FictionBook>"##;

        let book = parse(evil.as_bytes()).unwrap();
        let all: String = book.chapters.iter().map(|c| c.body.clone()).collect();
        assert!(!all.contains("onload="), "атрибут із книги пройшов: {all}");
        assert!(!all.contains("alert(1)"), "атрибут із книги пройшов: {all}");
    }

    #[test]
    fn збирається_відкривний_epub() {
        let epub = convert(SAMPLE.as_bytes(), "Запасна").unwrap();
        let unpacked = crate::unpack(epub).unwrap();
        assert!(unpacked.entries.contains_key("EPUB/package.opf"));

        let opf = String::from_utf8_lossy(&unpacked.entries["EPUB/package.opf"]);
        assert!(opf.contains("<dc:title>Проба пера</dc:title>"));
        assert!(opf.contains("Леся Українка"));

        let chapter = String::from_utf8_lossy(&unpacked.entries["EPUB/chapter1.xhtml"]);
        // Мітки посилань мусять зникнути: Readium спіткнеться на такій адресі.
        assert!(!chapter.contains("@@LINK"));
        assert!(!chapter.contains("@@IMG"));
    }
}
