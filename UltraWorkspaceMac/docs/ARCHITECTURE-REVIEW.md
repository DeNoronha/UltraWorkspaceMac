# Deckhand — architecture review (2026-11-04)

Read-only review at commit `e1faf57` (main, clean tree). Every Swift file in `Sources/`, the Android `MainActivity.kt` and `build.gradle.kts`, `PROTOCOL.md`, `docs/WIDGETS.md`, `docs/COLLAB.md`, `docs/UX-REVIEW.md`, `docs/ROADMAP.md`, `MANUAL.md` and `README.md` were read; `swift build` passes. Line numbers are file lines at this commit. The previous review (`docs/reviews/architecture-2026-11-03.md`) is taken as the baseline: its phase-1 items are done (act-aware redaction, `CoreBarLink.State` as an enum, volume off the main actor through `MacAudio`, upload cancellation, `UploadReply` classification), its phase-2 and phase-3 items (device twin, one polling owner, typed profiles, a testable core) are not, and a whole new subsystem has landed since: eleven bar apps, `BarPages`, `MonitorServer`, ADB, presence, the marketplace page. This review therefore concentrates on where the new subsystem stresses the structure and re-ranks the older items against it.

## 1. The architecture as it is

Three Swift targets in one package (`Package.swift:11-17`): `UltraBarKit` (library, no UI), `UltraWorkspaceApp` (SwiftUI executable) and `kitcheck` (executable, depends on the kit only). No test target. Next to the package: `android/DeckhandMonitor` (one Kotlin activity, eleven product flavors), `mock-corebar` (Node emulator of the bar), `api/` (OpenAPI + AsyncAPI mirrors of `PROTOCOL.md`), `packaging/` (app bundle, DMG, notarization) and `site/` (static site with `marketplace/registry.json`).

```
                    ┌────────────────────────────────────────────────────────────────┐
  macOS             │ UltraWorkspaceApp (SwiftUI, @MainActor)                        │
                    │                                                                │
                    │  UltraWorkspaceApp.swift ── @StateObject AppModel (app life)   │
                    │  ContentView.swift:7 ───── @StateObject AppSettings (window)   │
                    │        │ 22 model funcs take `settings:` as a parameter        │
                    │        ▼                                                       │
                    │  AppModel (338 lines, 63 @Published) + 13 extensions (~1.9k)   │
                    │   +Link +Pages +Themes +Doctor +Presence +Apps +Adb            │
                    │   +Screensaver +Weather +VivoWiFi +Claude +Music +Monitor      │
                    │        │ owns: BarPages (AppModel.swift:106), activeLink,      │
                    │        │       10 long-lived Tasks, presenceLog: Process       │
                    │        ▼                                                       │
                    │  BarPages (632 lines): 10 feed Tasks → [String: Any] dicts     │
                    │     route()/action() answer MonitorServer on its queue         │
                    │     + 11 pages of HTML/canvas-JS as Swift string literals      │
                    │  Widgets/ CardKit + 6 *Card renderers (RGBA for the cube)      │
                    │  Integrations/ AppleMusic, MacLocation, People; MacAudio       │
                    └───────┬───────────────┬──────────────────┬─────────────────────┘
                            │ CoreBarSession │ CoreBarLink       │ MonitorServer.shared :7432
                            │ (fresh TLS per │ (persistent,      │ MonitorBeacon UDP 5320 → bar
                            │  call)         │  heartbeat 3 s)   │
  UltraBarKit       ┌───────▼───────────────▼──────────────────▼─────────────────────┐
                    │ protocol: Proto, CoreBarClient (actor, TOFU), CoreBarSession,  │
                    │   CoreBarLink (actor), Discovery, DeployPackager, DeviceImage, │
                    │   ZipWriter, Store (tokens, pins, secrets), WireLog            │
                    │ servers: MonitorServer, PreviewServer, LocalIP                 │
                    │ feeds (not protocol): OpenMeteo, ClaudeUsage, NewsFeed,        │
                    │   LinearTasks, Flights, DailyVerse, SkyMath, SystemStats,      │
                    │   NetworkStats                                                 │
                    └───────┬────────────────────────────────────┬───────────────────┘
                            │ :5319 UDP, :7431 TLS, :8080 HTTP    │ adb :5555 (Process)
  CoreBar           ┌───────▼────────────────────────────────────▼───────────────────┐
  (Android)         │ launcher + hub; one APPS card per installed package            │
                    │ 11 × DeckhandMonitor flavor = WebView → http://mac:7432/<page> │
                    └────────────────────────────────────────────────────────────────┘
```

Two output paths exist for similar data. The cube path renders Swift `*Card` bitmaps through `CardKit.draw` (`Widgets/CardKit.swift:46-64`) and uploads an RGB565 package (`AppModel+Themes.swift:137-201`). The bar path serves a 1424×280 canvas page per app whose JavaScript polls `/<page>/data.json` (`BarPages.swift:327-356`), fed by Tasks that keep `[String: Any]` snapshots warm (`BarPages.swift:32-215`). Weather, crypto, calendar and Claude exist on both paths, with separate data shaping and separate drawing code.

## 2. What is sound and should be kept

The kit's protocol core is good and should stay as it is: `CoreBarClient` as an actor with the resume-once `ConnectOnce` box, TOFU pinning evaluated inside the TLS verify block, the ordered receive loop and bounded line buffer (`CoreBarClient.swift:12-174`); `CoreBarLink` with heartbeat-failure reconnect and backoff (`CoreBarLink.swift:62-111`); the pure encoders `DeviceImage`, `DeployPackager`, `ZipWriter` and the `ModuleWiFi` codec; `UploadReply` as a typed classification of the bar's reply text (`CoreBarSession.swift:418-449`); `savePages` refusing an empty list (`CoreBarSession.swift:619-624`).

`WireLog` with act-aware redaction, a 0600 file, rotation and the volume-traffic coalescing (`WireLog.swift:39-55, 86-102`) is the right diagnostic surface and the Logs page, Status report and the mock's capture directory all build on it.

`MonitorServer` is small, serves only closures, uses `Connection: close`, drops unfinished requests and gates actions on a custom header rather than CORS (`MonitorServer.swift:133-155`); `MonitorBeacon` sending both broadcast and unicast is a hardware-verified fix worth keeping (`MonitorServer.swift:166-194`).

`CardKit` as the one bitmap contract, with cards as pure `render(...) -> [UInt8]?` functions, is the correct seam for the cube and for the future `.deckhandtheme` renderer (`Widgets/CardKit.swift:5-9`). `CryptoStats.Gate` (`Widgets/CryptoStats.swift:43-83`) is the right shape for every keyless API: dedupe in-flight requests, space calls, return stale on failure. `MacAudio` answering `GET_VOLUME` from a CoreAudio cache off the main actor (`AppModel+Link.swift:29-40`, `MacAudio.swift:13-35`) is the model for every push reply.

In the UI, `StepProgress` + `ProgressRow`, `DoctorItem` with one `DoctorAction`, the `DeviceStrip` truth line, the per-view private `UI: ObservableObject` pattern and the shared `Header`/`Panel`/`EmptyState`/`LibraryRow` pieces are consistent and should not be touched by a refactor.

The flights/tasks feeds already have the right idea for interval keyed on page-open state: `lastHit` and a wake-up within 5 s (`BarPages.swift:116-143, 189-215`). The problem is only that it is implemented twice by hand instead of once.

## 3. Problems, ranked by cost of leaving versus cost of fixing

| # | Problem | Cost of leaving | Cost of fixing | Where |
|---|---|---|---|---|
| P1 | The eleven bar pages are 1424×280 HTML/JS inside Swift string literals; `wrap()` splices `JS` and `POLL` by `replacingOccurrences` | Every page change is a Swift rebuild with no editor support, no linting, no browser preview; the twelfth page will be pasted from the eleventh; the Teams page will be the largest yet | One evening: resources + `Bundle.module`, plus two lines in `make-app.sh` | `BarPages.swift:309-356, 357-631`; `AppModel+Monitor.swift:129-190` |
| P2 | Ten hand-written feed loops with the same shape (`while !Task.isCancelled { fetch; store dict; sleep }`), two of them with a bespoke page-open fast path, results typed as `[String: Any]` | A feed that needs auth state (Teams), a feed that must pause while the page is closed, or a second bar asking for the same data cannot be expressed; a mistake in one loop is invisible in the other nine | One evening for the scheduler, one for typed snapshots | `BarPages.swift:32-215` |
| P3 | `BarPages` and `AppModel` depend on each other: `AppModel` owns `barPages`, `BarPages` calls `model.resolveLocation`, `model.linearKey`, `model.linearError`, `model.say`, `model.musicPlayPause` | Nothing in `BarPages` can be built or tested without the whole app; the mutual dependency is the main reason it sits in the executable target | One evening: a `BarPageHost` protocol with five members | `AppModel.swift:106`; `BarPages.swift:42, 75, 120, 147, 192-212, 231-253` |
| P4 | `route()` answers the HTTP server from its socket queue with `DispatchQueue.main.sync` into a `@MainActor` class | A busy main actor (card render, publish) delays every bar page poll and, worse, a request arriving while the main actor awaits something that needs the server queue would deadlock; the design also forbids ever answering from a background actor | Half an evening once P2 gives feeds a thread-safe snapshot store | `BarPages.swift:264, 266` |
| P5 | The bar-app catalogue is written out five times: `BarPages.pages`, `AppModel.barAppPages`, `AppsView.barAppIcon`/`blurb`, `build.gradle.kts` flavors, `site/marketplace/registry.json`; the APK version lives in `barAppsVersion = "1.6"` and `versionName = "1.6"` separately | Adding the Teams app is five edits and one forgotten entry; a release can bundle APKs whose version does not match the string the app compares against (`barAppNeedsUpdate`) | One evening: one table in Swift plus a check in `make-dmg.sh` that reads the APKs | `BarPages.swift:13`; `AppModel+Monitor.swift:55-59, 70`; `AppsView.swift:8-29`; `android/.../app/build.gradle.kts:24-36` |
| P6 | Polling owned by views: `DeviceStrip` and `StatusView` each run a 30 s loop that opens five to ten TLS sessions; `runDoctor` repeats `refreshDeviceState`; nothing pauses during a publish | A nav switch starts a burst of handshakes concurrent with uploads and the link; the 2026-11-03 review already found mid-publish overwrites of `vivoLayerIndex` | One evening: one owner on `AppModel` with a visible-page refcount and a "paused while delivering" flag | `DeviceStrip.swift:36`; `StatusView.swift:47-52`; `AppModel+Doctor.swift:30-43, 132-235` |
| P7 | Two roots with different lifetimes: `AppModel` is created by the `App`, `AppSettings` by `ContentView`, and the settings object is captured by long-lived tasks (`BarPages.start`, cover refresh, Claude watch, presence) | Works today because there is one window; a second window, a menu-bar extra or a Settings scene would create a second `AppSettings` and the feeds would keep the old one | Half an evening: move the `@StateObject` one level up | `UltraWorkspaceApp.swift:5`; `ContentView.swift:7, 23-29` |
| P8 | Two secret policies and chatty persistence: `accuWeatherKey` in plaintext `settings.json`, `linearKey` in a 0600 Store file; `save()` on every `didSet` (per keystroke) | A Teams refresh token has nowhere typed to live; a user pasting a key rewrites the file per character | One evening | `AppSettings.swift:27, 211-230`; `AppModel.swift:97`; `Store.swift:143-153` |
| P9 | Profiles, widgets and module bindings are untyped `[String: Any]` built inline; the kit's `savePages` validates only `id` and `widget` | Every new card type is a dictionary literal; there is no fixture, so a key typo only shows on the glass | One evening for the types, one for a byte-equality fixture | `AppModel+Pages.swift:97-152, 185-226`; `CoreBarSession.swift:619-636` |
| P10 | `kitcheck/main.swift` is a 430-line top-level script that mixes a hardware CLI with assertions; nothing in the app target is testable; `FriendlyError` matches substrings (`"host"`, `"pin"`, `"auth"`) | Each refactor above has to be verified by hand on hardware; the previous review's false positives in `FriendlyError` are still there | One evening to add a test target and port the pure checks; Xcode is the selected toolchain now, so `swift test` works | `Sources/kitcheck/main.swift:195-431`; `Progress.swift:47-61` |
| P11 | The kit carries non-protocol code: eight data feeds, two HTTP servers, `Store`, and app policy such as the upload retry sleeps and `UploadDiag.shared` read from a view | Harmless for one client, but the kit is what `COLLAB.md` offers to the Windows author and what the mock and specs mirror; the feeds and the retry policy are not part of that contract | Cheap to leave; one evening to split targets when the test target exists | `CoreBarSession.swift:459-492, 688-694`; `WidgetsView.swift:72`; `OpenMeteo.swift:82` logs to `WireLog` |
| P12 | Single-bar assumptions: one `selectedSerial`, one `activeLink`, one `modules` list, beacon unicast to `ipForSelected()` only, one `MonitorServer` port, presence for one bar | A second bar is on the roadmap; today it would mean duplicating the model | Not fixable in an evening; the plan below creates the seam without doing the work | `AppModel.swift:11, 14, 60`; `AppModel+Monitor.swift:42-45`; `AppModel+Presence.swift:14-62` |
| P13 | Eleven Android flavors of one activity | Eleven APK installs over ADB per release (`updateBarApps` installs them serially); icons and manifests per flavor | Leave: the bar's launcher shows one card per installed package, so one app with a page chooser would collapse to one card, which the whole design exists to avoid | `android/.../build.gradle.kts:21-45`; `AppModel+Pages.swift:138-143` |

Lower-cost items noted but not ranked: `AdbBridge` lives in `AppModel+Presence.swift:75-159` although Apps, Doctor and Themes use it; `WeatherCard`'s wide 1424×280 layout (`Widgets/WeatherCard.swift:41-48`) is only reached from `WeatherPreview`, the bar page draws its own; `NewsFeed` sends `Deckhand/1.3` and `MapTiles` `Deckhand/0.2` as User-Agent (`NewsFeed.swift:31`, `MapTiles.swift:30`), neither read from `Info.plist`; `MapTiles.tile` blocks the server's connection queue on a semaphore for up to 9 s (`MapTiles.swift:31-38`); `selectFirstLayerAfterSettle` is still an untracked Task (`AppModel+Themes.swift:255-260`); `sendToCube` is not gated by `isWorking` while publish and Wi-Fi writes are (`AppModel+Themes.swift:19-33` versus `AppModel+Pages.swift:74-75`).

## 4. Assessment by topic

### Module boundaries

The kit knows nothing about the app, which is right. The app knows a lot about the protocol that it should not: module type strings in `SidebarView.swift:16-25` and `ContentView.swift:68-73`, the launcher package and activity names in `AppModel+Doctor.swift:103-104`, profile JSON keys throughout `AppModel+Pages.swift`. The reverse leak is the kit carrying feeds and policy (P11). The clean cut is three layers, not two: `UltraBarKit` (protocol, encoders, store, wire log), a `DeckhandCore` library (feeds, catalogue, typed profiles, `FriendlyError`, settings model, page data shaping, nothing that imports SwiftUI) and the SwiftUI executable. The plan below reaches that without a rewrite by moving files only after they have no `AppModel` dependency.

### AppModel

63 `@Published` properties and ~1.9k lines across 14 files is less a size problem than an ownership one: state for the link, the cube delivery, the page publish, the app store, ADB, presence, the monitor and Linear all live in one object, and the only reason is that extensions cannot add stored properties. The 2026-11-03 target (`CubePublisher`, `PagePublisher`, `LinkService`, `DeviceWatcher`, `Diagnostics`) still holds. The cheapest first steps are the ones that cut a dependency rather than move code: `BarPages` out (P3), one polling owner (P6), the link's five properties into one `BarLink` object (P12 seam).

### Concurrency

The actor split is sound: `CoreBarClient` and `CoreBarLink` are actors, `AppModel` and `BarPages` are `@MainActor`, the push handler answers volume off the main actor. The remaining issues are structural rather than data races. `MonitorServer.Route` is a synchronous `@Sendable` closure called on the connection's queue (`MonitorServer.swift:24, 148-149`), which is why `BarPages.route` must `DispatchQueue.main.sync` (P4); the fix is a thread-safe snapshot store, not an async route. `startLink` still stops the old link in a fire-and-forget Task and immediately starts a new one (`AppModel+Link.swift:15-19, 48-51`); the enum state helped, a generation counter is still missing. `BarPages.stop()` cancels its Tasks but the loops `try? await Task.sleep` and then run one more iteration before checking (`BarPages.swift:53-56`), so a feed can write a snapshot after `stop()`; harmless but it means `start()` after `stop()` briefly has two writers. The `[weak self]` plus `guard let self` inside the loops keeps a captured `self` alive for the duration of each iteration, which is fine. Long sleeps are everywhere written as `try? await Task.sleep` without a cancellation check after them; `uploadPackage` is the one place that checks (`AppModel+Themes.swift:184`).

### BarPages

Three separable things are in one file: feeds (data), routing (HTTP) and pages (markup). Pages should be resources (P1); the shell `wrap()` already is one template, so the eleven JS files can share it unchanged, and the shared helpers (`txt`, `rr`, `clip`, `ago`, `act`, `poll`) move with it. Feeds should be one abstraction (P2): a feed has an id, an idle interval, an open interval, and an async function that returns a typed snapshot; the scheduler owns the loop, the `lastHit` logic and the wake-up. Routing then becomes a table from page id to snapshot plus the three special routes (`art.jpg`, tiles, actions). The monitor page is the odd one out, living in `AppModel+Monitor.swift:129-190` with its stats route built in `startMonitor`; it should become the twelfth entry of the same table.

### Settings and persistence

`AppSettings` is one flat `Persisted` struct with retired fields kept for decoding (`AppSettings.swift:90-130`), which is a reasonable migration strategy. The problems are lifetime (P7), per-keystroke writes and the split secret policy (P8). `Store` is fine as a 0600 file store; what it lacks is a typed secret (a Codable blob per name) so a token with expiry and refresh can live there. `Store.shared` is read directly from a view (`VivoCubeView.swift:211, 226`); that should go through the model.

### Widget pipeline versus bar pages

The cube cards and the bar pages are two render paths by necessity: the cube takes a 240×240 bitmap every five minutes, the bar takes a live web page. What should not be duplicated is the data shaping. Today `renderTheme` and the crypto feed both fetch and shape `CryptoStats` (`AppModel+Themes.swift:301-306` versus `BarPages.swift:58-70`), the calendar card and the calendar feed both call `CalendarSource.upcoming` with different limits and windows, and the Claude card and the Claude feed both call `ClaudeUsage.snapshot()`. With typed feed snapshots (P2) the cube renderer can take the same snapshot the page serves, which also removes the second scheduler (the cube's 5-minute refresh) from the picture: a card renders from whatever the feed has. `WIDGETS.md`'s decision for web/TypeScript widgets rendered headlessly to an image is consistent with this: the bar pages are already web pages, and the same JS could render the cube card through an offscreen `WKWebView` snapshot later.

### Error handling and user-facing surfaces

There are six surfaces: `say()` (status line plus Activity list), `StepProgress.failure` (inline under Send/Publish), `DoctorItem` (Status page), per-feature strings (`appStoreError`, `barAppError`, `linearError`, `monitorError`, `presenceStatus`), the bar pages' own "Waiting for the Mac…" and `error` fields, and `WireLog`. That is acceptable for a device app, and `FriendlyError` centralises the wording. Two gaps: most feeds swallow failures with `try?` and keep the last snapshot silently (`BarPages.swift:75-77, 122, 182`), so a page can show hours-old weather with no indication; and `FriendlyError.text` is substring matching on `localizedDescription` (`Progress.swift:50-60`), so the kit's own message "its module hotspot has no IP address" contains "host" and maps to the wrong sentence. A typed `UltraBarError` to text table and an `at`/`stale` field in every feed snapshot fix both.

### Testability

`kitcheck` is valuable as a hardware and mock CLI and should stay for that. As a test runner it has three weaknesses: assertions are top-level code that runs after a chain of `if CommandLine.arguments` branches, a failing check does not name a file or line, and nothing from the app target is reachable. Xcode is now the selected developer directory (`xcode-select -p` → `/Applications/Xcode.app`), so a `.testTarget` with Swift Testing works and the CLT also ships `Testing.framework`. What a test target gains immediately: the pure checks in `kitcheck/main.swift:201-375` as named tests; `UploadReply`, `Discovery.parse`, `WireLog.redact` already have fixtures there. What it gains after the plan: `FriendlyError` mapping, `BarAppCatalog` consistency, feed snapshot shaping, typed profile encoding against a recorded wire-log fixture, settings migration. The missing seams are exactly the ones in P2, P3, P5 and P9.

### Android

One activity, eleven flavors, is the right call for this launcher: the bar lists one APPS card per installed package (`CoreBarSession.listApps`, `AppModel+Pages.swift:138-143`), so one app with a chooser would lose the per-page cards. `MainActivity.kt` is careful (private-LAN URL check, host pinning in `shouldOverrideUrlLoading`, beacon socket ownership). The update burden is real but mechanical: eleven `adb install -r` of ~1 MB APKs, already serialised and version-gated by `barAppNeedsUpdate`. The burden to cut is the catalogue duplication (P5) and the manual version string, not the flavor count. One Kotlin improvement worth an hour: read `PAGE` from the beacon's `base` plus `BuildConfig.PAGE` is fine, but the Deckhand side could serve `/apps.json` so the bar app can show "Deckhand 0.2 at 192.168.x.y" on its waiting page instead of a bare "Looking for Deckhand…".

### Release and distribution

`make-app.sh` copies whatever APKs are in `dist/bar-apps` into the bundle (`packaging/make-app.sh:24`), and nothing builds them; a release can ship stale APKs with `barAppsVersion` claiming otherwise. `make-dmg.sh` handles signing and notarization honestly. The marketplace registry marks every entry `"distribution": "bundled"`; `performInstallBarApp` can only install a bundled APK (`AppModel+Monitor.swift:89-108`), so third-party entries would need a download-verify-install path that does not exist yet. The vendor marketplace path (`BarAppStore` + act 30600) is separate and complete.

## 5. A sequenced plan of evening-sized refactors

Each step compiles and ships on its own; none depends on a rewrite. Order matters only within the first four.

### Evening 1: pages become resources

Create `Sources/UltraWorkspaceApp/Resources/pages/shell.html` (the body of `wrap()` with `{{TITLE}}`, `{{JS}}`, `{{POLL}}` placeholders) and `monitor.html`, then one file per page `claude.js`, `crypto.js`, `weather.js`, `music.js`, `calendar.js`, `flights.js`, `sky.js`, `news.js`, `verse.js`, `tasks.js` with the literal contents of `BarPages.claudeJS` … `tasksJS` (`BarPages.swift:357-631`) and `AppModel.monitorPage` (`AppModel+Monitor.swift:129-190`). Add `resources: [.copy("Resources")]` to the `UltraWorkspaceApp` target in `Package.swift`. Replace `BarPages.html(_:)` and `wrap(_:_:)` with a loader that reads `Bundle.module.url(forResource:subdirectory:)` once per page and caches the string; keep the `POLL` constant at the top of each JS file as today. In `packaging/make-app.sh`, after copying the binary, copy `.build/$CONF/UltraWorkspaceMac_UltraWorkspaceApp.bundle` into `Contents/Resources/` (SwiftPM's `Bundle.module` looks there in an app bundle). Verify: before the change, `curl -s http://127.0.0.1:7432/weather > /tmp/weather-before.html` for all eleven pages; after, diff each (byte-identical is achievable since `wrap()` is a template), then open one page in Safari at 1424×280 and confirm the poll works from `dist/Deckhand.app` as well as from `swift run`.

### Evening 2: one feed abstraction

In `BarPages.swift` add `struct Feed { let id: String; let idle: TimeInterval; let open: TimeInterval; let run: @Sendable () async -> [String: Any]? }` and a single `schedule(_ feeds: [Feed])` that owns one Task per feed with the loop from `BarPages.swift:116-143` generalised: sleep in 5 s slices, recompute `open` from `lastHit[id]` each slice, break early when the page was just opened. Rewrite the ten loops as ten `Feed` values; `verse` keeps its "same reference, skip fetch" guard inside `run`. Every snapshot gets `"at": Int(Date().timeIntervalSince1970)` and, on a failed `run`, the previous snapshot is kept but `"stale": true` is set, so a page can draw "updated 2 h ago" instead of nothing. Verify: `curl` each `data.json` and check `at` advances at the expected cadence; open the flights page on the bar (or `curl` it every 2 s) and confirm `at` moves to 10 s intervals and back to 2 min within a minute of stopping; CPU in Activity Monitor unchanged.

### Evening 3: a thread-safe snapshot store, no more `DispatchQueue.main.sync`

Add `final class PageSnapshots: @unchecked Sendable` with an `NSLock`, `set(_ page: String, _ dict: [String: Any])`, `get(_ page:) -> [String: Any]`, `touch(_ page:)` and `lastHit(_ page:) -> Date?`; the art JPEG goes in the same box. Feeds write through it; `route()` reads from it without touching the main actor (`BarPages.swift:264, 266`). `action()` keeps `DispatchQueue.main.async` since it invokes model methods. Verify: the kitcheck `MonitorServer` checks still pass; hammer `data.json` with `ab -n 2000 -c 20` while Send to cube renders, and the request latency stays in milliseconds (today it waits for the main actor).

### Evening 4: cut `BarPages` loose from `AppModel`

Define `protocol BarPageHost: AnyObject { func resolveLocation() async throws -> (lat: Double, lon: Double, name: String); var nowPlaying: AppleMusic.NowPlaying { get }; var linearKey: String { get }; func reportLinear(error: String?); func note(_ s: String); func music(_ cmd: String) }` and make `AppModel` conform in a five-line extension. `BarPages.start(host:settings:)` stores the host weakly; all `model.` uses in `BarPages.swift:42-253` go through it. `AppModel.monitorPackage`, `barAppPages`, `bundledAPK` stay where they are for now. Verify: `BarPages.swift` has no `AppModel` reference (`grep -c AppModel Sources/UltraWorkspaceApp/BarPages.swift` returns one, the `monitorPage` line, which Evening 1 already removed); build; bar pages still answer; Tasks "Done" from the bar still marks the issue done and shows in Activity.

### Evening 5: one bar-app catalogue, checked at release time

Create `Sources/UltraWorkspaceApp/BarAppCatalog.swift` with `struct BarApp { let page, label, apk, symbol, blurb: String }` and `static let all: [BarApp]` holding the rows from `AppModel.barAppPages`, `AppsView.barAppIcon`, `AppsView.blurb`; derive `BarPages.pages` and `package(for:)` from it. Read the shipped APK version at runtime instead of `barAppsVersion`: `make-app.sh` writes `Contents/Resources/bar-apps/VERSION` from `aapt dump badging` (or `unzip -p … AndroidManifest.xml` is binary, so `aapt` from build-tools), and `AppModel+Monitor.swift:70` reads that file with `"1.6"` as the fallback. In `make-dmg.sh`, abort when any APK in `dist/bar-apps` is missing or its `versionName` differs from the others. Add a `kitcheck catalog` command that parses `android/DeckhandMonitor/app/build.gradle.kts` for `Triple("…"` lines and `site/marketplace/registry.json` for `"id"` and fails on any id missing from either; wire it into `make-dmg.sh`. Verify: delete one flavor line locally and watch the check fail; restore it.

### Evening 6: settings lifetime, debounced saves, one secret policy

Move `@StateObject private var settings = AppSettings()` from `ContentView.swift:7` to `UltraWorkspaceApp.swift` next to `model`, and inject it with `.environmentObject(settings)` there; `ContentView.onAppear` keeps calling the `start…` functions. In `AppSettings.save()` replace the direct write with a 300 ms debounce (one `Task` that sleeps and writes, cancelled on the next `didSet`), plus an explicit `flush()` called from `applicationWillTerminate` via an `NSApplicationDelegateAdaptor`. Move `accuWeatherKey` to `Store.shared.saveSecret(_:name: "accuweather")` the way `linearKey` is stored (`AppModel.swift:97`), migrating a non-empty value from `settings.json` on first load and blanking it there. Verify: type into the AccuWeather field and watch `settings.json` mtime with `stat` (one write, not one per keystroke); quit and relaunch, the key is still present and `settings.json` no longer contains it.

### Evening 7: one polling owner

Add to `AppModel` a `deviceWatchers = 0` refcount, `startDeviceWatch()`/`stopDeviceWatch()` that create or cancel a single 30 s loop calling `refreshDeviceState()` only when `!cubeProgress.isRunning && !pageProgress.isRunning`, and make `DeviceStrip.swift:36` and `StatusView.swift:47-52` call those from `onAppear`/`onDisappear` instead of owning `.task` loops. `runDoctor` (`AppModel+Doctor.swift:132`) stops calling `refreshDeviceState()` itself and reads the last twin values. Verify: open the VivoCube page, then Status, and count `connected … (TLS)` lines per 30 s in `wire.log` before and after (today it is roughly ten, after it should be five); start Send to cube and confirm no property reads appear in the log until the progress row finishes.

### Evening 8: a test target, kitcheck keeps the hardware commands

Add `.testTarget(name: "UltraBarKitTests", dependencies: ["UltraBarKit"])` with Swift Testing and port the pure checks from `Sources/kitcheck/main.swift:201-375` one block per file: `UploadReplyTests`, `WiFiCodecTests`, `RedactionTests`, `DiscoveryParseTests`, `PackagerTests`, `SkyMathTests`, `NewsFeedTests`, `MonitorServerTests` (the loopback server test, with `requestTimeout` made an instance property so the test does not mutate a static). Leave `kitcheck` with `discover`, `e2e`, `linkwatch`, `raw`, `apps`, `modules` and the new `catalog`. Add the first app-layer test the moment Evening 4 is done: `FriendlyErrorTests` asserting that `UltraBarError.uploadRejected("… module hotspot has no IP address …")` does not map to the "could not reach the bar" sentence (it does today, `Progress.swift:58`); fixing that means `FriendlyError.text(_ error: Error)` switches on `UltraBarError` cases first and falls back to substrings only for foreign errors. Verify: `swift test` green; `swift run kitcheck` still prints `ALL CHECKS PASSED` for whatever remains there.

### Evening 9: typed profiles in the kit, with a recorded fixture

Add `Profile`, `Widget` and `ModuleBinding` as `Codable` structs in `Sources/UltraBarKit/Profiles.swift` mirroring the keys used in `AppModel+Pages.swift:97-152, 185-226` (`id`, `name`, `isDefault`, `showName`, `iconScale`, `icon`, `module`, `widget`; widget `id`, `type`, `name`, `icon`, `iconScale`, `param` as `[String: AnyCodable]` or a small enum of the five param shapes). Add `CoreBarSession.savePages(_ profiles: [Profile])` that encodes with sorted keys and calls the existing dictionary overload. Before switching `publishDeckhandPage`, copy the current 1108 frame from `wire.log` into `Tests/UltraBarKitTests/Fixtures/batch-save-profile.json`; the test encodes the same page through the new types and compares key-sorted JSON. Then move `moduleBindings()` and the card-to-widget switch into a `DeckhandPage.build(cards:modules:senseSerial:coords:)` pure function. Verify: the fixture test; publish once on hardware and confirm the wire-log frame is unchanged except key order.

### Evening 10: a `DeckhandCore` library target

Create the target with no SwiftUI import and move, in this order, files that now have no `AppModel` dependency: `Progress.swift` (`StepProgress`, `FriendlyError`), `Theme.swift`, `BarAppCatalog.swift`, `BarPages.swift` with its `PageSnapshots` and `Feed`, `Widgets/CryptoStats.swift`, `Widgets/CalendarSource.swift`, `MapTiles.swift`, the `DeckhandPage` builder, and the `AppSettings.Persisted` struct as `SettingsModel` with its migration (`AppSettings.swift:90-130, 170-213`) while `AppSettings` stays in the app as the `ObservableObject` wrapper. The `UltraWorkspaceApp` target depends on both libraries. Add `DeckhandCoreTests` for the settings migration (a `settings.json` from before 2026-11-03 decodes and maps `enabledThemes` to `vivoThemes`) and for `BarPages.linearDict` and the calendar day shaping. Verify: `swift build`, `swift test`, and the app behaves the same; `grep -l SwiftUI Sources/DeckhandCore` is empty.

### Evening 11: the per-bar seam

Group the link state into `@MainActor final class BarLink: ObservableObject` holding `link`, `pushCount`, `lastPushAt`, `lastVolumePushAt`, `lastKnobVolume`, `activeLink` and a `generation` counter; `startLink()` increments the generation and `onState` callbacks from an older generation are dropped (`AppModel+Link.swift:20-26`). `AppModel` exposes `links: [String: BarLink]` keyed by serial and `var link: CoreBarLink.State { links[selectedSerial]?.link ?? .stopped }` so no view changes. `MonitorBeacon.send` loops over every paired bar's IP (`AppModel+Monitor.swift:42-45`). Verify: pair the mock as a second bar, switch between the two in the sidebar and watch the badge; the Status page's "Reconnect" no longer produces a transient "Not connected" on a healthy link.

### Evening 12: feed auth state, ahead of the Teams app

Extend `Feed` with `enum Auth { case none, needsSignIn(instructions: String, code: String?), signedIn(as: String), expired }` surfaced as `"auth"` in the snapshot, and add to `Store` a `saveSecret<T: Codable>(_ value: T, name:)` / `loadSecret(name:) -> T?` pair so a Graph token with refresh token and expiry can be stored next to the Linear key. The device-code flow from `docs/TEAMS-APP-RESEARCH.md` then becomes a `Feed` whose `run` returns `needsSignIn` until the token exists, and the page's JS draws the code. Verify: a fake feed that returns `needsSignIn` renders the instruction text on the shell page; the real tier-1 Teams page (EventKit meetings, no sign-in) can ship before any Graph code.

## 6. Roadmap items and what they will stress

Marketplace installs of third-party bar apps need `performInstallBarApp` to take a source (`.bundled(name)` or `.download(url, sha256)`) and a verify step before `adb install`; with the catalogue in one place (Evening 5) that is a second `BarApp.distribution` field, and `registry.json` already carries the shape. Until a download path exists, the registry should say "bundled with Deckhand" rather than "install through Deckhand" for entries that are not.

The Teams app needs a feed with auth state, a Codable secret and a page that can display sign-in instructions (Evening 12); none of the ten current feeds has any of those, which is why it should not be written as the eleventh copy of the loop.

More pages are the cheapest after Evenings 1, 2 and 5: a JS file, a `Feed` value, one catalogue row, one flavor line, one registry entry, and the catalog check tells you if one is missing.

A second bar needs per-bar link, modules, pages and beacon targets (Evening 11 starts it) and later per-bar `AppSettings` card lists, which the `Persisted` struct does not model yet; that is the one place where a schema change is unavoidable and should be planned, not improvised.

The web/TypeScript widget runtime from `WIDGETS.md` is well served by Evening 1 (pages as files) and Evening 2 (typed data snapshots): a community widget is then a JS file plus a declared feed id, and the cube can later get the same page snapshotted through an offscreen web view.

## 7. What not to do

Do not split `AppModel` by renaming extensions or by adding more `@Published` flags; cut dependencies (Evenings 4, 7, 11) and the object shrinks on its own. Do not merge the eleven Android flavors into one app; the launcher's one-card-per-package model is the reason they exist. Do not move the feeds into actors to solve P4; a locked snapshot box is enough and keeps `route()` synchronous. Do not replace `kitcheck` with tests; keep it for hardware and the mock, and let the test target take only the pure checks. Do not start the `DeckhandCore` target before Evening 4; a library that still needs `AppModel` cannot be created.
