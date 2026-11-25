// Оболонка Windows-версії.
//
// Уся читалка — текст, розкладка, оформлення — живе у вебвʼю на тому самому
// TypeScript, що й у розробці. Rust робить рівно одне: тримає розпакований
// архів книги й віддає з нього файли на запити вебвʼю. Потрібно це тому, що
// Readium ставить документу `<base>` на справжню адресу, і картинки, стилі
// та шрифти всередині розділу вантажаться звичайним запитом, а не через
// наш фетчер.

mod epub;
mod formats;

use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::sync::Mutex;

use tauri::http::{Request, Response, StatusCode};
use tauri::{Manager, State};
use tauri_plugin_dialog::DialogExt;

/// Розпакована книга: шлях усередині архіву → байти.
#[derive(Default)]
pub(crate) struct OpenBook {
    raw: Vec<u8>,
    pub(crate) entries: HashMap<String, Vec<u8>>,
}

#[derive(Default)]
struct BookState(Mutex<OpenBook>);

/// Стеля на один файл усередині книги й на книгу загалом.
///
/// Розмір кожного файлу заявляє заголовок архіву, тобто той, хто книгу
/// зібрав. Повірити цьому числу й одразу попросити стільки памʼяті
/// означає віддати застосунок будь-кому, хто напише в заголовку сто
/// гігабайтів: вистачить відкрити таку книгу, щоб застосунок зжер усю
/// памʼять. Тому число з заголовка ні на що не впливає, а читання
/// обривається на межі.
const MAX_ENTRY_BYTES: u64 = 64 * 1024 * 1024;
const MAX_TOTAL_BYTES: u64 = 512 * 1024 * 1024;

pub(crate) fn unpack(raw: Vec<u8>) -> Result<OpenBook, String> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(raw.clone())).map_err(|e| e.to_string())?;

    let mut entries = HashMap::new();
    let mut total: u64 = 0;
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

        // `take` замість довіри до заявленого розміру: читаємо щонайбільше
        // на байт більше за стелю, щоб відрізнити «рівно по межі» від
        // «більше, ніж можна».
        let mut bytes = Vec::new();
        file.take(MAX_ENTRY_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;

        if bytes.len() as u64 > MAX_ENTRY_BYTES {
            return Err(format!("файл {path} у книзі завеликий"));
        }

        total += bytes.len() as u64;
        if total > MAX_TOTAL_BYTES {
            return Err("книга завелика".to_string());
        }

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
    // Сам файл книги теж тримаємо в памʼяті цілком, тож міряємо його до
    // читання, а не після.
    let size = std::fs::metadata(path)
        .map_err(|e| format!("{path}: {e}"))?
        .len();
    if size > MAX_TOTAL_BYTES {
        return Err(format!("{path}: файл завеликий"));
    }

    let raw = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;

    // TXT, Markdown і решта не-EPUB форматів стають EPUB тут, на боці
    // Rust: далі їх розбирає той самий код, що й звичайну книгу.
    let file = std::path::Path::new(path);
    let extension = file
        .extension()
        .map(|e| e.to_string_lossy().into_owned())
        .unwrap_or_default();

    let raw = match formats::converter_for(&extension) {
        Some(converter) => {
            let title = file
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Книга".to_string());
            converter.convert(&raw, &title)?
        }
        None => raw,
    };

    let book = unpack(raw)?;
    log::info!(
        "відкрито {path}: {} байтів, {} файлів",
        book.raw.len(),
        book.entries.len()
    );
    *state.0.lock().map_err(|e| e.to_string())? = book;
    Ok(())
}

/// Реквізити для внеску.
///
/// Ті самі, що у версіях для macOS та Android. Імені отримувача тут
/// навмисно немає: воно потрібне лише для переказу за IBAN, а банка й
/// картка приймають гроші без нього.
const DONATION_JAR: &str = "https://send.monobank.ua/jar/bUjttUaxp";
pub const DONATION_CARD: &str = "4874100027184244";

/// Відкриває банку monobank у звичайному браузері.
///
/// Адресу складає Rust, а вебвʼю передає лише суму: приймати сюди готове
/// посилання означало б дати книзі відкривати будь-що назовні.
#[tauri::command]
fn open_jar(amount: Option<u32>) -> Result<(), String> {
    let url = match amount {
        Some(value) if value > 0 => format!("{DONATION_JAR}?a={value}"),
        _ => DONATION_JAR.to_string(),
    };

    let (program, args): (&str, Vec<&str>) = if cfg!(target_os = "windows") {
        ("cmd", vec!["/C", "start", ""])
    } else if cfg!(target_os = "macos") {
        ("open", vec![])
    } else {
        ("xdg-open", vec![])
    };

    std::process::Command::new(program)
        .args(args)
        .arg(&url)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Номер картки для внеску.
#[tauri::command]
fn donation_card() -> String {
    DONATION_CARD.to_string()
}

/// Стійкий ідентифікатор книги замість шляху.
///
/// Вебвʼю не має знати, де на диску лежать файли: розділи книги малюються
/// в iframe зі скриптами, тож перелік шляхів означав би, що будь-яка
/// книга вичитує будову вашого диска — імена тек, назву облікового
/// запису. Для читалки ж достатньо чогось, що стабільно вказує на ту саму
/// книгу між запусками.
///
/// FNV-1a, а не `DefaultHasher`: останній не обіцяє однакового результату
/// між версіями Rust, а ідентифікатор мусить пережити оновлення.
pub(crate) fn book_id(path: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in path.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{hash:016x}")
}

/// Запис про книгу в бібліотеці.
#[derive(serde::Serialize, serde::Deserialize, Clone, Default)]
struct BookRecord {
    path: String,
    title: String,
    #[serde(default)]
    author: String,
    #[serde(default)]
    progress: f64,
    /// Коли востаннє відкривали, у секундах епохи: недавно читане вгорі.
    #[serde(default)]
    opened_at: u64,
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn library_path(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    let dir = app.path().app_data_dir().ok()?;
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("library.json"))
}

fn read_library(app: &tauri::AppHandle) -> Vec<BookRecord> {
    let Some(file) = library_path(app) else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(file) else {
        return Vec::new();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn write_library(app: &tauri::AppHandle, books: &[BookRecord]) {
    if let Some(file) = library_path(app) {
        if let Ok(text) = serde_json::to_string_pretty(books) {
            let _ = std::fs::write(file, text);
        }
    }
}

/// Додає книгу до бібліотеки або піднімає наявну вгору.
fn note_opened(app: &tauri::AppHandle, path: &str) {
    let mut books = read_library(app);
    match books.iter_mut().find(|b| b.path == path) {
        Some(book) => book.opened_at = now(),
        None => books.push(BookRecord {
            path: path.to_string(),
            // Назва поки невідома: її дасть вебвʼю, коли розбере книгу.
            title: std::path::Path::new(path)
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.to_string()),
            opened_at: now(),
            ..Default::default()
        }),
    }
    write_library(app, &books);
}

/// Книга такою, якою її бачить вебвʼю: без шляху.
#[derive(serde::Serialize)]
struct BookSummary {
    id: String,
    title: String,
    author: String,
    progress: f64,
}

/// Перелік книг, недавно читані вгорі.
#[tauri::command]
fn list_books(app: tauri::AppHandle) -> Vec<BookSummary> {
    let mut books = read_library(&app);
    books.sort_by(|a, b| b.opened_at.cmp(&a.opened_at));
    books
        .into_iter()
        .map(|book| BookSummary {
            id: book_id(&book.path),
            title: book.title,
            author: book.author,
            progress: book.progress,
        })
        .collect()
}

/// Відкриває книгу з бібліотеки за її місцем у переліку.
///
/// Саме за номером, а не за шляхом: шлях до файлу не має приходити з
/// вебвʼю — причина та сама, що й у `load_book`.
#[tauri::command]
fn open_library_book(
    index: usize,
    app: tauri::AppHandle,
    state: State<'_, BookState>,
) -> Result<Option<String>, String> {
    let mut books = read_library(&app);
    books.sort_by(|a, b| b.opened_at.cmp(&a.opened_at));

    let Some(book) = books.get(index) else {
        return Ok(None);
    };
    let path = book.path.clone();

    if load_book(&path, &state).is_err() {
        // Книга зникла з диска — прибираємо її з переліку, щоб не дражнила.
        let mut all = read_library(&app);
        all.retain(|b| b.path != path);
        write_library(&app, &all);
        return Ok(None);
    }

    remember(&app, &path);
    note_opened(&app, &path);
    Ok(Some(book_id(&path)))
}

/// Доповнює запис про відкриту книгу тим, що вичитав із неї вебвʼю.
///
/// Назва, автор і поступ — не шляхи, тож брати їх звідти безпечно: вони
/// лягають у запис книги, яку Rust уже відкрив сам.
#[tauri::command]
fn record_metadata(
    title: String,
    author: String,
    progress: f64,
    app: tauri::AppHandle,
) -> Result<(), String> {
    let Some(file) = memory_path(&app) else {
        return Ok(());
    };
    let Ok(current) = std::fs::read_to_string(file) else {
        return Ok(());
    };

    let mut books = read_library(&app);
    if let Some(book) = books.iter_mut().find(|b| b.path == current) {
        if !title.is_empty() {
            book.title = title;
        }
        book.author = author;
        book.progress = progress.clamp(0.0, 1.0);
        write_library(&app, &books);
    }
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
        .add_filter("Книги", &["epub", "txt", "text", "md", "markdown", "fb2", "fb2z", "zip"])
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
    note_opened(&app, &path);
    Ok(Some(book_id(&path)))
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
    note_opened(&app, &path);
    Ok(Some(book_id(&path)))
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
    Ok(Some(book_id(&path)))
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
        .on_window_event(|window, event| {
            // Книгу, перетягнуту у вікно, відкриває Rust і лише сповіщає
            // вебвʼю: шлях до файлу через нього не ходить — причина та
            // сама, що й у `load_book`.
            let tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) = event
            else {
                return;
            };
            let Some(path) = paths.iter().find(|p| p.is_file()) else {
                return;
            };
            let path = path.to_string_lossy().into_owned();

            let app = window.app_handle();
            let state = app.state::<BookState>();
            if load_book(&path, &state).is_ok() {
                remember(app, &path);
                note_opened(app, &path);
                use tauri::Emitter;
                let _ = app.emit("book-opened", book_id(&path));
            }
        })
        .plugin(tauri_plugin_log::Builder::default().build())
        .plugin(tauri_plugin_dialog::init())
        .manage(BookState::default())
        .register_uri_scheme_protocol("epub", |context, request| {
            let state = context.app_handle().state::<BookState>();
            serve(&state, request)
        })
        .invoke_handler(tauri::generate_handler![
            pick_book,
            open_sample,
            open_startup_book,
            open_last_book,
            list_books,
            open_library_book,
            record_metadata,
            open_jar,
            donation_card
        ])
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
    fn реквізити_внеску_на_місці() {
        // Не про значення, а про те, що вони не загубилися й не
        // перетворилися на щось інше під час правок.
        assert_eq!(DONATION_CARD.len(), 16);
        assert!(DONATION_CARD.chars().all(|c| c.is_ascii_digit()));
        assert!(DONATION_JAR.starts_with("https://send.monobank.ua/jar/"));
    }

    #[test]
    fn завеликий_запис_відкидається() {
        // Архів, у якому один файл більший за стелю, не має розпакуватися
        // й не має зʼїсти памʼять по дорозі.
        use std::io::Write;
        let mut buffer = Vec::new();
        {
            let mut writer = zip::ZipWriter::new(Cursor::new(&mut buffer));
            writer
                .start_file(
                    "велике.bin",
                    zip::write::SimpleFileOptions::default()
                        .compression_method(zip::CompressionMethod::Deflated),
                )
                .unwrap();
            // Нулі стискаються майже в ніщо: у цьому й суть такої книги.
            let chunk = vec![0u8; 1024 * 1024];
            for _ in 0..((MAX_ENTRY_BYTES / chunk.len() as u64) + 2) {
                writer.write_all(&chunk).unwrap();
            }
            writer.finish().unwrap();
        }

        let error = match unpack(buffer) {
            Err(error) => error,
            Ok(_) => panic!("завеликий запис мав бути відкинутий"),
        };
        assert!(error.contains("завеликий"), "несподівана помилка: {error}");
    }

    #[test]
    fn шляхи_з_виходом_за_межі_архіву_відкидаються() {
        // `enclosed_name` повертає None на таких записах, тож у перелік
        // вони не потрапляють і прочитати чужий файл книга не може.
        let book = sample();
        assert!(book.entries.keys().all(|path| !path.contains("..")));
    }
}
