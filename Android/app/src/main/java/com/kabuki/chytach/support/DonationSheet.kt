package com.kabuki.chytach.support

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.kabuki.chytach.R
import com.kabuki.chytach.reader.BookAppearance

/**
 * Екран підтримки проєкту.
 *
 * Те саме, що у версії для macOS: банка monobank із наперед вписаною
 * сумою та номер картки з кнопкою копіювання. Тексти однакові слово в
 * слово — це той самий застосунок, лише на іншій системі.
 */
object DonationSheet {

    fun show(activity: Activity, hasOpenBook: Boolean) {
        val dialog = BottomSheetDialog(activity)
        val content = column(activity)

        content.addView(title(activity, activity.getString(R.string.donate_title)))
        content.addView(body(activity, activity.getString(R.string.donate_body)))
        content.addView(muted(activity, activity.getString(R.string.donate_voluntary)))

        var chosen: Int? = DonationDetails.AMOUNTS[1]
        var custom: EditText? = null

        content.addView(heading(activity, R.string.donate_jar))

        val amounts = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
        }
        val chips = mutableListOf<TextView>()

        fun highlight() {
            for ((index, chip) in chips.withIndex()) {
                val isChosen = chosen == DonationDetails.AMOUNTS[index]
                chip.background = rounded(
                    if (isChosen) BookAppearance.argb(BookAppearance.DEFAULT_PAPER)
                    else Color.parseColor("#323232"),
                    999f,
                )
                chip.setTextColor(
                    if (isChosen) BookAppearance.argb(BookAppearance.DEFAULT_INK)
                    else BookAppearance.argb(0xE4DFD0)
                )
            }
        }

        for (amount in DonationDetails.AMOUNTS) {
            val chip = TextView(activity).apply {
                text = "$amount ₴"
                gravity = Gravity.CENTER
                setPadding(dp(activity, 14), dp(activity, 10), dp(activity, 14), dp(activity, 10))
                layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f).apply {
                    marginEnd = dp(activity, 8)
                }
                isClickable = true
                setOnClickListener {
                    chosen = amount
                    custom?.setText("")
                    highlight()
                }
            }
            chips += chip
            amounts.addView(chip)
        }
        content.addView(amounts)

        // Власна сума: щойно в полі зʼявляється число, готові суми гаснуть.
        custom = EditText(activity).apply {
            hint = activity.getString(R.string.donate_custom_amount)
            inputType = InputType.TYPE_CLASS_NUMBER
            setTextColor(BookAppearance.argb(0xE4DFD0))
            setHintTextColor(Color.parseColor("#777777"))
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply {
                topMargin = dp(activity, 8)
            }
            addTextChangedListener(object : android.text.TextWatcher {
                override fun afterTextChanged(editable: android.text.Editable?) {
                    val typed = editable?.toString()?.toIntOrNull()
                    chosen = typed ?: if (editable.isNullOrBlank()) DonationDetails.AMOUNTS[1] else null
                    highlight()
                }

                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            })
        }
        content.addView(custom)
        highlight()

        content.addView(Button(activity).apply {
            text = activity.getString(R.string.donate_via_monobank)
            isAllCaps = false
            setTextColor(BookAppearance.argb(BookAppearance.DEFAULT_INK))
            background = rounded(BookAppearance.argb(BookAppearance.DEFAULT_PAPER), 999f)
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply {
                topMargin = dp(activity, 12)
            }
            setOnClickListener {
                val url = DonationDetails.jarUrl(chosen)
                runCatching {
                    activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                }
            }
        })
        content.addView(muted(activity, activity.getString(R.string.donate_jar_note)))

        // Картка
        content.addView(heading(activity, R.string.donate_card))
        content.addView(cardRow(activity))
        content.addView(muted(activity, activity.getString(R.string.donate_currency_note)))

        content.addView(Button(activity).apply {
            text = activity.getString(
                if (hasOpenBook) R.string.donate_back_to_reading else R.string.donate_not_now
            )
            isAllCaps = false
            setTextColor(BookAppearance.argb(0xE4DFD0))
            background = null
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply {
                topMargin = dp(activity, 10)
            }
            setOnClickListener { dialog.dismiss() }
        })

        dialog.setContentView(scroll(activity, content))
        dialog.show()
    }

    /** Рядок із номером картки й кнопкою копіювання. */
    private fun cardRow(activity: Activity): View {
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(activity, 14), dp(activity, 12), dp(activity, 14), dp(activity, 12))
            background = rounded(Color.parseColor("#14FFFFFF"), 14f)
        }

        row.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f)
            addView(TextView(activity).apply {
                text = activity.getString(R.string.donate_card_number)
                textSize = 13f
                alpha = 0.6f
                setTextColor(BookAppearance.argb(0xE4DFD0))
            })
            addView(TextView(activity).apply {
                text = DonationDetails.grouped(DonationDetails.CARD_NUMBER)
                textSize = 19f
                typeface = android.graphics.Typeface.MONOSPACE
                setTextColor(BookAppearance.argb(0xE4DFD0))
                setTextIsSelectable(true)
            })
        })

        val copy = TextView(activity).apply {
            text = activity.getString(R.string.donate_copy)
            gravity = Gravity.CENTER
            setPadding(dp(activity, 14), dp(activity, 8), dp(activity, 14), dp(activity, 8))
            setTextColor(BookAppearance.argb(0xE4DFD0))
            background = rounded(Color.parseColor("#323232"), 999f)
            isClickable = true
        }
        copy.setOnClickListener {
            val clipboard =
                activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(
                ClipData.newPlainText("card", DonationDetails.CARD_NUMBER)
            )
            copy.text = activity.getString(R.string.donate_copied)
            copy.postDelayed(
                { copy.text = activity.getString(R.string.donate_copy) },
                2000,
            )
        }
        row.addView(copy)
        return row
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
        textSize = 26f
        setTextColor(BookAppearance.argb(BookAppearance.DEFAULT_PAPER))
        setPadding(0, 0, 0, dp(activity, 10))
    }

    private fun body(activity: Activity, text: String) = TextView(activity).apply {
        this.text = text
        textSize = 15f
        setTextColor(BookAppearance.argb(0xE4DFD0))
    }

    private fun muted(activity: Activity, text: String) = TextView(activity).apply {
        this.text = text
        textSize = 13f
        alpha = 0.6f
        setTextColor(BookAppearance.argb(0xE4DFD0))
        setPadding(0, dp(activity, 8), 0, 0)
    }

    private fun heading(activity: Activity, res: Int) = TextView(activity).apply {
        text = activity.getString(res).uppercase()
        textSize = 11f
        letterSpacing = 0.08f
        alpha = 0.5f
        setTextColor(BookAppearance.argb(0xE4DFD0))
        setPadding(0, dp(activity, 18), 0, dp(activity, 8))
    }

    private fun rounded(fill: Int, radius: Float) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = radius
    }
}
