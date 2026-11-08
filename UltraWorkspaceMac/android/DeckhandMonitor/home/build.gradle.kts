plugins {
    id("com.android.application")
}

// Deckhand Home: a HOME-category launcher for the CoreBar's 1424×280 screen that lists every installed app as a tile.
// Separate package from the eleven page kiosks (app/), its own version.
android {
    namespace = "nl.denoronha.deckhand.home"
    compileSdk = 34

    defaultConfig {
        applicationId = "nl.denoronha.deckhand.home"
        minSdk = 29
        targetSdk = 34
        versionCode = 2
        versionName = "1.1"
    }

    buildFeatures {
        buildConfig = true
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
