import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Підпис релізу. Ключ і паролі живуть поза репозиторієм: шлях до них
// задає keystore.properties, якого в git немає й не буде. Без цього файлу
// проєкт збирається як раніше, тільки реліз виходить непідписаний.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.kabuki.chytach"
    compileSdk = (property("android.compileSdk") as String).toInt()

    defaultConfig {
        applicationId = "com.kabuki.chytach"
        minSdk = (property("android.minSdk") as String).toInt()
        targetSdk = (property("android.targetSdk") as String).toInt()

        // Версія йде окремо від iOS-версії: нумерація спільна, збірки — ні.
        versionCode = 2
        versionName = "0.2.0"

    }

    androidResources {
        // Українська — мова вихідних рядків, англійська — переклад.
        localeFilters += setOf("uk", "en")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // Readium спирається на java.time, якого на API 24 ще немає.
        isCoreLibraryDesugaringEnabled = true
    }

    signingConfigs {
        keystoreProperties.getProperty("storeFile")?.let { path ->
            create("release") {
                storeFile = file(path)
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // R8 поки не вмикаємо: Readium спирається на рефлексію в
            // розборі публікацій, і скорочення коду треба перевіряти
            // окремо, а не разом із першим релізом.
            isMinifyEnabled = false
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }

    packaging {
        resources.excludes.add("META-INF/*")
    }
}


dependencies {
    val readium = "3.4.0"
    implementation("org.readium.kotlin-toolkit:readium-shared:$readium")
    implementation("org.readium.kotlin-toolkit:readium-streamer:$readium")
    implementation("org.readium.kotlin-toolkit:readium-navigator:$readium")

    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.core:core-ktx:1.19.0")
    implementation("androidx.appcompat:appcompat:1.8.0")
    implementation("androidx.fragment:fragment-ktx:1.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("com.google.android.material:material:1.14.0")
}
