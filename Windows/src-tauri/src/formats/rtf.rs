//! RTF → EPUB.
//!
//! На macOS цей формат розбирає системний `NSAttributedString`. Ні в Rust,
//! ні в Android такого немає, тож розбирач тут свій. Він свідомо не повний:
//! з RTF нас цікавить те, що впливає на читання — абзаци, накреслення,
//! вирівнювання, кирилиця й вбудовані картинки. Таблиці, колонтитули й
//! поля лишаються поза увагою.

use std::collections::HashMap;

use crate::epub::{self, Chapter, Metadata, Resource};

pub const EXTENSIONS: &[&str] = &["rtf"];

/// Приблизний розмір розділу — як і в текстовому конвертері.
const CHARACTERS_PER_CHAPTER: usize = 60_000;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Align {
    Left,
    Center,
    Right,
    Justify,
}

#[derive(Clone, Copy, Default, PartialEq)]
struct Style {
    bold: bool,
    italic: bool,
    underline: bool,
    strike: bool,
}

pub struct Picture {
    pub data: Vec<u8>,
    pub media_type: String,
    pub extension: String,
}

struct Paragraph {
    html: String,
    align: Align,
    /// Номер картинки, якщо абзац — це вона.
    picture: Option<usize>,
}

/// Таблиця cp1251 для `\'hh`, коли шрифт кириличний.
const CP1251_HIGH: [char; 128] = [
    'Ђ', 'Ѓ', '‚', 'ѓ', '„', '…', '†', '‡', '€', '‰', 'Љ', '‹', 'Њ', 'Ќ', 'Ћ', 'Џ', 'ђ', '‘',
    '’', '“', '”', '•', '–', '—', '\u{FFFD}', '™', 'љ', '›', 'њ', 'ќ', 'ћ', 'џ', '\u{A0}', 'Ў',
    'ў', 'Ј', '¤', 'Ґ', '¦', '§', 'Ё', '©', 'Є', '«', '¬', '\u{AD}', '®', 'Ї', '°', '±', 'І',
    'і', 'ґ', 'µ', '¶', '·', 'ё', '№', 'є', '»', 'ј', 'Ѕ', 'ѕ', 'ї', 'А', 'Б', 'В', 'Г', 'Д',
    'Е', 'Ж', 'З', 'И', 'Й', 'К', 'Л', 'М', 'Н', 'О', 'П', 'Р', 'С', 'Т', 'У', 'Ф', 'Х', 'Ц',
    'Ч', 'Ш', 'Щ', 'Ъ', 'Ы', 'Ь', 'Э', 'Ю', 'Я', 'а', 'б', 'в', 'г', 'д', 'е', 'ж', 'з', 'и',
    'й', 'к', 'л', 'м', 'н', 'о', 'п', 'р', 'с', 'т', 'у', 'ф', 'х', 'ц', 'ч', 'ш', 'щ', 'ъ',
    'ы', 'ь', 'э', 'ю', 'я',
];

/// Таблиця cp1252 — типова для англомовних RTF.
const CP1252_HIGH: [char; 32] = [
    '€', '\u{FFFD}', '‚', 'ƒ', '„', '…', '†', '‡', 'ˆ', '‰', 'Š', '‹', 'Œ', '\u{FFFD}', 'Ž',
    '\u{FFFD}', '\u{FFFD}', '‘', '’', '“', '”', '•', '–', '—', '˜', '™', 'š', '›', 'œ',
    '\u{FFFD}', 'ž', 'Ÿ',
];

fn decode_byte(byte: u8, cyrillic: bool) -> char {
    if byte < 0x80 {
        return byte as char;
    }
    if cyrillic {
        return CP1251_HIGH[(byte - 0x80) as usize];
    }
    if byte < 0xA0 {
        return CP1252_HIGH[(byte - 0x80) as usize];
    }
    byte as char
}

/// Відкидає все, крім картинок, які браузер уміє показати.
///
/// У RTF часто лежать метафайли Windows; показати їх ніяк, і краще
/// пропустити картинку, ніж поставити порожню рамку.
fn web_safe(data: &[u8]) -> Option<(String, String)> {
    if data.starts_with(&[0x89, b'P', b'N', b'G']) {
        return Some(("image/png".into(), "png".into()));
    }
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(("image/jpeg".into(), "jpg".into()));
    }
    if data.starts_with(b"GIF8") {
        return Some(("image/gif".into(), "gif".into()));
    }
    None
}

struct Parser<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl<'a> Parser<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, position: 0 }
    }

    /// Читає керівне слово після зворотної скісної.
    fn control_word(&mut self) -> (String, Option<i32>) {
        let start = self.position;
        while self.position < self.bytes.len()
            && self.bytes[self.position].is_ascii_alphabetic()
        {
            self.position += 1;
        }
        let word = String::from_utf8_lossy(&self.bytes[start..self.position]).to_string();

        let mut number: Option<i32> = None;
        if self.position < self.bytes.len()
            && (self.bytes[self.position] == b'-' || self.bytes[self.position].is_ascii_digit())
        {
            let number_start = self.position;
            if self.bytes[self.position] == b'-' {
                self.position += 1;
            }
            while self.position < self.bytes.len() && self.bytes[self.position].is_ascii_digit() {
                self.position += 1;
            }
            number = String::from_utf8_lossy(&self.bytes[number_start..self.position])
                .parse()
                .ok();
        }

        // Пробіл після слова — роздільник, а не текст.
        if self.position < self.bytes.len() && self.bytes[self.position] == b' ' {
            self.position += 1;
        }
        (word, number)
    }
}

/// Розбирає RTF у абзаци й картинки.
fn parse(data: &[u8]) -> (Vec<Paragraph>, Vec<Picture>, String) {
    let mut parser = Parser::new(data);

    let mut paragraphs: Vec<Paragraph> = Vec::new();
    let mut pictures: Vec<Picture> = Vec::new();
    let mut title = String::new();

    let mut text = String::new();
    let mut style = Style::default();
    let mut open: Vec<&'static str> = Vec::new();
    let mut align = Align::Justify;

    // Стек станів: група відновлює те, що було до неї.
    let mut stack: Vec<(Style, Align, bool, usize)> = Vec::new();
    let mut cyrillic = false;
    let mut skip_chars = 0usize;

    // Чого не показуємо зовсім.
    let mut skip_depth: Option<usize> = None;
    let mut depth = 0usize;

    // Збирання картинки.
    let mut in_picture = false;
    let mut picture_hex = String::new();

    // Збирання назви з `\info\title`.
    let mut in_title = false;

    fn close_all(text: &mut String, open: &mut Vec<&'static str>) {
        while let Some(tag) = open.pop() {
            text.push_str(&format!("</{tag}>"));
        }
    }

    fn apply(text: &mut String, open: &mut Vec<&'static str>, style: Style) {
        close_all(text, open);
        for (flag, tag) in [
            (style.bold, "strong"),
            (style.italic, "em"),
            (style.underline, "u"),
            (style.strike, "s"),
        ] {
            if flag {
                text.push_str(&format!("<{tag}>"));
                open.push(tag);
            }
        }
    }

    while parser.position < parser.bytes.len() {
        let byte = parser.bytes[parser.position];

        match byte {
            b'{' => {
                parser.position += 1;
                depth += 1;
                stack.push((style, align, cyrillic, open.len()));
            }
            b'}' => {
                parser.position += 1;
                if in_picture && skip_depth == Some(depth) {
                    // Кінець групи картинки.
                    let bytes: Vec<u8> = picture_hex
                        .as_bytes()
                        .chunks(2)
                        .filter_map(|pair| {
                            if pair.len() == 2 {
                                u8::from_str_radix(
                                    std::str::from_utf8(pair).unwrap_or("zz"),
                                    16,
                                )
                                .ok()
                            } else {
                                None
                            }
                        })
                        .collect();

                    if let Some((media_type, extension)) = web_safe(&bytes) {
                        pictures.push(Picture {
                            data: bytes,
                            media_type,
                            extension,
                        });
                        paragraphs.push(Paragraph {
                            html: String::new(),
                            align: Align::Center,
                            picture: Some(pictures.len() - 1),
                        });
                    }
                    picture_hex.clear();
                    in_picture = false;
                }
                if skip_depth == Some(depth) {
                    skip_depth = None;
                }
                if in_title && skip_depth.is_none() {
                    in_title = false;
                }
                depth = depth.saturating_sub(1);

                if let Some((previous_style, previous_align, previous_cyrillic, open_len)) =
                    stack.pop()
                {
                    while open.len() > open_len {
                        if let Some(tag) = open.pop() {
                            text.push_str(&format!("</{tag}>"));
                        }
                    }
                    style = previous_style;
                    align = previous_align;
                    cyrillic = previous_cyrillic;
                }
            }
            b'\\' => {
                parser.position += 1;
                if parser.position >= parser.bytes.len() {
                    break;
                }
                let next = parser.bytes[parser.position];

                match next {
                    b'\\' | b'{' | b'}' => {
                        parser.position += 1;
                        if skip_depth.is_none() {
                            text.push(next as char);
                        }
                    }
                    b'\'' => {
                        parser.position += 1;
                        let hex: String = parser
                            .bytes
                            .iter()
                            .skip(parser.position)
                            .take(2)
                            .map(|&b| b as char)
                            .collect();
                        parser.position += 2.min(parser.bytes.len() - parser.position);
                        if skip_chars > 0 {
                            skip_chars -= 1;
                        } else if let Ok(value) = u8::from_str_radix(&hex, 16) {
                            let ch = decode_byte(value, cyrillic);
                            // Назва книги теж пишеться екранованими
                            // байтами; без цієї гілки вона лягала б і в
                            // назву, і в текст першого абзацу.
                            if in_title {
                                title.push(ch);
                            } else if skip_depth.is_none() {
                                text.push(ch);
                            }
                        }
                    }
                    b'*' => {
                        // `\*\destination` — те, чого читач не бачить.
                        parser.position += 1;
                        skip_depth = Some(depth);
                    }
                    _ => {
                        let (word, number) = parser.control_word();
                        match word.as_str() {
                            "par" | "line" if skip_depth.is_none() => {
                                close_all(&mut text, &mut open);
                                paragraphs.push(Paragraph {
                                    html: std::mem::take(&mut text),
                                    align,
                                    picture: None,
                                });
                                apply(&mut text, &mut open, style);
                            }
                            "pard" => {
                                align = Align::Justify;
                                style = Style::default();
                                close_all(&mut text, &mut open);
                            }
                            "b" => {
                                style.bold = number != Some(0);
                                apply(&mut text, &mut open, style);
                            }
                            "i" => {
                                style.italic = number != Some(0);
                                apply(&mut text, &mut open, style);
                            }
                            "ul" => {
                                style.underline = number != Some(0);
                                apply(&mut text, &mut open, style);
                            }
                            "ulnone" => {
                                style.underline = false;
                                apply(&mut text, &mut open, style);
                            }
                            "strike" => {
                                style.strike = number != Some(0);
                                apply(&mut text, &mut open, style);
                            }
                            "plain" => {
                                style = Style::default();
                                close_all(&mut text, &mut open);
                            }
                            "qc" => align = Align::Center,
                            "qr" => align = Align::Right,
                            "ql" => align = Align::Left,
                            "qj" => align = Align::Justify,
                            "fcharset" => cyrillic = number == Some(204),
                            "ansicpg" => cyrillic = number == Some(1251),
                            "uc" => skip_chars = 0.max(number.unwrap_or(1)) as usize,
                            "u" => {
                                if let Some(value) = number {
                                    // Відʼємні значення — те саме число,
                                    // записане зі знаком.
                                    let code = if value < 0 {
                                        (value + 65536) as u32
                                    } else {
                                        value as u32
                                    };
                                    if skip_depth.is_none() {
                                        if let Some(ch) = char::from_u32(code) {
                                            text.push(ch);
                                        }
                                    }
                                    // Далі йде запасний запис того самого
                                    // символу — його пропускаємо.
                                    skip_chars = 1;
                                }
                            }
                            "pict" => {
                                in_picture = true;
                                skip_depth = Some(depth);
                                picture_hex.clear();
                            }
                            "title" => in_title = true,
                            "fonttbl" | "colortbl" | "stylesheet" | "info" | "header"
                            | "footer" | "footnote" | "listtable" | "generator" => {
                                if word != "info" {
                                    skip_depth = Some(depth);
                                }
                            }
                            "tab" if skip_depth.is_none() => text.push('\t'),
                            "emdash" if skip_depth.is_none() => text.push('—'),
                            "endash" if skip_depth.is_none() => text.push('–'),
                            "ldblquote" if skip_depth.is_none() => text.push('«'),
                            "rdblquote" if skip_depth.is_none() => text.push('»'),
                            "lquote" if skip_depth.is_none() => text.push('‘'),
                            "rquote" if skip_depth.is_none() => text.push('’'),
                            _ => {}
                        }
                    }
                }
            }
            b'\r' | b'\n' => parser.position += 1,
            _ => {
                parser.position += 1;
                if in_picture {
                    if byte.is_ascii_hexdigit() {
                        picture_hex.push(byte as char);
                    }
                } else if skip_depth.is_some() {
                    // Усередині `\info` назву все-таки збираємо.
                    if in_title {
                        title.push(decode_byte(byte, cyrillic));
                    }
                } else if skip_chars > 0 {
                    skip_chars -= 1;
                } else if in_title {
                    title.push(decode_byte(byte, cyrillic));
                } else {
                    let ch = decode_byte(byte, cyrillic);
                    for escaped in epub::escape(&ch.to_string()).chars() {
                        text.push(escaped);
                    }
                }
            }
        }
    }

    close_all(&mut text, &mut open);
    if !text.trim().is_empty() {
        paragraphs.push(Paragraph {
            html: text,
            align,
            picture: None,
        });
    }

    (paragraphs, pictures, title.trim().to_string())
}

/// Перетворює RTF на EPUB.
pub fn convert(data: &[u8], fallback_title: &str) -> Result<Vec<u8>, String> {
    let (paragraphs, pictures, parsed_title) = parse(data);

    let mut resources = Vec::new();
    let mut paths: HashMap<usize, String> = HashMap::new();
    for (index, picture) in pictures.iter().enumerate() {
        let path = format!("images/rtf-{}.{}", index + 1, picture.extension);
        paths.insert(index, path.clone());
        resources.push(Resource {
            path,
            media_type: picture.media_type.clone(),
            data: picture.data.clone(),
            is_cover: false,
        });
    }

    // Абзаци складаємо в розділи приблизно однакового розміру.
    let mut chapters = Vec::new();
    let mut body = String::new();
    let mut size = 0usize;

    for paragraph in &paragraphs {
        let html = if let Some(index) = paragraph.picture {
            match paths.get(&index) {
                Some(path) => format!("<p style=\"text-align:center !important\"><img src=\"{path}\"/></p>"),
                None => continue,
            }
        } else {
            let content = paragraph.html.trim();
            if content.is_empty() {
                "<p class=\"empty-line\"><br/></p>".to_string()
            } else {
                // Вирівнювання вбудованим стилем: класу Readium не слухає.
                let style = match paragraph.align {
                    Align::Center => " style=\"text-indent:0 !important;text-align:center !important\"",
                    Align::Right => " style=\"text-indent:0 !important;text-align:right !important\"",
                    Align::Left => " style=\"text-indent:0 !important;text-align:left !important\"",
                    Align::Justify => "",
                };
                format!("<p{style}>{content}</p>")
            }
        };

        size += html.chars().count();
        body.push_str(&html);
        body.push('\n');

        if size >= CHARACTERS_PER_CHAPTER {
            chapters.push(Chapter {
                title: None,
                body: std::mem::take(&mut body),
            });
            size = 0;
        }
    }
    if !body.trim().is_empty() {
        chapters.push(Chapter { title: None, body });
    }

    let title = if parsed_title.is_empty() {
        fallback_title.to_string()
    } else {
        parsed_title
    };

    epub::build(
        &Metadata {
            title: title.clone(),
            identifier: format!("chytach-rtf-{}", crate::book_id(&title)),
            ..Default::default()
        },
        &chapters,
        &resources,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn абзаци_й_накреслення() {
        let rtf = r"{\rtf1\ansi Plain text.\par \b Bold\b0  and \i italic\i0 .\par }".as_bytes();
        let (paragraphs, _, _) = parse(rtf);
        assert!(paragraphs.len() >= 2);
        assert!(paragraphs[1].html.contains("<strong>"));
        assert!(paragraphs[1].html.contains("<em>"));
    }

    #[test]
    fn кирилиця_в_cp1251() {
        // `\'cf\'f0\'e8\'e2\'b3\'f2` — «Привіт» у cp1251.
        let rtf = r"{\rtf1\ansi\ansicpg1251 \'cf\'f0\'e8\'e2\'b3\'f2\par }".as_bytes();
        let (paragraphs, _, _) = parse(rtf);
        assert!(
            paragraphs[0].html.contains("Привіт"),
            "вийшло: {}",
            paragraphs[0].html
        );
    }

    #[test]
    fn unicode_записи_читаються() {
        // Запис виду \uNNNN із запасним символом після нього.
        let rtf = format!(
            "{{\\rtf1\\ansi\\uc1 {}u1055 ?{}u1088 ?{}u1080 ?\\par }}",
            '\\', '\\', '\\'
        );
        let (paragraphs, _, _) = parse(rtf.as_bytes());
        assert!(
            paragraphs[0].html.contains("При"),
            "вийшло: {}",
            paragraphs[0].html
        );
    }

    #[test]
    fn вирівнювання_стає_стилем() {
        let rtf = r"{\rtf1\ansi\qc Centered\par }".as_bytes();
        let (paragraphs, _, _) = parse(rtf);
        assert_eq!(paragraphs[0].align, Align::Center);
    }

    #[test]
    fn службові_таблиці_не_потрапляють_у_текст() {
        let rtf = r"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\colortbl;\red0\green0\blue0;}Tekst\par }".as_bytes();
        let (paragraphs, _, _) = parse(rtf);
        let all: String = paragraphs.iter().map(|p| p.html.clone()).collect();
        assert!(!all.contains("Arial"), "у тексті лишилася таблиця шрифтів: {all}");
        assert!(all.contains("Tekst"), "вийшло: {all}");
    }

    #[test]
    fn назва_з_info_не_тече_в_текст() {
        let rtf = r"{\rtf1\ansi{\info{\title Nazva}}Tekst\par }".as_bytes();
        let (paragraphs, _, title) = parse(rtf);
        assert_eq!(title, "Nazva");
        let all: String = paragraphs.iter().map(|p| p.html.clone()).collect();
        assert!(!all.contains("Nazva"), "назва потрапила в текст: {all}");
        assert!(all.contains("Tekst"));
    }

    #[test]
    fn збирається_відкривний_epub() {
        let rtf = r"{\rtf1\ansi First paragraph.\par Second paragraph.\par }".as_bytes();
        let epub = convert(rtf, "Запасна").unwrap();
        let unpacked = crate::unpack(epub).unwrap();
        assert!(unpacked.entries.contains_key("EPUB/chapter1.xhtml"));
        let chapter = String::from_utf8_lossy(&unpacked.entries["EPUB/chapter1.xhtml"]);
        assert!(chapter.contains("First paragraph."));
        assert!(chapter.contains("Second paragraph."));
    }
}
