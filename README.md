# Chytach

Читалка електронних книг для macOS, iPad і iPhone. Побудована на
[Readium Swift Toolkit](https://github.com/readium/swift-toolkit).

Розворот на дві сторінки, паперове тло з зерном, налаштовні кольори,
запамʼятовування місця читання.

## Стан

Ранній етап. Застосунок працює й ним можна читати щодня, але бібліотеки,
закладок і пошуку ще немає — одночасно відкрита одна книга.

**Працює і перевірено**

- EPUB
- TXT і Markdown — конвертуються в EPUB на льоту, з автовизначенням кодування
  (UTF-8, UTF-16, Windows-1251, KOI8-U)
- розворот на дві сторінки на широкому вікні, одна колонка на вузькому
- перенесення слів, виключка по ширині
- розмір тексту: `⌘+`, `⌘−`, або `⌘` з коліщатком миші
- кольори тла й тексту, шість готових тем
- місце читання зберігається для кожної книги окремо
- імпорт: `⌘O`, перетягування у вікно, «Відкрити за допомогою» з Finder

**Має працювати, але не перевірялося**

- PDF і CBZ — їх розбирає Readium, у застосунку окремо не тестувалися

**Ще немає**

- бібліотека, закладки, пошук у тексті, зміст
- FB2, RTF, MOBI, DOC
- синхронізація між пристроями
- DRM (Readium LCP)

## Встановлення на macOS

Завантажте `Chytach-macOS.zip` зі сторінки
[Releases](https://github.com/kaydanko/chitach/releases), розпакуйте й
перетягніть `Chytach.app` у теку «Програми».

**Перший запуск потребує однієї команди.** Застосунок підписаний ad-hoc і не
нотаризований в Apple, тому macOS ставить завантаженому файлу карантин і
відмовляється його відкривати з повідомленням на кшталт «пошкоджено».

Зніміть карантин:

```bash
xattr -dr com.apple.quarantine /Applications/Chytach.app
```

Після цього застосунок відкривається звичайним подвійним кліком. Повторювати
команду не треба — лише один раз після встановлення чи оновлення.

Потрібна macOS 14 або новіша. Бінарник універсальний: Apple Silicon та Intel.

## Збірка з джерел

Потрібні Xcode 16.4+ і [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
./Scripts/build.sh
```

Проєкт `.xcodeproj` не зберігається в репозиторії — він генерується з
`project.yml`. Версії залежностей зафіксовані в `Package.resolved`.

Збірка Mac-варіанта:

```bash
xcodebuild build -project Chytach.xcodeproj -scheme Chytach -destination 'platform=macOS,variant=Mac Catalyst' -configuration Release CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
```

Іконка й текстура паперу генеруються скриптами, а не зберігаються як готові
асети:

```bash
./Scripts/generate-app-icon.py
./Scripts/generate-paper-texture.py
```

## Ліцензія

Код застосунку — [MIT](LICENSE).

Повний перелік сторонніх компонентів і їхніх умов — у
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). GPL, LGPL чи AGPL у графі
залежностей немає.

Окремі подяки, яких вимагають умови використаних бібліотек:

- Readium Swift Toolkit © Readium Foundation, ліцензія BSD-3-Clause
- CryptoSwift — розробник Marcin Krzyżanowski, https://krzyzanowskim.com/
- DifferenceKit — ліцензія Apache 2.0
- SwiftSoup, Zip, ZIPFoundation, Fuzi, SQLite.swift — ліцензія MIT
