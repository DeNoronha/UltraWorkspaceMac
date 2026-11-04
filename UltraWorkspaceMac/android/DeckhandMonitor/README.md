# Deckhand bar apps (Android)

A tiny full-screen kiosk app for the Sanytron UltraBar X CoreBar (Android 10, 1424×280 landscape). It is a single `WebView` that shows one of the live pages served by the Deckhand macOS app on the LAN. The CoreBar launcher shows one card per installed package, so the project is built as eleven product flavors, one per page, each with its own package, label and icon:

| flavor | applicationId | label | page |
|---|---|---|---|
| monitor | nl.denoronha.deckhand.monitor | Monitor | /monitor |
| claude | nl.denoronha.deckhand.claude | Claude | /claude |
| crypto | nl.denoronha.deckhand.crypto | Crypto | /crypto |
| weather | nl.denoronha.deckhand.weather | Weather | /weather |
| music | nl.denoronha.deckhand.music | Music | /music |
| calendar | nl.denoronha.deckhand.calendar | Calendar | /calendar |
| flights | nl.denoronha.deckhand.flights | Flights | /flights |
| sky | nl.denoronha.deckhand.sky | Sun & Moon | /sky |
| news | nl.denoronha.deckhand.news | Headlines | /news |
| verse | nl.denoronha.deckhand.verse | Verse | /verse |
| tasks | nl.denoronha.deckhand.tasks | Tasks | /tasks |

The flavors are declared in `app/build.gradle.kts` (one dimension, `page`); each sets `applicationId`, the `app_name` string and `BuildConfig.PAGE`. All eleven share one version: `versionCode 8` / `versionName 1.7` in `app/build.gradle.kts`, which must move together with `AppModel.barAppsVersion` in the Mac app (the Apps page compares the bar's copy against it) and the `version` fields in `site/marketplace/registry.json`. The shared code lives in `src/main`; everything icon-related per flavor lives in `src/<flavor>/res/` and is generated (see below).

## Launcher icons

`tools/make-icons.swift` renders every flavor's icons with AppKit and must be run on a Mac (`cd android/DeckhandMonitor && swift tools/make-icons.swift`). Every flavor except `claude` uses a 3D render from Microsoft's [Fluent Emoji](https://github.com/microsoft/fluentui-emoji) set (MIT licence; the PNGs, their source URLs and the licence text are in `tools/fluent/SOURCES.md`): monitor chart increasing, crypto coin, weather sun behind cloud, music musical note, calendar spiral calendar, flights airplane, sky crescent moon, news rolled-up newspaper, verse open book, tasks check mark button. The glyph is trimmed to its opaque bounds, fitted into about 62 % of the icon, given a soft drop shadow and placed on a two-tone vertical gradient (top and bottom colour per flavor in the `flavors` table at the top of the script) with a soft radial highlight top-left. The Claude flavor keeps its hand-drawn 12-ray starburst in #d97757 on a dark gradient. Per flavor the script writes, under `app/src/<flavor>/res/`, `mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_background.png` (adaptive background, 108 dp canvas), `mipmap-*/ic_launcher_foreground.png` (adaptive foreground, the glyph inside the 72 dp safe zone), `mipmap-*/ic_launcher.png` (legacy 48 dp icon: 20 % rounded square, composed), `values/ic_launcher_background.xml` (the flavor's base colour, kept for anything that reads it), and previews of the composed icon to `dist/bar-apps/icons/<flavor>.png` (216 px) and `<flavor>-240.png` (the bar shows the icons at about 240 px on a card). The shared `src/main/res/mipmap-anydpi-v26/ic_launcher.xml` is the adaptive icon that points at those; the manifest uses it for both `icon` and `roundIcon`. To change a glyph or colour, edit the `flavors` table and run the script again; the PNGs are committed so a build does not need the script. The site's `assets/img/icons/*.png` are copies of these previews.

## How it finds Deckhand

Deckhand sends a UDP beacon to port 5320 every 5 s, both as a broadcast to `255.255.255.255` and as a unicast to the bar's IP (the bar's Wi‑Fi drops broadcasts; the unicast always arrives): `{"deckhand":"monitor","v":2,"base":"http://<mac-ip>:7432","url":"http://<mac-ip>:7432/monitor"}`. Each app opens `base + "/" + BuildConfig.PAGE`, so one beacon serves all eleven cards; a v1 beacon without `base` falls back to its `url`. On start the app shows "Looking for Deckhand…", listens on UDP 5320 (with a Wi‑Fi `MulticastLock` so broadcasts get through; the listener owns its socket, so an old listener can never close a newer one's socket when onPause/onResume follow each other quickly) and loads the first page URL it computes. It keeps listening while in front; a beacon that yields a different URL switches the page. The last URL is remembered in `SharedPreferences`: if no beacon arrives within 4 s the remembered URL is loaded, and if there is none the app keeps looking. If the page fails to load it falls back to the "Looking for Deckhand…" page and retries every 5 s (and immediately on the next beacon); the WebView is detached and destroyed when the activity goes away.

## What it will and will not load (1.6 and later)

Since 1.7 a beacon is only accepted when the URL it carries points at the address the beacon came from, so a spoofed beacon from another host cannot send the kiosk to a page of its own.

Whatever the source — beacon, the `url` intent extra or the remembered URL — a page is loaded only when it is an `http(s)://` URL whose host is a private IPv4 address: 10/8, 172.16/12, 192.168/16 or 169.254/16. Anything else is dropped with a log line that says why (tag `DeckhandMonitor`), so a forged beacon or a stale preference cannot send the bar's WebView anywhere but a machine on the LAN. Once a page is loaded the WebView may only navigate within the host and port it was loaded from (`shouldOverrideUrlLoading`; blocked navigations are logged as "Blocked navigation to …"); the pages themselves only fetch their own `data.json`, the Music artwork and the Flights map tiles from that same origin, and send their few actions (Music transport, Tasks Done) as POSTs with the `X-Deckhand: action` header, which Deckhand's server requires for anything that changes state. The app asks for two permissions only: `INTERNET` and `CHANGE_WIFI_MULTICAST_STATE` (for the multicast lock). Cleartext HTTP is allowed on purpose: the pages are plain HTTP on the LAN.

## Leaving the app

Long press (≥ 700 ms) anywhere, press the hardware back key, or let the page call `Deckhand.close()` from JavaScript (the page can also read `Deckhand.version()`). The activity just finishes; the CoreBar launcher is the HOME app and comes back on its own.

## Build

Requires JDK 21, the Android command-line tools with `platforms;android-34`, and network access the first time (the Gradle wrapper downloads Gradle 9.8.2 and AGP 9.4.1 pulls in Build-Tools 36.0.0 automatically).

```sh
cd android/DeckhandMonitor
JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ./gradlew assembleDebug
for f in monitor:Monitor claude:Claude crypto:Crypto weather:Weather music:Music calendar:Calendar flights:Flights sky:Sky news:News verse:Verse tasks:Tasks; do cp app/build/outputs/apk/${f%%:*}/debug/app-${f%%:*}-debug.apk ../../dist/bar-apps/Deckhand${f##*:}.apk; done
cp ../../dist/bar-apps/DeckhandMonitor.apk ../../dist/DeckhandMonitor.apk
```

`assembleDebug` builds all eleven flavors; `assembleClaudeDebug` etc. builds one.

The debug-signed APK is fine for the bar (it is an eng build). Kotlin, no Compose, no AndroidX. The Mac app installs these APKs from the Apps page (switch **Installed on the bar**, over Wi-Fi ADB; Settings → Debug bridge turns Wi-Fi ADB on over USB and keeps it on after reboots); `packaging/make-app.sh` bundles whatever is in `dist/bar-apps/` into Deckhand.app, so rebuild here before a release.

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

The activity class is `nl.denoronha.deckhand.monitor.MainActivity` in every flavor (only the package differs), so the component name must be written in full. The `url` extra takes precedence over discovery and is remembered like a beacon URL, under the same rule: it must be an http(s) URL on a private LAN address or it is ignored. Logs are tagged `DeckhandMonitor` (`adb logcat -s DeckhandMonitor`).
