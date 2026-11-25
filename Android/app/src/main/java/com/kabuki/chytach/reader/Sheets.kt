package com.kabuki.chytach.reader

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.kabuki.chytach.R
import com.kabuki.chytach.library.BookLibrary
import com.kabuki.chytach.library.BookRecord
import org.readium.r2.shared.publication.Link

/**
 * Панелі читалки: оформлення, зміст, бібліотека.
 *
 * Зібрані кодом, а не з XML: кожна — це перелік однотипних рядків, і
 * розмітка вийшла б утричі довшою за те, що її будує.
 */
object Sheets {

    /** Запис змісту з рівнем вкладеності. */
    data class ContentsEntry(val link: Link, val title: String, val depth: Int)

    /** Розгортає дерево змісту в пласкій перелік із рівнями. */
    fun flattenContents(links: List<Link>, depth: Int = 0): List<ContentsEntry> =
        links.flatMap { link ->
            listOf(ContentsEntry(link, link.title.orEmpty(), depth)) +
                flattenContents(link.children, depth + 1)
        }

    // MARK: — Оформлення

    /**
     * @param onChange `fast` — чи досить навігатору нових налаштувань без
     *   перебудови. Кегль міняється часто, і перемальовувати книгу на
     *   кожне натискання було б помітно; колір і поля живуть у вставленому
     *   стилі, тож без перебудови не обійтися.
     */
    fun appearance(
        activity: Activity,
        library: BookLibrary,
        onChange: (fast: Boolean) -> Unit,
    ): BottomSheetDialog {
        val dialog = BottomSheetDialog(activity)
        val content = column(activity)
        val refreshers = mutableListOf<() -> Unit>()

        fun changed(fast: Boolean) {
            library.saveAppearance()
            refreshers.forEach { it() }
            onChange(fast)
        }

        content.addView(title(activity, activity.getString(R.string.appearance)))

        // Зразок
        content.addView(heading(activity, R.string.themes))
        val grid = GridLayout(activity).apply {
            columnCount = 3
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
        }
        for (theme in BookAppearance.THEMES) {
            val chip = Button(activity).apply {
                text = activity.getString(theme.nameRes)
                isAllCaps = false
                setTextColor(BookAppearance.argb(theme.ink))
                background = rounded(BookAppearance.argb(theme.paper), 8f)
                layoutParams = GridLayout.LayoutParams().apply {
                    width = 0
                    height = dp(activity, 44)
                    columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
                    setMargins(dp(activity, 4), dp(activity, 4), dp(activity, 4), dp(activity, 4))
                }
                setOnClickListener {
                    BookAppearance.paperColor = theme.paper
                    BookAppearance.inkColor = theme.ink
                    changed(false)
                }
            }
            refreshers += {
                val current = BookAppearance.paperColor == theme.paper &&
                    BookAppearance.inkColor == theme.ink
                chip.background = rounded(
                    BookAppearance.argb(theme.paper),
                    8f,
                    if (current) BookAppearance.argb(0xE4DFD0) else Color.TRANSPARENT,
                    dp(activity, 2),
                )
            }
            grid.addView(chip)
        }
        content.addView(grid)

        // Власні кольори
        content.addView(heading(activity, R.string.own_colors))
        content.addView(
            colorRow(activity, R.string.paper_color, refreshers,
                get = { BookAppearance.paperColor },
                set = { BookAppearance.paperColor = it; changed(false) })
        )
        content.addView(
            colorRow(activity, R.string.ink_color, refreshers,
                get = { BookAppearance.inkColor },
                set = { BookAppearance.inkColor = it; changed(false) })
        )

        // Кегль
        content.addView(heading(activity, R.string.text_size))
        content.addView(
            stepperRow(
                activity, R.string.font_size, refreshers,
                get = { BookAppearance.fontSize },
                set = { BookAppearance.fontSize = BookAppearance.clampFontSize(it) },
                step = BookAppearance.FONT_SIZE_STEP,
                min = BookAppearance.MINIMUM_FONT_SIZE,
                max = BookAppearance.MAXIMUM_FONT_SIZE,
                format = { "${Math.round(it * 100)}%" },
                onChanged = { changed(true) },
            )
        )

        // Поля сторінки
        content.addView(heading(activity, R.string.page_margins))
        content.addView(
            marginRow(activity, R.string.left_margin, refreshers,
                get = { BookAppearance.leftMargin },
                set = { BookAppearance.leftMargin = BookAppearance.clampSideMargin(it) },
                onChanged = { changed(false) })
        )
        content.addView(
            marginRow(activity, R.string.right_margin, refreshers,
                get = { BookAppearance.rightMargin },
                set = { BookAppearance.rightMargin = BookAppearance.clampSideMargin(it) },
                onChanged = { changed(false) })
        )
        content.addView(
            stepperRow(
                activity, R.string.spread_gap, refreshers,
                get = { BookAppearance.spreadGap },
                set = { BookAppearance.spreadGap = BookAppearance.clampSpreadGap(it) },
                step = BookAppearance.SIDE_MARGIN_STEP,
                min = BookAppearance.MINIMUM_SPREAD_GAP,
                max = BookAppearance.MAXIMUM_SPREAD_GAP,
                format = { "${it.toInt()} px" },
                onChanged = { changed(false) },
            )
        )

        // Дії
        val actions = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(activity, 8), 0, 0)
        }
        actions.addView(Button(activity).apply {
            text = activity.getString(R.string.reset_appearance)
            isAllCaps = false
            setTextColor(Color.parseColor("#D98B80"))
            background = null
            setOnClickListener {
                BookAppearance.reset()
                changed(false)
            }
        })
        actions.addView(View(activity), LinearLayout.LayoutParams(0, 1, 1f))
        actions.addView(Button(activity).apply {
            text = activity.getString(R.string.done)
            isAllCaps = false
            setTextColor(BookAppearance.argb(BookAppearance.DEFAULT_INK))
            background = rounded(BookAppearance.argb(BookAppearance.DEFAULT_PAPER), 999f)
            setOnClickListener { dialog.dismiss() }
        })
        content.addView(actions)

        refreshers.forEach { it() }
        dialog.setContentView(scroll(activity, content))
        return dialog
    }

    // MARK: — Зміст

    fun contents(
        activity: Activity,
        entries: List<ContentsEntry>,
        currentHref: String?,
        onPick: (Link) -> Unit,
    ): BottomSheetDialog {
        val dialog = BottomSheetDialog(activity)
        val content = column(activity)
        content.addView(title(activity, activity.getString(R.string.contents)))

        if (entries.isEmpty()) {
            content.addView(muted(activity, activity.getString(R.string.no_contents)))
        } else {
            for (entry in entries) {
                val isCurrent = currentHref != null &&
                    entry.link.href.toString().substringBefore('#') ==
                    currentHref.substringBefore('#')

                content.addView(listButton(activity, entry.title.ifBlank { entry.link.href.toString() }) {
                    dialog.dismiss()
                    onPick(entry.link)
                }.apply {
                    // Відступ за рівнем вкладеності — як у дереві на macOS.
                    setPadding(
                        dp(activity, 10 + entry.depth * 16),
                        paddingTop, paddingRight, paddingBottom,
                    )
                    if (isCurrent) setTextColor(BookAppearance.argb(BookAppearance.paperColor))
                })
            }
        }

        dialog.setContentView(scroll(activity, content))
        return dialog
    }

    // MARK: — Бібліотека

    fun library(
        activity: Activity,
        books: List<BookRecord>,
        current: Uri?,
        onPick: (BookRecord) -> Unit,
        onAdd: () -> Unit,
    ): BottomSheetDialog {
        val dialog = BottomSheetDialog(activity)
        val content = column(activity)
        content.addView(title(activity, activity.getString(R.string.library)))

        if (books.isEmpty()) {
            content.addView(muted(activity, activity.getString(R.string.library_empty)))
        } else {
            for (book in books) {
                val parts = buildList {
                    if (book.author.isNotBlank()) add(book.author)
                    if (book.progress > 0) {
                        add(activity.getString(R.string.read_percent, Math.round(book.progress * 100).toInt()))
                    }
                }
                val label = if (parts.isEmpty()) book.title
                else "${book.title}\n${parts.joinToString(" · ")}"

                content.addView(listButton(activity, label) {
                    dialog.dismiss()
                    onPick(book)
                }.apply {
                    if (book.uri == current) {
                        setTextColor(BookAppearance.argb(BookAppearance.paperColor))
                    }
                })
            }
        }

        content.addView(Button(activity).apply {
            text = activity.getString(R.string.add_book)
            isAllCaps = false
            setTextColor(BookAppearance.argb(BookAppearance.DEFAULT_INK))
            background = rounded(BookAppearance.argb(BookAppearance.DEFAULT_PAPER), 999f)
            layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply {
                topMargin = dp(activity, 10)
            }
            setOnClickListener {
                dialog.dismiss()
                onAdd()
            }
        })

        dialog.setContentView(scroll(activity, content))
        return dialog
    }

    // MARK: — Будівельні блоки

    private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

    private fun dp(activity: Activity, value: Int): Int =
        (value * activity.resources.displayMetrics.density).toInt()

    private fun column(activity: Activity) = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(activity, 20), dp(activity, 18), dp(activity, 20), dp(activity, 18))
        setBackgroundColor(Color.parseColor("#1C1C1C"))
    }

    private fun scroll(activity: Activity, child: View) = ScrollView(activity).apply {
        addView(child)
        layoutParams = FrameLayout.LayoutParams(MATCH, WRAP)
    }

    private fun title(activity: Activity, text: String) = TextView(activity).apply {
        this.text = text
        textSize = 18f
        setTextColor(BookAppearance.argb(0xE4DFD0))
        setPadding(0, 0, 0, dp(activity, 10))
    }

    private fun heading(activity: Activity, res: Int) = TextView(activity).apply {
        text = activity.getString(res).uppercase()
        textSize = 11f
        letterSpacing = 0.08f
        alpha = 0.5f
        setTextColor(BookAppearance.argb(0xE4DFD0))
        setPadding(0, dp(activity, 14), 0, dp(activity, 6))
    }

    private fun muted(activity: Activity, text: String) = TextView(activity).apply {
        this.text = text
        alpha = 0.5f
        setTextColor(BookAppearance.argb(0xE4DFD0))
        setPadding(0, dp(activity, 6), 0, dp(activity, 6))
    }

    private fun listButton(activity: Activity, label: String, action: () -> Unit) =
        TextView(activity).apply {
            text = label
            setTextColor(BookAppearance.argb(0xE4DFD0))
            setPadding(dp(activity, 10), dp(activity, 10), dp(activity, 10), dp(activity, 10))
            isClickable = true
            setOnClickListener { action() }
        }

    private fun rounded(
        fill: Int,
        radius: Float,
        stroke: Int = Color.TRANSPARENT,
        strokeWidth: Int = 0,
    ) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = radius
        if (strokeWidth > 0) setStroke(strokeWidth, stroke)
    }

    private fun row(activity: Activity, labelRes: Int): LinearLayout {
        val line = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(activity, 7), 0, dp(activity, 7))
        }
        line.addView(TextView(activity).apply {
            text = activity.getString(labelRes)
            setTextColor(BookAppearance.argb(0xE4DFD0))
            layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f)
        })
        return line
    }

    /** Рядок із зразком кольору; дотик відкриває три повзунки. */
    private fun colorRow(
        activity: Activity,
        labelRes: Int,
        refreshers: MutableList<() -> Unit>,
        get: () -> Int,
        set: (Int) -> Unit,
    ): View {
        val line = row(activity, labelRes)
        val swatch = View(activity).apply {
            layoutParams = LinearLayout.LayoutParams(dp(activity, 44), dp(activity, 26))
            setOnClickListener { pickColor(activity, get(), set) }
        }
        refreshers += { swatch.background = rounded(BookAppearance.argb(get()), 6f) }
        line.addView(swatch)
        return line
    }

    /**
     * Вибір кольору трьома повзунками.
     *
     * Android не має власного вибирача кольору, а тягнути заради цього
     * чужу бібліотеку — забагато. Три повзунки з живим зразком роблять
     * те саме й нічого не важать.
     */
    private fun pickColor(activity: Activity, initial: Int, set: (Int) -> Unit) {
        var red = (initial shr 16) and 0xFF
        var green = (initial shr 8) and 0xFF
        var blue = initial and 0xFF

        val content = column(activity)
        val preview = View(activity).apply {
            layoutParams = LinearLayout.LayoutParams(MATCH, dp(activity, 54))
            background = rounded(BookAppearance.argb(initial), 8f)
        }
        content.addView(preview)

        fun channel(name: String, value: Int, apply: (Int) -> Unit) {
            content.addView(TextView(activity).apply {
                text = name
                alpha = 0.6f
                setTextColor(BookAppearance.argb(0xE4DFD0))
                setPadding(0, dp(activity, 10), 0, 0)
            })
            content.addView(SeekBar(activity).apply {
                max = 255
                progress = value
                layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(bar: SeekBar?, p: Int, byUser: Boolean) {
                        apply(p)
                        preview.background =
                            rounded(BookAppearance.argb((red shl 16) or (green shl 8) or blue), 8f)
                    }

                    override fun onStartTrackingTouch(bar: SeekBar?) = Unit
                    override fun onStopTrackingTouch(bar: SeekBar?) = Unit
                })
            })
        }

        channel("R", red) { red = it }
        channel("G", green) { green = it }
        channel("B", blue) { blue = it }

        AlertDialog.Builder(activity)
            .setView(scroll(activity, content))
            .setPositiveButton(R.string.done) { _, _ ->
                set((red shl 16) or (green shl 8) or blue)
            }
            .show()
    }

    private fun marginRow(
        activity: Activity,
        labelRes: Int,
        refreshers: MutableList<() -> Unit>,
        get: () -> Double,
        set: (Double) -> Unit,
        onChanged: () -> Unit,
    ): View = stepperRow(
        activity, labelRes, refreshers, get, set,
        step = BookAppearance.SIDE_MARGIN_STEP,
        min = BookAppearance.MINIMUM_SIDE_MARGIN,
        max = BookAppearance.MAXIMUM_SIDE_MARGIN,
        format = { "${it.toInt()} px" },
        onChanged = onChanged,
    )

    private fun stepperRow(
        activity: Activity,
        labelRes: Int,
        refreshers: MutableList<() -> Unit>,
        get: () -> Double,
        set: (Double) -> Unit,
        step: Double,
        min: Double,
        max: Double,
        format: (Double) -> String,
        onChanged: () -> Unit,
    ): View {
        val line = row(activity, labelRes)

        val minus = stepButton(activity, "−") { set(get() - step); onChanged() }
        val value = TextView(activity).apply {
            gravity = Gravity.CENTER
            alpha = 0.75f
            setTextColor(BookAppearance.argb(0xE4DFD0))
            layoutParams = LinearLayout.LayoutParams(dp(activity, 70), WRAP)
        }
        val plus = stepButton(activity, "+") { set(get() + step); onChanged() }

        refreshers += {
            val current = get()
            value.text = format(current)
            minus.isEnabled = current > min
            minus.alpha = if (minus.isEnabled) 1f else 0.35f
            plus.isEnabled = current < max
            plus.alpha = if (plus.isEnabled) 1f else 0.35f
        }

        line.addView(minus)
        line.addView(value)
        line.addView(plus)
        return line
    }

    private fun stepButton(activity: Activity, label: String, action: () -> Unit) =
        TextView(activity).apply {
            text = label
            gravity = Gravity.CENTER
            textSize = 18f
            setTextColor(BookAppearance.argb(0xE4DFD0))
            background = rounded(Color.parseColor("#323232"), 6f)
            layoutParams = LinearLayout.LayoutParams(dp(activity, 40), dp(activity, 32))
            isClickable = true
            setOnClickListener { action() }
        }
}
