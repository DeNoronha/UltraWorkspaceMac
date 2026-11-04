# Deckhand Monitor (Android)

A tiny full-screen kiosk app for the Sanytron UltraBar X CoreBar (Android 10, 1424×280 landscape). It is a single `WebView` that shows the live monitoring page served by the Deckhand macOS app on the LAN. It appears in the CoreBar launcher as a normal app card called "Monitor".

## How it finds Deckhand

Deckhand broadcasts a UDP beacon to `255.255.255.255:5320` every 5 s: `{"deckhand":"monitor","url":"http://<mac-ip>:7432/monitor","v":1}`. On start the app shows "Looking for Deckhand…", listens on UDP 5320 (with a Wi‑Fi `MulticastLock` so broadcasts get through) and loads the first URL it sees. It keeps listening while in front; a beacon with a different URL switches the page. The last URL is remembered in `SharedPreferences`: if no beacon arrives within 4 s the remembered URL is loaded, and if there is none the app keeps looking. If the page fails to load it falls back to the "Looking for Deckhand…" page and retries every 5 s (and immediately on the next beacon).

## Leaving the app

Long press (≥ 700 ms) anywhere, press the hardware back key, or let the page call `Deckhand.close()` from JavaScript (the page can also read `Deckhand.version()`). The activity just finishes; the CoreBar launcher is the HOME app and comes back on its own.

## Build

Requires JDK 21, the Android command-line tools with `platforms;android-34`, and network access the first time (the Gradle wrapper downloads Gradle 9.8.2 and AGP 9.4.1 pulls in Build-Tools 36.0.0 automatically).

```sh
cd android/DeckhandMonitor
JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ./gradlew assembleDebug
cp app/build/outputs/apk/debug/app-debug.apk ../../dist/DeckhandMonitor.apk
```

The debug-signed APK is fine for the bar (it is an eng build). Kotlin, no Compose, no AndroidX.

## Install by hand

```sh
adb install -r dist/DeckhandMonitor.apk
```

## Test with an explicit URL

```sh
adb shell am start -n nl.denoronha.deckhand.monitor/.MainActivity --es url http://192.168.50.207:7432/monitor
```

The `url` extra takes precedence over discovery and is remembered like a beacon URL. Logs are tagged `DeckhandMonitor` (`adb logcat -s DeckhandMonitor`).
