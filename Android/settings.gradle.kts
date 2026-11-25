// Android-версія Chytach. Окремий Gradle-проєкт у тому ж репозиторії:
// спільного коду зі Swift-версією немає й бути не може, але спільні
// ресурси (зерно паперу, іконка, зразок книги) лежать поруч.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Chytach"

include(":app")
