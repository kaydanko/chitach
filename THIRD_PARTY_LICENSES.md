# Сторонні компоненти

Станом на 2026-11-19. Джерело версій — `Chytach.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Тексти ліцензій перевірені у вихідниках, не за назвами пакетів.

**Висновок аудиту: GPL / LGPL / AGPL у графі немає.** Усі ліцензії сумісні
із закритим застосунком у App Store.

| Пакет | Версія | Ліцензія | Лінкується в бінарник |
|---|---|---|---|
| [readium/swift-toolkit](https://github.com/readium/swift-toolkit) | 3.11.0 | BSD 3-Clause | так |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | 2.13.7 | MIT | так |
| [Zip](https://github.com/marmelroy/Zip) | 2.1.2 | MIT | так |
| [readium/ZIPFoundation](https://github.com/readium/ZIPFoundation) | 3.0.1 | MIT | так |
| [readium/Fuzi](https://github.com/readium/Fuzi) | 4.0.0 | MIT | так |
| [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) | 1.10.0 | zlib-подібна, **з обов'язковою згадкою** | так |
| [DifferenceKit](https://github.com/ra1028/DifferenceKit) | 1.3.0 | Apache 2.0 | так |
| [SQLite.swift](https://github.com/stephencelis/SQLite.swift) | 0.16.0 | MIT | ні¹ |
| [readium/GCDWebServer](https://github.com/readium/GCDWebServer) | 4.0.1 | BSD 3-Clause | ні² |

¹ Потрібен лише продукту `ReadiumAdapterLCPSQLite`, якого ми не підключаємо.
  З'явиться, якщо дійдемо до LCP (Фаза 7).
² Потрібен лише продукту `ReadiumAdapterGCDWebServer`, який **deprecated** з
  Readium 3.9.0 і нами не підключається. SPM тягне його в граф резолюції, але
  в бінарник він не потрапляє.

## Зобов'язання, які треба виконати

### 1. CryptoSwift — обов'язкова згадка ⚠️

Ліцензія прямо вимагає: *«If you use this software in a product, an
acknowledgment in the product documentation is required»* і
*«Redistributions of any form whatsoever must retain the following
acknowledgment»*.

Це не формальність і не «за бажанням». Екран **Про програму → Ліцензії**
(Фаза 1) **мусить** містити рядок подяки Marcin Krzyżanowski із посиланням на
krzyzanowskim.com. Без нього поширення порушує ліцензію.

### 2. DifferenceKit — Apache 2.0

Потребує збереження тексту ліцензії та позначення змін, якщо ми щось міняємо.
Ми не міняємо — достатньо включити текст ліцензії.

### 3. BSD 3-Clause (Readium, GCDWebServer)

Зберегти копірайт і текст ліцензії в документації. Не використовувати імена
Readium Foundation чи авторів для просування продукту без дозволу.

### 4. MIT (SwiftSoup, Zip, ZIPFoundation, Fuzi, SQLite.swift)

Зберегти копірайт і текст ліцензії.

## Що це означає для застосунку

У розділі `INFORMATION` налаштувань (Фаза 1) має бути пункт **Ліцензії** з
повними текстами всіх ліцензій вище. Це закриває вимоги BSD, MIT, Apache 2.0
і обов'язкову згадку CryptoSwift одночасно.

Екран не можна відкладати «на потім перед релізом»: він передбачений
структурою Settings, скопійованою з оригіналу, і коштує небагато.

## Окремо: референсні матеріали

`Reference/fbreader-appstore/` містить скриншоти зі сторінки FBReader в
App Store. Вони **не є** частиною продукту, не потрапляють у бінарник і
виключені з git (`.gitignore`). Див. `Reference/README.md`.

## Як оновити цей файл

Після будь-якої зміни залежностей:

```bash
./Scripts/audit-licenses.sh
```
