//! TXT і Markdown → EPUB.
//!
//! Та сама поведінка, що в `TextToEPUBConverter` на macOS: визначаємо
//! кодування, ріжемо текст на розділи приблизно по 60 тисяч символів і
//! складаємо з абзаців XHTML.

use crate::epub::{self, Chapter, Metadata};

pub const EXTENSIONS: &[&str] = &["txt", "text", "md", "markdown"];

/// Приблизний розмір розділу. Цілий роман одним файлом Readium розбирає
/// помітно довше, ніж десяток частин.
const CHARACTERS_PER_CHAPTER: usize = 60_000;

/// Верхня половина cp1251: від 0x80 до 0xFF.
const CP1251: [char; 128] = [
    'Ђ', 'Ѓ', '‚', 'ѓ', '„', '…', '†', '‡', '€', '‰', 'Љ', '‹', 'Њ', 'Ќ', 'Ћ', 'Џ', 'ђ', '‘',
    '’', '“', '”', '•', '–', '—', '\u{FFFD}', '™', 'љ', '›', 'њ', 'ќ', 'ћ', 'џ', '\u{A0}', 'Ў',
    'ў', 'Ј', '¤', 'Ґ', '¦', '§', 'Ё', '©', 'Є', '«', '¬', '\u{AD}', '®', 'Ї', '°', '±', 'І',
    'і', 'ґ', 'µ', '¶', '·', 'ё', '№', 'є', '»', 'ј', 'Ѕ', 'ѕ', 'ї', 'А', 'Б', 'В', 'Г', 'Д',
    'Е', 'Ж', 'З', 'И', 'Й', 'К', 'Л', 'М', 'Н', 'О', 'П', 'Р', 'С', 'Т', 'У', 'Ф', 'Х', 'Ц',
    'Ч', 'Ш', 'Щ', 'Ъ', 'Ы', 'Ь', 'Э', 'Ю', 'Я', 'а', 'б', 'в', 'г', 'д', 'е', 'ж', 'з', 'и',
    'й', 'к', 'л', 'м', 'н', 'о', 'п', 'р', 'с', 'т', 'у', 'ф', 'х', 'ц', 'ч', 'ш', 'щ', 'ъ',
    'ы', 'ь', 'э', 'ю', 'я',
];

/// Верхня половина koi8-u: від 0x80 до 0xFF.
const KOI8U: [char; 128] = [
    '─', '│', '┌', '┐', '└', '┘', '├', '┤', '┬', '┴', '┼', '▀', '▄', '█', '▌', '▐', '░', '▒',
    '▓', '⌠', '■', '∙', '√', '≈', '≤', '≥', '\u{A0}', '⌡', '°', '²', '·', '÷', '═', '║', '╒',
    'ё', 'є', '╔', 'і', 'ї', '╗', '╘', '╙', '╚', '╛', 'ґ', '╝', '╞', '╟', '╠', '╡', 'Ё', 'Є',
    '╣', 'І', 'Ї', '╦', '╧', '╨', '╩', '╪', 'Ґ', '╬', '©', 'ю', 'а', 'б', 'ц', 'д', 'е', 'ф',
    'г', 'х', 'и', 'й', 'к', 'л', 'м', 'н', 'о', 'п', 'я', 'р', 'с', 'т', 'у', 'ж', 'в', 'ь',
    'ы', 'з', 'ш', 'э', 'щ', 'ч', 'ъ', 'Ю', 'А', 'Б', 'Ц', 'Д', 'Е', 'Ф', 'Г', 'Х', 'И', 'Й',
    'К', 'Л', 'М', 'Н', 'О', 'П', 'Я', 'Р', 'С', 'Т', 'У', 'Ж', 'В', 'Ь', 'Ы', 'З', 'Ш', 'Э',
    'Щ', 'Ч', 'Ъ',
];

fn decode_table(data: &[u8], table: &[char; 128]) -> String {
    data.iter()
        .map(|&byte| {
            if byte < 0x80 {
                byte as char
            } else {
                table[(byte - 0x80) as usize]
            }
        })
        .collect()
}

fn decode_utf16(data: &[u8], little_endian: bool) -> Option<String> {
    if data.len() % 2 != 0 {
        return None;
    }
    let units: Vec<u16> = data
        .chunks_exact(2)
        .map(|pair| {
            if little_endian {
                u16::from_le_bytes([pair[0], pair[1]])
            } else {
                u16::from_be_bytes([pair[0], pair[1]])
            }
        })
        .collect();
    String::from_utf16(&units).ok()
}

/// Наскільки текст схожий на текст, а не на сміття.
///
/// Рахуємо частку літер, цифр, пробілів і звичайної пунктуації. Рамки
/// псевдографіки до них не належать навмисно: саме ними розсипається
/// кирилиця, прочитана не в тому кодуванні, і без цього koi8-u виглядав
/// би не гірше за cp1251.
fn plausibility(text: &str) -> f64 {
    let sample: Vec<char> = text.chars().take(4000).collect();
    if sample.is_empty() {
        return 0.0;
    }

    let good = sample
        .iter()
        .filter(|ch| {
            ch.is_alphanumeric()
                || ch.is_whitespace()
                || matches!(
                    **ch,
                    '.' | ',' | ';' | ':' | '!' | '?' | '-' | '–' | '—' | '(' | ')' | '[' | ']'
                        | '{' | '}' | '"' | '\'' | '«' | '»' | '“' | '”' | '‘' | '’' | '…' | '/'
                        | '\\' | '*' | '#' | '№' | '%' | '+' | '=' | '_' | '@' | '&' | '§'
                )
        })
        .count();

    good as f64 / sample.len() as f64
}

/// Читає файл, вгадуючи кодування.
///
/// Порядок той самий, що на macOS: позначка порядку байтів, тоді UTF-8,
/// тоді кирилиця за схожістю на текст.
pub fn read_text(data: &[u8]) -> Result<String, String> {
    if data.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8(data[3..].to_vec()).map_err(|e| e.to_string());
    }
    if data.starts_with(&[0xFF, 0xFE]) {
        if let Some(text) = decode_utf16(&data[2..], true) {
            return Ok(text);
        }
    }
    if data.starts_with(&[0xFE, 0xFF]) {
        if let Some(text) = decode_utf16(&data[2..], false) {
            return Ok(text);
        }
    }
    if let Ok(text) = std::str::from_utf8(data) {
        return Ok(text.to_string());
    }

    let latin1: String = data.iter().map(|&b| b as char).collect();
    let candidates = [
        decode_table(data, &CP1251),
        decode_table(data, &KOI8U),
        latin1,
    ];

    // Строго більше, а не «не менше»: за рівних оцінок перемагає те
    // кодування, що раніше в переліку. Кирилиця, прочитана трьома
    // способами, часто дає однакову оцінку, і без цього вигравав би
    // latin1 — останній у черзі й найменш імовірний.
    let mut best: Option<(String, f64)> = None;
    for text in candidates {
        let score = plausibility(&text);
        if best.as_ref().map_or(true, |(_, previous)| score > *previous) {
            best = Some((text, score));
        }
    }

    match best {
        Some((text, score)) if score > 0.9 => Ok(text),
        _ => Err("Не вдалося визначити кодування файлу. Спробуйте зберегти його в UTF-8.".into()),
    }
}

/// Ріже текст на розділи з абзаців.
pub fn split_into_chapters(text: &str) -> Vec<Vec<String>> {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let paragraphs: Vec<String> = normalized
        .split('\n')
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect();

    if paragraphs.is_empty() {
        return vec![vec![String::new()]];
    }

    let mut chapters = Vec::new();
    let mut current = Vec::new();
    let mut size = 0usize;

    for paragraph in paragraphs {
        size += paragraph.chars().count();
        current.push(paragraph);
        if size >= CHARACTERS_PER_CHAPTER {
            chapters.push(std::mem::take(&mut current));
            size = 0;
        }
    }
    if !current.is_empty() {
        chapters.push(current);
    }
    chapters
}

/// Перетворює текстовий файл на EPUB.
pub fn convert(data: &[u8], title: &str) -> Result<Vec<u8>, String> {
    let text = read_text(data)?;

    let chapters: Vec<Chapter> = split_into_chapters(&text)
        .into_iter()
        .map(|paragraphs| Chapter {
            title: None,
            body: paragraphs
                .iter()
                .map(|line| format!("  <p>{}</p>", epub::escape(line)))
                .collect::<Vec<_>>()
                .join("\n"),
        })
        .collect();

    epub::build(
        &Metadata {
            title: title.to_string(),
            identifier: format!("chytach-txt-{}", crate::book_id(title)),
            ..Default::default()
        },
        &chapters,
        &[],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_читається_як_є() {
        let text = read_text("Привіт, світе".as_bytes()).unwrap();
        assert_eq!(text, "Привіт, світе");
    }

    #[test]
    fn позначка_порядку_байтів_знімається() {
        let mut data = vec![0xEF, 0xBB, 0xBF];
        data.extend_from_slice("Текст".as_bytes());
        assert_eq!(read_text(&data).unwrap(), "Текст");
    }

    #[test]
    fn cp1251_вгадується() {
        // «Привіт» у cp1251.
        let data = [0xCF, 0xF0, 0xE8, 0xE2, 0xB3, 0xF2];
        assert_eq!(read_text(&data).unwrap(), "Привіт");
    }

    #[test]
    fn koi8u_вгадується() {
        // «Привіт» у koi8-u.
        let data = [0xF0, 0xD2, 0xC9, 0xD7, 0xA6, 0xD4];
        assert_eq!(read_text(&data).unwrap(), "Привіт");
    }

    #[test]
    fn utf16_з_позначкою_читається() {
        let mut data = vec![0xFF, 0xFE];
        for unit in "Текст".encode_utf16() {
            data.extend_from_slice(&unit.to_le_bytes());
        }
        assert_eq!(read_text(&data).unwrap(), "Текст");
    }

    #[test]
    fn порожні_рядки_не_стають_абзацами() {
        let chapters = split_into_chapters("перший\n\n\nдругий\n");
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0], vec!["перший", "другий"]);
    }

    #[test]
    fn довгий_текст_ріжеться_на_розділи() {
        let paragraph = "а".repeat(1000);
        let text = vec![paragraph.as_str(); 200].join("\n");
        let chapters = split_into_chapters(&text);
        assert!(chapters.len() >= 3, "розділів: {}", chapters.len());
    }

    #[test]
    fn збирається_відкривний_epub() {
        let book = convert("Перший абзац\nДругий абзац".as_bytes(), "Проба").unwrap();
        let unpacked = crate::unpack(book).unwrap();
        assert!(unpacked.entries.contains_key("META-INF/container.xml"));
        assert!(unpacked.entries.contains_key("EPUB/package.opf"));
        assert!(unpacked.entries.contains_key("EPUB/chapter1.xhtml"));

        let chapter = String::from_utf8_lossy(&unpacked.entries["EPUB/chapter1.xhtml"]);
        assert!(chapter.contains("<p>Перший абзац</p>"));
    }
}
