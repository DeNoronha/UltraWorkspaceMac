plugins {
    id("com.android.application")
}

android {
    namespace = "nl.denoronha.deckhand.monitor"
    compileSdk = 34

    defaultConfig {
        minSdk = 29
        targetSdk = 34
        versionCode = 5
        versionName = "1.4"
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    // One card per page on the CoreBar launcher: each flavor is its own package.
    flavorDimensions += "page"
    productFlavors {
        val pages = listOf(
            Triple("monitor", "nl.denoronha.deckhand.monitor", "Monitor"),
            Triple("claude", "nl.denoronha.deckhand.claude", "Claude"),
            Triple("crypto", "nl.denoronha.deckhand.crypto", "Crypto"),
            Triple("weather", "nl.denoronha.deckhand.weather", "Weather"),
            Triple("music", "nl.denoronha.deckhand.music", "Music"),
            Triple("calendar", "nl.denoronha.deckhand.calendar", "Calendar"),
            Triple("flights", "nl.denoronha.deckhand.flights", "Flights"),
            Triple("sky", "nl.denoronha.deckhand.sky", "Sun & Moon"),
            Triple("news", "nl.denoronha.deckhand.news", "Headlines"),
            Triple("verse", "nl.denoronha.deckhand.verse", "Verse"),
            Triple("tasks", "nl.denoronha.deckhand.tasks", "Tasks"),
        )
        for ((flavor, appId, label) in pages) {
            create(flavor) {
                dimension = "page"
                applicationId = appId
                resValue("string", "app_name", label)
                buildConfigField("String", "PAGE", "\"$flavor\"")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
