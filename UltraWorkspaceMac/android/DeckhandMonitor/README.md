# Deckhand bar apps (Android)

A tiny full-screen kiosk app for the Sanytron UltraBar X CoreBar (Android 10, 1424×280 landscape). It is a single `WebView` that shows one of the live pages served by the Deckhand macOS app on the LAN. The CoreBar launcher shows one card per installed package, so the project is built as six product flavors, one per page, each with its own package, label and icon:

| flavor | applicationId | label | page |
|---|---|---|---|
| monitor | nl.denoronha.deckhand.monitor | Monitor | /monitor |
| claude | nl.denoronha.deckhand.claude | Claude | /claude |
| crypto | nl.denoronha.deckhand.crypto | Crypto | /crypto |
| weather | nl.denoronha.deckhand.weather | Weather | /weather |
| music | nl.denoronha.deckhand.music | Music | /music |
| calendar | nl.denoronha.deckhand.calendar | Calendar | /calendar |

The flavors are declared in `app/build.gradle.kts` (one dimension, `page`); each sets `applicationId`, the `app_name` string and `BuildConfig.PAGE`. The shared code lives in `src/main`, the launcher icon foreground per flavor in `src/<flavor>/res/drawable/ic_launcher_foreground.xml` (the dark blue background is shared).

## How it finds Deckhand

Deckhand sends a UDP beacon to port 5320 every 5 s, both as a broadcast to `255.255.255.255` and as a unicast to the bar's IP (the bar's Wi‑Fi tends to drop broadcasts): `{"deckhand":"monitor","v":2,"base":"http://<mac-ip>:7432","url":"http://<mac-ip>:7432/monitor"}`. Each app opens `base + "/" + BuildConfig.PAGE`, so one beacon serves all six cards; a v1 beacon without `base` falls back to its `url`. On start the app shows "Looking for Deckhand…", listens on UDP 5320 (with a Wi‑Fi `MulticastLock` so broadcasts get through) and loads the first page URL it computes. It keeps listening while in front; a beacon that yields a different URL switches the page. The last URL is remembered in `SharedPreferences`: if no beacon arrives within 4 s the remembered URL is loaded, and if there is none the app keeps looking. If the page fails to load it falls back to the "Looking for Deckhand…" page and retries every 5 s (and immediately on the next beacon).

## Leaving the app

Long press (≥ 700 ms) anywhere, press the hardware back key, or let the page call `Deckhand.close()` from JavaScript (the page can also read `Deckhand.version()`). The activity just finishes; the CoreBar launcher is the HOME app and comes back on its own.

## Build

Requires JDK 21, the Android command-line tools with `platforms;android-34`, and network access the first time (the Gradle wrapper downloads Gradle 9.8.2 and AGP 9.4.1 pulls in Build-Tools 36.0.0 automatically).

```sh
cd android/DeckhandMonitor
JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ./gradlew assembleDebug
for f in monitor:Monitor claude:Claude crypto:Crypto weather:Weather music:Music calendar:Calendar; do cp app/build/outputs/apk/${f%%:*}/debug/app-${f%%:*}-debug.apk ../../dist/bar-apps/Deckhand${f##*:}.apk; done
cp ../../dist/bar-apps/DeckhandMonitor.apk ../../dist/DeckhandMonitor.apk
```

`assembleDebug` builds all six flavors; `assembleClaudeDebug` etc. builds one.

The debug-signed APK is fine for the bar (it is an eng build). Kotlin, no Compose, no AndroidX.

## Install by hand

```sh
adb install -r dist/bar-apps/DeckhandMonitor.apk
for f in dist/bar-apps/Deckhand*.apk; do adb install -r "$f"; done
```

`-r` updates an installed card in place (same package, debug signature).

## Test with an explicit URL

```sh
adb shell am start -n nl.denoronha.deckhand.monitor/nl.denoronha.deckhand.monitor.MainActivity --es url http://192.168.50.207:7432/monitor
adb shell am start -n nl.denoronha.deckhand.weather/nl.denoronha.deckhand.monitor.MainActivity --es url http://192.168.50.207:7432/weather
```

The activity class is `nl.denoronha.deckhand.monitor.MainActivity` in every flavor (only the package differs), so the component name must be written in full. The `url` extra takes precedence over discovery and is remembered like a beacon URL. Logs are tagged `DeckhandMonitor` (`adb logcat -s DeckhandMonitor`).
