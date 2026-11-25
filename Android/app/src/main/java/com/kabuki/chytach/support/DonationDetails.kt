package com.kabuki.chytach.support

/**
 * Реквізити для внеску.
 *
 * Ті самі, що у версії для macOS. Імені отримувача тут навмисно немає:
 * воно потрібне лише для переказу за IBAN, а банка й картка приймають
 * гроші без нього — тож і IBAN, і імʼя прибрано з усіх версій.
 */
object DonationDetails {

    const val JAR_URL = "https://send.monobank.ua/jar/bUjttUaxp"
    const val CARD_NUMBER = "4874100027184244"

    val AMOUNTS = listOf(100, 200, 500)

    /** Номер картки групами по чотири — так його легше звірити очима. */
    fun grouped(value: String): String = value.chunked(4).joinToString(" ")

    /** Посилання на банку з наперед вписаною сумою. */
    fun jarUrl(amount: Int?): String =
        if (amount != null && amount > 0) "$JAR_URL?a=$amount" else JAR_URL
}
