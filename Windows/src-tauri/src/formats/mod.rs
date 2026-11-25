//! Конвертери форматів у EPUB.
//!
//! Усі вони віддають байти готового архіву, який далі розбирає той самий
//! код, що й звичайну книгу: окремого шляху для конвертованих форматів
//! немає й не потрібно.

pub mod text;

/// Чи вміємо ми перетворити цей файл на EPUB.
pub fn converter_for(extension: &str) -> Option<Converter> {
    let extension = extension.to_ascii_lowercase();
    if text::EXTENSIONS.contains(&extension.as_str()) {
        return Some(Converter::Text);
    }
    None
}

pub enum Converter {
    Text,
}

impl Converter {
    pub fn convert(&self, data: &[u8], title: &str) -> Result<Vec<u8>, String> {
        match self {
            Converter::Text => text::convert(data, title),
        }
    }
}
