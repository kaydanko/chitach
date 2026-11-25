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
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.util.DirectionalNavigationAdapter
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Publication
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

        val url = book.toAbsoluteUrl()
        if (url == null) {
            showError(getString(R.string.open_failed), book)
            return
        }

        lifecycleScope.launch {
            val app = application as ChytachApplication
            app.bookOpener.open(url)
                .onSuccess { opened ->
                    publication?.close()
                    publication = opened
                    currentBook = book
                    library.lastBook = book
                    hideStartPanel()
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

            if (top != BookAppearance.safeTopInset || bottom != BookAppearance.safeBottomInset) {
                BookAppearance.safeTopInset = top
                BookAppearance.safeBottomInset = bottom
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
