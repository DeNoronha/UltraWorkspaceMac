plugins {
    id("com.android.application")
}

android {
    namespace = "nl.denoronha.deckhand.monitor"
    compileSdk = 34

    defaultConfig {
        minSdk = 29
        targetSdk = 34
        versionCode = 12
        versionName = "2.1"
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    // The page scripts are the Mac app's own (Sources/UltraWorkspaceApp/Resources/pages): one source for the pages
    // Deckhand serves and the pages the on-bar apps carry. Packaged as assets: shell.html, <page>.js.
    sourceSets {
        getByName("main") {
            assets.srcDir("../../../Sources/UltraWorkspaceApp/Resources/pages")
        }
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
            Triple("haven", "nl.denoronha.deckhand.haven", "Haven"),
            Triple("tide", "nl.denoronha.deckhand.tide", "Tide"),
            Triple("teletekst", "nl.denoronha.deckhand.teletekst", "Teletekst"),
        )
        // These fetch their own data on the bar (1.9): page and feeds in the APK, only config.json from the Mac.
        val onBar = setOf("flights", "crypto", "weather", "sky", "news", "verse", "tide", "teletekst")
        for ((flavor, appId, label) in pages) {
            create(flavor) {
                dimension = "page"
                applicationId = appId
                resValue("string", "app_name", label)
                buildConfigField("String", "PAGE", "\"$flavor\"")
                buildConfigField("String", "TITLE", "\"$label\"")
                buildConfigField("boolean", "ON_BAR", if (flavor in onBar) "true" else "false")
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
