package com.kabuki.chytach.reader

import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Shader
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.LayerDrawable
import android.net.Uri
import android.os.Bundle
import android.util.DisplayMetrics
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.SeekBar
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.IntentCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.updateLayoutParams
import androidx.fragment.app.commitNow
import androidx.lifecycle.lifecycleScope
import com.kabuki.chytach.ChytachApplication
import com.kabuki.chytach.R
import com.kabuki.chytach.library.BookLibrary
import com.kabuki.chytach.library.BookRecord
import com.kabuki.chytach.support.DonationSheet
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.util.DirectionalNavigationAdapter
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.positions
import org.readium.r2.shared.util.toAbsoluteUrl

/**
 * Екран читання.
 *
 * Навігатор Readium тут — фрагмент, а не Compose: саме ця реалізація має
 * `pageMargins`, `RsProperties` і `evaluateJavascript`, тобто все, на чому
 * тримається наше оформлення. Новіший Compose-навігатор натомість рахує
 * поля з довжини рядка й хука для власного CSS не дає.
 */
@OptIn(ExperimentalReadiumApi::class)
class ReaderActivity : AppCompatActivity() {

    private lateinit var library: BookLibrary

    private var navigator: EpubNavigatorFragment? = null
    private var publication: Publication? = null
    private var currentBook: Uri? = null
    private var twoColumns: Boolean = false

    /** Позиції книги — ними ходить повзунок поступу. */
    private var positions: List<org.readium.r2.shared.publication.Locator> = emptyList()

    /**
     * Вибір книги з файлів.
     *
     * Тип фільтра навмисно найширший. Чимало провайдерів віддають EPUB як
     * потік байтів або взагалі без типу, і суворіший перелік робив би
     * частину книг недоступними — сірими в переліку, без пояснення чому.
     * Краще дати відкрити будь-що й сказати словами, коли це не книга.
     */
    private val pickBook =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri == null) return@registerForActivityResult
            keepAccess(uri)
            openBook(uri)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Фабрику фрагментів треба підставити до `super.onCreate`: Android
        // відновлює фрагменти вже там, а наша книга відкривається
        // асинхронно. Readium тримає заглушку саме для цього випадку.
        supportFragmentManager.fragmentFactory = EpubNavigatorFragment.createDummyFactory()
        super.onCreate(savedInstanceState)

        library = BookLibrary(this)
        library.loadAppearance()

        setContentView(R.layout.activity_reader)
        hideSystemBars()
        drawBehindCutout()
        observeCutoutInsets()
        installGrainBackdrop()

        findViewById<Button>(R.id.open_book).setOnClickListener {
            pickBook.launch(arrayOf("*/*"))
        }
        findViewById<Button>(R.id.open_sample).setOnClickListener {
            openSample()
        }

        wireChrome()

        val book = bookFromIntent(intent) ?: library.lastBook
        if (book != null) openBook(book) else showStartPanel()
    }

    /** Книга, надіслана з іншого застосунку, поки Chytach уже працює. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        bookFromIntent(intent)?.let { openBook(it) }
    }

    override fun onDestroy() {
        super.onDestroy()
        publication?.close()
    }

    // MARK: — Хром

    /**
     * Шапка, підвал і панелі.
     *
     * Порядок кнопок той самий, що у Swift-версії: закрити книгу,
     * бібліотека, відкрити файл, зміст — ліворуч, оформлення — праворуч.
     */
    private fun wireChrome() {
        findViewById<ImageButton>(R.id.tool_close).setOnClickListener { closeBook() }
        findViewById<ImageButton>(R.id.tool_open).setOnClickListener {
            pickBook.launch(arrayOf("*/*"))
        }
        findViewById<ImageButton>(R.id.tool_library).setOnClickListener { showLibrary() }
        findViewById<ImageButton>(R.id.tool_contents).setOnClickListener { showContents() }
        findViewById<ImageButton>(R.id.tool_support).setOnClickListener {
            DonationSheet.show(this, hasOpenBook = publication != null)
        }
        findViewById<ImageButton>(R.id.tool_appearance).setOnClickListener { showAppearance() }

        findViewById<ImageButton>(R.id.jump_start).setOnClickListener { goToFraction(0.0) }
        findViewById<ImageButton>(R.id.jump_end).setOnClickListener { goToFraction(1.0) }

        findViewById<SeekBar>(R.id.progress).setOnSeekBarChangeListener(
            object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, value: Int, byUser: Boolean) {
                    if (byUser) goToFraction(value / 1000.0)
                }

                override fun onStartTrackingTouch(bar: SeekBar?) = Unit
                override fun onStopTrackingTouch(bar: SeekBar?) = Unit
            }
        )
    }

    private fun setChromeVisible(visible: Boolean) {
        val state = if (visible) View.VISIBLE else View.GONE
        findViewById<View>(R.id.toolbar).visibility = state
        findViewById<View>(R.id.footer).visibility = state
    }

    private fun showAppearance() {
        Sheets.appearance(this, library) { fast ->
            layoutNavigator()
            if (fast) {
                navigator?.submitPreferences(BookAppearance.preferences(twoColumns))
            } else {
                // Колір, зерно й поля живуть у вставленому стилі, а він
                // потрапляє в документ під час завантаження. Тому
                // просимо навігатор застосувати налаштування й одразу
                // перевставляємо стиль у поточний webview.
                navigator?.submitPreferences(BookAppearance.preferences(twoColumns))
                lifecycleScope.launch { applyAppearance() }
            }
            installGrainBackdrop()
        }.show()
    }

    private fun showContents() {
        val toc = publication?.tableOfContents ?: emptyList()
        Sheets.contents(
            this,
            Sheets.flattenContents(toc),
            navigator?.currentLocator?.value?.href?.toString(),
        ) { link ->
            navigator?.go(link, true)
        }.show()
    }

    private fun showLibrary() {
        Sheets.library(
            this,
            library.books(),
            currentBook,
            onPick = { record: BookRecord -> openBook(record.uri) },
            onAdd = { pickBook.launch(arrayOf("*/*")) },
        ).show()
    }

    private fun closeBook() {
        publication?.close()
        publication = null
        navigator = null
        currentBook = null
        positions = emptyList()

        supportFragmentManager.findFragmentByTag(NAVIGATOR_TAG)?.let { fragment ->
            supportFragmentManager.commitNow { remove(fragment) }
        }
        setChromeVisible(false)
        showStartPanel()
    }

    /** Повзунок ходить позиціями книги — тими самими, що рахує Readium. */
    private fun goToFraction(fraction: Double) {
        val all = positions
        if (all.isEmpty()) return
        val index = (fraction * (all.size - 1)).toInt().coerceIn(0, all.size - 1)
        navigator?.go(all[index], true)
    }

    private fun updateProgress(locator: org.readium.r2.shared.publication.Locator) {
        val fraction = locator.locations.totalProgression ?: 0.0
        findViewById<SeekBar>(R.id.progress).progress = (fraction * 1000).toInt()
        findViewById<TextView>(R.id.position_label).text = "${Math.round(fraction * 100)}%"
    }

    // MARK: — Звідки береться книга

    private fun bookFromIntent(intent: Intent): Uri? = when (intent.action) {
        Intent.ACTION_VIEW -> intent.data
        Intent.ACTION_SEND ->
            IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
        else -> null
    }?.also { keepAccess(it) }

    /**
     * Просить систему лишити доступ до книги назавжди.
     *
     * Без цього дозвіл живе до перезапуску застосунку, і книга, відкрита
     * вчора, сьогодні вже не відкрилася б. Дозвіл дають не всі джерела —
     * відмова тут не привід не відкрити книгу зараз.
     */
    private fun keepAccess(book: Uri) {
        runCatching {
            contentResolver.takePersistableUriPermission(
                book,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
    }

    private fun openSample() {
        val app = application as ChytachApplication
        openBook(Uri.parse(app.bookOpener.sampleBookUrl().toString()))
    }

    private fun openBook(book: Uri) {
        hideError()

        lifecycleScope.launch {
            val app = application as ChytachApplication
            app.bookOpener.open(book)
                .onSuccess { opened ->
                    publication?.close()
                    publication = opened
                    currentBook = book
                    library.lastBook = book
                    hideStartPanel()
                    library.noteOpened(book)
                    positions = runCatching { opened.positions() }
                        .getOrDefault(emptyList<org.readium.r2.shared.publication.Locator>())
                    setChromeVisible(true)
                    showNavigator(opened, book)
                }
                .onFailure { error ->
                    showError(error.message ?: getString(R.string.open_failed), book)
                }
        }
    }

    // MARK: — Відображення

    private fun showNavigator(publication: Publication, book: Uri) {
        twoColumns = BookAppearance.shouldUseTwoColumns(widthDp())
        layoutNavigator()

        val factory = EpubNavigatorFactory(publication)
            .createFragmentFactory(
                initialLocator = library.locator(book),
                initialPreferences = BookAppearance.preferences(twoColumns),
                configuration = EpubNavigatorFragment.Configuration {
                    readiumCssRsProperties = BookAppearance.rsProperties(twoColumns)
                    // Нуль: поле тексту має доходити до самого верху. Будь-який
                    // відступ ззовні лишає смугу, яку малює не документ, а шар
                    // під ним — саме вона на iOS роками читалася як дефект.
                    shouldApplyInsetsPadding = false
                },
            )

        supportFragmentManager.fragmentFactory = factory
        supportFragmentManager.commitNow {
            replace(R.id.navigator_container, EpubNavigatorFragment::class.java, null, NAVIGATOR_TAG)
        }

        val fragment = supportFragmentManager.findFragmentByTag(NAVIGATOR_TAG)
            as? EpubNavigatorFragment ?: return
        navigator = fragment

        // Гортання дотиком біля краю та клавішами — окремий адаптер, не
        // вбудована поведінка навігатора. Без нього сторінка не
        // перегортається взагалі: ні дотиком, ні стрілками.
        fragment.addInputListener(DirectionalNavigationAdapter(fragment))

        // Стиль доводиться вставляти після кожного завантаження ресурсу:
        // навігатор тримає окремий webview на кожен файл книги, і новий
        // приходить без нашого оформлення. Тут же запам'ятовуємо місце.
        fragment.currentLocator
            .onEach { locator ->
                applyAppearance()
                library.saveLocator(book, locator)
                updateProgress(locator)
                library.describe(
                    book,
                    publication.metadata.title.orEmpty(),
                    publication.metadata.authors.joinToString(", ") { it.name },
                    locator.locations.totalProgression ?: 0.0,
                )
            }
            .launchIn(lifecycleScope)
    }

    private suspend fun applyAppearance() {
        navigator?.evaluateJavascript(
            BookAppearance.styleInjectionScript(this, twoColumns)
        )
    }

    private fun showStartPanel() {
        findViewById<View>(R.id.start_panel).visibility = View.VISIBLE
    }

    private fun hideStartPanel() {
        findViewById<View>(R.id.start_panel).visibility = View.GONE
    }

    private fun hideError() {
        findViewById<TextView>(R.id.error_label).visibility = View.GONE
    }

    /**
     * Книга, яку не вдалося відкрити, більше не вважається останньою:
     * інакше застосунок відкривався б тією самою помилкою щоразу.
     */
    private fun showError(message: String, book: Uri) {
        library.forget(book)
        currentBook = null
        showStartPanel()

        findViewById<TextView>(R.id.error_label).apply {
            text = getString(R.string.open_failed) + "\n\n" + message
            visibility = View.VISIBLE
        }
    }

    // MARK: — Розкладка

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        val wide = BookAppearance.shouldUseTwoColumns(widthDp())
        if (wide != twoColumns) {
            twoColumns = wide
            navigator?.submitPreferences(BookAppearance.preferences(twoColumns))
        }
        layoutNavigator()
        lifecycleScope.launch { applyAppearance() }
    }

    /**
     * Бічні поля на розвороті робляться зсувом вебвʼю, а не полями
     * документа: усередині документа проміжок між колонками дорівнює сумі
     * бічних полів, і розчепити їх розкладкою неможливо. У смузі з краю
     * видно підкладку з зерном.
     */
    private fun layoutNavigator() {
        val view = BookAppearance.textInsets(twoColumns).view
        val density = resources.displayMetrics.density
        findViewById<View>(R.id.navigator_container).updateLayoutParams<FrameLayout.LayoutParams> {
            leftMargin = (view.left * density).toInt()
            rightMargin = (view.right * density).toInt()
        }
    }

    private fun widthDp(): Double =
        resources.displayMetrics.widthPixels / resources.displayMetrics.density.toDouble()

    /**
     * Підкладка: колір паперу, поверх нього плитка зерна.
     *
     * Шарами, а не `foreground`: фон із плиткою малюється незалежно від
     * гравітації переднього плану, який розтягує зображення замість
     * повторювати. Щільність бітмапа задаємо вручну — файл знятий під
     * подвійний масштаб, тож 256 пікселів мають лягати в 128 dp, як
     * `background-size: 128px` у документі.
     */
    private fun installGrainBackdrop() {
        val bitmap = runCatching {
            assets.open("grain.png").use { BitmapFactory.decodeStream(it) }
        }.getOrNull() ?: return

        bitmap.density = DisplayMetrics.DENSITY_DEFAULT * 2

        val paper = ColorDrawable(BookAppearance.argb(BookAppearance.paperColor))
        val grain = BitmapDrawable(resources, bitmap).apply {
            setTileModeXY(Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
        }

        findViewById<View>(R.id.grain_backdrop).background =
            LayerDrawable(arrayOf(paper, grain))
    }

    /**
     * Малюємо під вирізом екрана навмисно: інакше система лишила б там
     * чорну смугу замість паперу. Текст від вічка камери відсуває вже
     * оформлення — див. `observeCutoutInsets`.
     */
    private fun drawBehindCutout() {
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
    }

    /**
     * Висота вирізу відома лише під час розкладки й залежить від повороту,
     * тому читаємо її з вікна й одразу переливаємо в оформлення.
     */
    private fun observeCutoutInsets() {
        val root = findViewById<View>(R.id.reader_root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
            val density = resources.displayMetrics.density
            val top = (cutout.top / density).toDouble()
            val bottom = (cutout.bottom / density).toDouble()

            // Коли шапка видима, виріз перекриває вона, і відсувати текст
            // усередині документа вже не треба — інакше відступ подвоївся б.
            val chromeVisible = findViewById<View>(R.id.toolbar).visibility == View.VISIBLE
            findViewById<View>(R.id.toolbar).setPadding(
                0, if (chromeVisible) cutout.top else 0, 0, 0
            )
            findViewById<View>(R.id.footer).setPadding(
                0, 0, 0, if (chromeVisible) cutout.bottom else 0
            )

            val textTop = if (chromeVisible) 0.0 else top
            val textBottom = if (chromeVisible) 0.0 else bottom

            if (textTop != BookAppearance.safeTopInset ||
                textBottom != BookAppearance.safeBottomInset
            ) {
                BookAppearance.safeTopInset = textTop
                BookAppearance.safeBottomInset = textBottom
                lifecycleScope.launch { applyAppearance() }
            }
            insets
        }
    }

    /** Повноекранний режим: без годинника й заряду, як на iPhone та iPad. */
    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    private companion object {
        const val NAVIGATOR_TAG = "navigator"
    }
}
