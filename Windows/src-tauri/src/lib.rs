// Оболонка Windows-версії.
//
// Уся читалка — текст, розкладка, оформлення — живе у вебвʼю на тому самому
// TypeScript, що й у розробці. Rust робить рівно одне: тримає розпакований
// архів книги й віддає з нього файли на запити вебвʼю. Потрібно це тому, що
// Readium ставить документу `<base>` на справжню адресу, і картинки, стилі
// та шрифти всередині розділу вантажаться звичайним запитом, а не через
// наш фетчер.

use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::sync::Mutex;

use tauri::http::{Request, Response, StatusCode};
use tauri::{Manager, State};
use tauri_plugin_dialog::DialogExt;

/// Розпакована книга: шлях усередині архіву → байти.
#[derive(Default)]
struct OpenBook {
    raw: Vec<u8>,
    entries: HashMap<String, Vec<u8>>,
}

#[derive(Default)]
struct BookState(Mutex<OpenBook>);

fn unpack(raw: Vec<u8>) -> Result<OpenBook, String> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(raw.clone())).map_err(|e| e.to_string())?;

    let mut entries = HashMap::new();
    for index in 0..archive.len() {
        let mut file = archive.by_index(index).map_err(|e| e.to_string())?;
        if file.is_dir() {
            continue;
        }
        // `name` з архіву може містити `..`; беремо нормалізований шлях,
        // який дає сам zip, інакше книга могла б адресувати будь-що.
        let Some(path) = file.enclosed_name() else {
            continue;
        };
        let path = path.to_string_lossy().replace('\\', "/");

        let mut bytes = Vec::with_capacity(file.size() as usize);
        file.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        entries.insert(path, bytes);
    }

    Ok(OpenBook { raw, entries })
}

/// Відкриває книгу з диска й лишає її розпакованою для схеми `epub`.
///
/// Навмисно не команда. Шлях до файлу не має приходити з вебвʼю: розділи
/// книги малюються в iframe, якому Readium дає і скрипти, і спільне
/// походження, тож код із книги дотягується до мосту Tauri. Якби команда
/// брала шлях, книга попросила б прочитати чужий файл і забрала б його
/// через схему `epub`. Тому шлях приходить лише звідти, де його обрала
/// людина: з рідного діалогу, з аргументів запуску або з власної памʼяті
/// застосунку.
fn load_book(path: &str, state: &BookState) -> Result<(), String> {
    let raw = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    let book = unpack(raw)?;
    log::info!(
        "відкрито {path}: {} байтів, {} файлів",
        book.raw.len(),
        book.entries.len()
    );
    *state.0.lock().map_err(|e| e.to_string())? = book;
    Ok(())
}

/// Шлях до файлу, у якому памʼятаємо останню книгу.
fn memory_path(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    let dir = app.path().app_data_dir().ok()?;
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("last-book.txt"))
}

fn remember(app: &tauri::AppHandle, path: &str) {
    if let Some(file) = memory_path(app) {
        let _ = std::fs::write(file, path);
    }
}

fn forget(app: &tauri::AppHandle) {
    if let Some(file) = memory_path(app) {
        let _ = std::fs::remove_file(file);
    }
}

/// Відкриває книгу, яку людина обрала в рідному діалозі.
#[tauri::command]
fn pick_book(app: tauri::AppHandle, state: State<'_, BookState>) -> Result<Option<String>, String> {
    let Some(picked) = app
        .dialog()
        .file()
        .add_filter("Книги", &["epub"])
        .blocking_pick_file()
    else {
        return Ok(None);
    };

    let path = picked
        .into_path()
        .map_err(|e| e.to_string())?
        .to_string_lossy()
        .into_owned();

    load_book(&path, &state)?;
    remember(&app, &path);
    Ok(Some(path))
}

/// Відкриває книгу, з якою застосунок запустили.
#[tauri::command]
fn open_startup_book(
    app: tauri::AppHandle,
    state: State<'_, BookState>,
) -> Result<Option<String>, String> {
    let Some(path) = book_from_args(std::env::args_os().map(|a| a.to_string_lossy().into_owned()))
    else {
        return Ok(None);
    };
    load_book(&path, &state)?;
    remember(&app, &path);
    Ok(Some(path))
}

/// Відкриває книгу, на якій зупинилися минулого разу.
#[tauri::command]
fn open_last_book(
    app: tauri::AppHandle,
    state: State<'_, BookState>,
) -> Result<Option<String>, String> {
    let Some(file) = memory_path(&app) else {
        return Ok(None);
    };
    let Ok(path) = std::fs::read_to_string(&file) else {
        return Ok(None);
    };
    if path == SAMPLE {
        open_sample(app, state)?;
        return Ok(Some(SAMPLE.to_string()));
    }
    // Книга могла переїхати або зникнути — тоді просто забуваємо її.
    if load_book(&path, &state).is_err() {
        forget(&app);
        return Ok(None);
    }
    Ok(Some(path))
}

/// Походження сторінки застосунку. На Windows вебвʼю працює за
/// `http://tauri.localhost`, на інших системах — за власною схемою.
#[cfg(windows)]
const APP_ORIGIN: &str = "http://tauri.localhost";
#[cfg(not(windows))]
const APP_ORIGIN: &str = "tauri://localhost";

/// Умовний шлях вкладеного зразка: справжній залежить від того, куди
/// встановлено застосунок, а памʼять має пережити оновлення.
const SAMPLE: &str = "__sample__";

/// Книга, з якою застосунок запустили.
///
/// Так Windows передає файл, на якому клацнули в Провіднику, або вибраний
/// через «Відкрити за допомогою»: шлях приходить аргументом командного
/// рядка. Перший аргумент — сам застосунок, тому беремо наступний, і то
/// лише якщо це справді наявний файл.
/// Шлях до книги серед аргументів командного рядка.
///
/// `args_os`, а не `args`: останній панікує на аргументі, який не є
/// правильним Unicode, і застосунок падав би просто на запуску — а на
/// Windows шляхи приходять із UTF-16, де таке трапляється.
fn book_from_args(args: impl Iterator<Item = String>) -> Option<String> {
    args.skip(1)
        .find(|arg| !arg.starts_with('-') && std::path::Path::new(arg).is_file())
}

/// Відкриває зразок книги, вкладений у збірку.
#[tauri::command]
fn open_sample(app: tauri::AppHandle, state: State<'_, BookState>) -> Result<(), String> {
    let path = app
        .path()
        .resolve("sample.epub", tauri::path::BaseDirectory::Resource)
        .map_err(|e| e.to_string())?;
    load_book(&path.to_string_lossy(), &state)?;
    remember(&app, SAMPLE);
    Ok(())
}

fn guess_type(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("").to_ascii_lowercase().as_str() {
        "xhtml" => "application/xhtml+xml",
        "html" | "htm" => "text/html",
        "css" => "text/css",
        "js" => "text/javascript",
        "xml" => "application/xml",
        "ncx" => "application/x-dtbncx+xml",
        "opf" => "application/oebps-package+xml",
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "epub" => "application/epub+zip",
        _ => "application/octet-stream",
    }
}

/// Віддає файл із відкритої книги.
///
/// Особливий шлях `__raw__` повертає архів цілком: його розбирає вже
/// сторона TypeScript, яка будує маніфест і читає розділи.
fn serve(state: &BookState, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
    let uri = request.uri();
    let path = percent_decode(uri.path().trim_start_matches('/'));

    let not_found = || {
        Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header("Content-Type", "text/plain; charset=utf-8")
            .body({
                log::warn!("не знайдено: {path}");
                format!("У книзі немає {path}").into_bytes()
            })
            .unwrap()
    };

    let Ok(book) = state.0.lock() else {
        return not_found();
    };

    log::info!("запит: {path}");

    let (bytes, mime) = if path == "__raw__" {
        (book.raw.clone(), "application/epub+zip")
    } else {
        match book.entries.get(&path) {
            Some(bytes) => (bytes.clone(), guess_type(&path)),
            None => return not_found(),
        }
    };

    Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", mime)
        // Вебвʼю звертається з іншого походження, ніж схема книги, тож
        // без цього заголовка запит не пройшов би. Зірочки тут немає
        // навмисно: дозволяємо рівно ті походження, під якими працює сам
        // застосунок, і нічого більше.
        .header("Access-Control-Allow-Origin", APP_ORIGIN)
        .header("Cache-Control", "no-store")
        .body(bytes)
        .unwrap()
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&value[index + 1..index + 3], 16) {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();

    // Друга книга, відкрита з Провідника, поки застосунок уже працює,
    // запустила б на Windows ще одне вікно. Замість цього передаємо шлях
    // у вже відкрите — так само, як Android передає новий намір.
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
        let Some(path) = book_from_args(args.into_iter()) else {
            return;
        };
        let state = app.state::<BookState>();
        if load_book(&path, &state).is_ok() {
            remember(app, &path);
            use tauri::Emitter;
            let _ = app.emit("book-opened", path);
        }
    }));

    builder
        .plugin(tauri_plugin_log::Builder::default().build())
        .plugin(tauri_plugin_dialog::init())
        .manage(BookState::default())
        .register_uri_scheme_protocol("epub", |context, request| {
            let state = context.app_handle().state::<BookState>();
            serve(&state, request)
        })
        .invoke_handler(tauri::generate_handler![pick_book, open_sample, open_startup_book, open_last_book])
        .run(tauri::generate_context!())
        .expect("не вдалося запустити застосунок");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> OpenBook {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../public/sample.epub");
        unpack(std::fs::read(path).expect("зразок книги на місці")).expect("книга розпакувалася")
    }

    #[test]
    fn архів_розпаковується_із_обовʼязковими_файлами() {
        let book = sample();
        assert!(book.entries.contains_key("META-INF/container.xml"));
        assert!(book.entries.contains_key("mimetype"));
        assert!(book.raw.len() > 0);
    }

    #[test]
    fn mimetype_читається_як_належить() {
        let book = sample();
        let bytes = book.entries.get("mimetype").unwrap();
        assert_eq!(String::from_utf8_lossy(bytes), "application/epub+zip");
    }

    #[test]
    fn типи_вмісту_визначаються_за_розширенням() {
        assert_eq!(guess_type("EPUB/text/ch1.xhtml"), "application/xhtml+xml");
        assert_eq!(guess_type("EPUB/css/main.css"), "text/css");
        assert_eq!(guess_type("EPUB/images/cover.JPG"), "image/jpeg");
        assert_eq!(guess_type("щось-невідоме"), "application/octet-stream");
    }

    #[test]
    fn відсотковий_запис_розкодовується() {
        assert_eq!(percent_decode("EPUB/text/%D1%80%D0%BE%D0%B7%D0%B4%D1%96%D0%BB.xhtml"),
                   "EPUB/text/розділ.xhtml");
        assert_eq!(percent_decode("EPUB/a%20b.css"), "EPUB/a b.css");
    }

    #[test]
    fn шляхи_з_виходом_за_межі_архіву_відкидаються() {
        // `enclosed_name` повертає None на таких записах, тож у перелік
        // вони не потрапляють і прочитати чужий файл книга не може.
        let book = sample();
        assert!(book.entries.keys().all(|path| !path.contains("..")));
    }
}
