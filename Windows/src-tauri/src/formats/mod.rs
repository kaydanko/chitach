//! Конвертери форматів у EPUB.
//!
//! Усі вони віддають байти готового архіву, який далі розбирає той самий
//! код, що й звичайну книгу: окремого шляху для конвертованих форматів
//! немає й не потрібно.

pub mod fb2;
pub mod text;

/// Чи вміємо ми перетворити цей файл на EPUB.
pub fn converter_for(extension: &str) -> Option<Converter> {
    let extension = extension.to_ascii_lowercase();
    if text::EXTENSIONS.contains(&extension.as_str()) {
        return Some(Converter::Text);
    }
    if fb2::EXTENSIONS.contains(&extension.as_str()) {
        return Some(Converter::Fb2);
    }
    if fb2::ZIP_EXTENSIONS.contains(&extension.as_str()) {
        return Some(Converter::Fb2Zip);
    }
    None
}

pub enum Converter {
    Text,
    Fb2,
    Fb2Zip,
}

impl Converter {
    pub fn convert(&self, data: &[u8], title: &str) -> Result<Vec<u8>, String> {
        match self {
            Converter::Text => text::convert(data, title),
            Converter::Fb2 => fb2::convert(data, title),
            Converter::Fb2Zip => fb2::convert_zip(data, title),
        }
    }
}
