// Kotlin 2.4.20 — не вільний вибір: артефакти Readium 3.4.0 скомпільовані
// саме ним, а метадані версії 2.4 старіший компілятор прочитати не може.
//
// AGP 9 має Kotlin вбудованим і зовнішнього плагіна `kotlin.android` не
// приймає, а власний компілятор везе версії 2.2. Версію задає той Kotlin
// Gradle Plugin, що потрапив на classpath збірки, тому оголошуємо тут
// плагін серіалізації потрібної версії — він нам усе одно знадобиться для
// збереження налаштувань. Так само це робить сам Readium.
plugins {
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.4.20" apply false
}
