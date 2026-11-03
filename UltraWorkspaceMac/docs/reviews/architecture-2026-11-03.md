# Deckhand — architecture review (2026-11-03)

Read-only review by the architect agent at commit `8bcd6b0`. Line numbers are file lines at that commit. Note: `Package.swift` declares `swift-tools-version: 6.0` with no `swiftLanguageVersions` and the toolchain is Swift 6.4.2 (CLT), so the app compiles in **Swift 6 language mode with strict concurrency** — that is why there are 11 `@unchecked Sendable` boxes and `Task { @MainActor in }` hops. The compiler already enforces actor isolation; the remaining races are logical, not data races.

## Executive summary

1. **The pairing token is written in cleartext to `wire.log` on every connection.** `WireLog.redact` only masks a `"token":` key (`WireLog.swift:63`), but the AUTH frame is `{"act":100,"data":"<token>"}` (`CoreBarClient.swift:269-274`). The user's `wire.log` is 16.5 MB, unbounded, and contains the token thousands of times, the VivoCube Wi-Fi password hex (property 7, `CoreBarSession.swift:313,325`) and the AccuWeather key (act 1010). README/MANUAL/SECURITY.md all claim "token redacted". Fix before any public release.
2. **`AppModel` is a 1,500-line god object with ~55 published properties and no model of what the device is doing.** "What the cube shows" exists as seven independent variables (`vivoLayerIndex`, `themeIndex`, `vivoLayerShowing`, `vivoWidgetShowing`, `vivoLayerNames`, `lastPublishedVivoLayers`, `settings.vivoLayerCount`) plus a global string prefix (`UploadDiag.shared.last.hasPrefix("accepted")`). The UI rewrite exposed this state honestly on screen; the regressions are those variables disagreeing. There is a missing type (`CubeTwin` + `Delivery` state), not a bug to patch.
3. **Long-running device work is owned by views and by a struct that reconnects per call.** `DeviceStrip.task` and `StatusView.task` each run 30 s polling loops; every `CoreBarSession` call opens a new TLS handshake, so one `refreshDeviceState()` is 5 handshakes and the Status page 10+ per 30 s, concurrent with the persistent link and uploads. The push handler runs `osascript` synchronously on the main actor (`AppModel+Link.swift:58,153-169`), blocking the UI every 5 s while the Deckhand page is on the bar.
4. **Nothing above `UltraBarKit` is testable** because app-layer logic (package rendering, delivery states, `FriendlyError`, settings migration, profile JSON) lives in the executable target. `kitcheck` has the right shape (`check()` + mock e2e). Move the logic into a `DeckhandCore` library and add `kitcheck unit`; no XCTest needed (the CLT ships neither XCTest nor Swift Testing).
5. **UI fragility is structural**: `List` inside `ScrollView` with hand-computed heights (`VivoCubeView.swift:113`, `CoreBarPageView.swift:144`), an `HStack(detail, activity)` substitute for an inspector, stringly-typed link state compared in five views, and `deviceFault(settings:)` policy evaluated inside `body`. Each regression this week came from one of these.

## Current state

```
UltraWorkspaceApp (SwiftUI, executable)
  UltraWorkspaceApp.swift  @StateObject AppModel (lives for the app)
  ContentView.swift:7      @StateObject AppSettings (lives for the window)   <-- second root; passed into 22 model funcs
      |
  AppModel (@MainActor, 407 lines) + extensions: +Link 177, +Themes 335, +Pages 272, +Doctor 221, +VivoWiFi 38, +Music 78, +Weather 86
      ~55 @Published vars; long-lived Tasks: themeTask, coverRefreshTask, musicPollTask, weatherTask, link
      | session(for:) -> NEW CoreBarSession per call | CoreBarLink (actor, persistent) | views also read CoreBarSession.UploadDiag.shared
UltraBarKit (library)
  Models (Proto, CoreBar, AttachedModule, UltraBarError), CoreBarClient (actor, TLS, TOFU) -> WireLog (FULL frames),
  CoreBarSession (struct: authedClient() per call; retries + provision policy; UploadDiag.shared),
  CoreBarLink (actor), Discovery, Store, WireLog (16 MB file), DeviceImage/DeployPackager/ZipWriter (pure),
  PreviewServer, OpenMeteo/SystemStats/NetworkStats/ClaudeUsage (not protocol!)
kitcheck: unit-ish checks on DeviceImage/DeployPackager; e2e vs mock-corebar; linkwatch/readprop/cubewifi
mock-corebar (Node/TS)
```

"Send to cube": `VivoCubeView` → `AppModel.sendToCube(settings:)` → `uploadPackage` (render on main actor with `Task.sleep(900ms)` per stat card) → `session.upload` (up to ~1 min of blind retries) → sleep 10 s → `readProperty(wifi)` → `showCubeCard(1)` → timed loop with a local `step` counter. Meanwhile `DeviceStrip.task` → `refreshDeviceState()` rewrites `vivoLayerIndex`/`currentThemeLabel`, and a DotKey push → `stepVivoLayer` rewrites `vivoLayerIndex` using a count re-read from `settings.json` on disk.

## Findings (by impact)

### F1 — Secrets in wire.log (HIGH)
- `CoreBarClient.swift:224-228` logs every outbound frame; the AUTH frame carries the token as `data`; `WireLog.swift:61-67` redacts only `"token":`.
- Property-7 writes/reads log `hex(len+ssid+len+password)`; act 1010 logs the AccuWeather key; `AppSettings` stores that key in plaintext `settings.json`.
- `WireLog` appends forever; Logs view offers "Copy"/"Reveal in Finder" and the Status report pastes the last 30 lines — the user is encouraged to share it.
- Fix: redaction by act in `CoreBarClient.send` (act 100 → mask `data`; 30200/30201 with propertyId 7 → mask `value`/`result`; 1010 → mask `apiKey`) before the string reaches `WireLog`; size cap/rotation; correct the docs; key to Keychain or a 0600 file.

### F2 — No single source of truth for the cube (HIGH)
- "What the cube shows": `vivoLayerShowing` (device-reported, but also assumed after a write), `vivoLayerIndex` (intent, written in 5 places), `themeIndex` (read nowhere useful), the timed loop's local `step` (ignores DotKey/◀▶ steps), and `VivoCubeView.swift:47` fallback.
- "How many cards": `vivoLayerNames.count`, `lastPublishedVivoLayers`, `settings.vivoLayerCount`, `UserDefaultsLayerCount.read()` (re-parses settings.json because the Link extension cannot see `AppSettings`). `stepVivoLayer` uses `max(...)` → DotKey can point at a layer not in the package = black screen, which Doctor then reports as a fault.
- "Sent / delivered": `lastCubeSentAt` means accepted by the bar, not delivered; `UploadDiag.shared.last` is a string with a baked-in timestamp parsed with `hasPrefix("accepted")`/`contains("error:4")`; any single-layer upload (`sendPanelSizeTest`, `pushNowPlaying`, `publishAddon`, `chooseAndUploadImage`) replaces the cube package without touching `vivoLayerNames`/`vivoLayerImages`. `cubePackageStale` conflates "sent while offline" with "went offline after a good send".
- "Is connected": `linkState: String` compared as `== "Live link"` in five places; `CoreBarLink.State` is already an enum.
- "What is selected": `selectedSerial`, `selectedModuleSerial`, `nav`, `selectedAddon`, `settings.vivoCards` (intent) vs `vivoLayerNames` (last sent); the "now" pill compares an index into one against the other.

### F3 — Concurrency (HIGH)
- Link restart race: `startLink()` → `stopLink()` fires `Task { await l.stop() }` and immediately creates a new link; the old link's `.stopped` can land after the new link's "Live link" → "Not connected" shown while connected; Doctor offers Reconnect, which restarts again.
- Main-thread blocking: `handlePush` is `@MainActor`; GET_VOLUME/SET_VOLUME/mute call `osascript` via `Process` + `waitUntilExit`; the bar polls every 5 s. `CoreBarLink.readLoop` awaits the handler inline.
- Polling owned by views: `DeviceStrip` is embedded in two pages; each mount starts a loop and fires immediately → every nav switch triggers 5 TLS sessions. `StatusView.task` runs `runDoctor` every 30 s which calls `refreshDeviceState()` and `listPages()` again. `refreshDeviceState` runs concurrently with `sendToCube` and overwrites `vivoLayerIndex`/`currentThemeLabel` mid-publish.
- Upload retries uncancellable: `CoreBarSession.upload` sleeps 6 s×3 + 10 s×3 + 14 s + 1.5 s with `try? await Task.sleep` and no cancellation checks; `themeTask?.cancel()` does nothing for up to ~70 s; a second Send starts a parallel upload. `isWorking` does not gate `sendToCube`, so cube and page uploads interleave.
- `selectFirstLayerAfterSettle` spawns an untracked Task writing property 9 ten seconds later.
- Long-lived loops capture the `AppSettings` owned by `ContentView` while `AppModel` is owned by the App.
- Resume-on-launch uploads to hardware with no user action, before the twin was read.
- `AppSettings.save()` `saving` guard never set; `vivoSwitchMode` migration is a no-op ternary.

### F4 — Module boundaries (MEDIUM)
- `UltraBarKit` carries app policy and non-protocol code: `UploadDiag.shared`, upload retry/provision policy with hard-coded sleeps, `WireLog` singleton, `Store`, `OpenMeteo`, `SystemStats`, `NetworkStats`, `ClaudeUsage`, `PreviewServer`. Hotspot SSID/password live in the app and kitcheck.
- The app leaks protocol: module type strings in `SidebarView`/`ContentView`/`CoreBarPageView`; Wi-Fi state `== 3` in views; widget id `101` in six places; `ProfileDTO` as untyped `[String: Any]`; `CoreBarSession.UploadDiag` read from a view.
- Keep: `CoreBarClient` (once-only continuation, TOFU), `CoreBarLink` actor, `DeviceImage`/`DeployPackager`/`ZipWriter`, `Models.Proto`, `savePages` guards.

### F5 — Testability (MEDIUM)
- `uploadPackage`/`renderTheme`, `StepProgress`, `FriendlyError`, `AppSettings` migration, `moduleBindings()`/profile JSON, `deviceFault`, `handlePush` are unreachable from `kitcheck`.
- `FriendlyError.text` substring matching has live false positives: the kit's own "its module **hotspot** has no IP address" matches `"host"` and reports "Could not reach the bar at its last address"; `"auth"` matches "author", `"pin"` matches "pinned"/"mapping". A typed error → message table would be a 20-line unit test.

### F6 — UI architecture (MEDIUM)
- `List` inside `ScrollView` sized by `rows*28 + 10` (+60 when the key field is open): wrong under Larger Text, multi-line rows, any future per-row control; `List` fights the outer `ScrollView` and reports its own minimum size — same family as the `LazyVStack` and the `fixedSize` incidents.
- `HStack(DetailRouter, Divider, ActivityLog.frame(width: 280))` + `safeAreaInset(.bottom)`: the activity column participates in the detail's minimum-size negotiation; `.inspector` is macOS 14.
- `deviceFault(settings:)` builds `DoctorAction` closures inside `body` on every render.
- Sheet booleans and navigation live on the model, so protocol code can push UI.
- Per-view `UI: ObservableObject`, `Header`/`Panel`/`EmptyState`/`ProgressRow` are sound and should stay.

### F7 — Persistence & security (LOW–MEDIUM)
- Token files 0600 are acceptable for a Developer-ID app; move to Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) behind a `TokenStore` protocol once notarized.
- `AppSettings` writes `settings.json` on every didSet (per keystroke, per drag step).
- Entitlements correct for notarization. `codesign --deep` is deprecated; sign nested items explicitly when there are any. `AppleShowScrollBars` per-app default: document it.

### F8 — Roadmap fit
- `POST /notify` / `POST /image` and HA need a command API that is not the UI: `CubePublisher.show(package:)` / `interrupt(with:for:)` owning the delivery state machine.
- `.deckhandtheme` packages need rendering as a pure function `(ThemeSpec, DataSnapshot) -> RGBA` in a library target; today `renderTheme` is a `@MainActor` method on `AppModel` with side effects, network calls and 900 ms sleeps.
- Both need typed `Profile`/`Widget`/`ModuleBinding` structs.

## Target architecture

```
UltraBarKit      protocol only: Proto, CoreBarClient, CoreBarLink, CoreBarSession (thin, no retry policy, no UploadDiag),
                 Discovery, Profile/Widget/ModuleBinding Codable, ModuleWiFi codec, DeviceImage/DeployPackager/ZipWriter,
                 WireLog (act-aware redaction, injectable sink)
DeckhandCore     app domain, no SwiftUI: DeviceTwin, Delivery, CubePublisher, PagePublisher, LinkService, DeviceWatcher,
                 Diagnostics, CardRenderer, ThemeSpec, Settings (Codable + migrations), FriendlyError (typed),
                 MacServices protocols (Volume, Music, Weather, Location, Stats)
UltraWorkspaceApp SwiftUI only: AppModel = thin façade (nav, sheets) over DeckhandCore stores
kitcheck         `kitcheck unit` (pure logic), `kitcheck e2e` (mock), tools
```

```swift
struct CubeTwin: Equatable {
    struct Package: Equatable { let id: UUID; let cards: [CardID]; let previews: [Int: ImageRef]; let sentAt: Date }
    var reported: Reported?      // last device read: layer, widget, screenOn, wifiState, readAt
    var lastPackage: Package?    // what we believe is on the glass (nil until a send is .applied)
    var delivery: Delivery
    var intent: Intent           // .stay(layer) | .timed(interval, next: Date) | .button
    var showing: Int? { ... }    // derived
    var fault: Fault? { ... }    // derived, pure; replaces deviceFault(settings:)
}
enum Delivery: Equatable {
    case idle
    case rendering(progress: StepProgress)
    case uploading(packageID: UUID)
    case accepted(packageID: UUID, at: Date)            // bar said state:200 — NOT on the glass yet
    case applying(packageID: UUID, until: Date)
    case applied(packageID: UUID, layer: Int, at: Date)
    case undeliverable(packageID: UUID, reason: DeliveryFault, at: Date) // cube offline, error 4, hotspotIp…
    case failed(packageID: UUID, error: FriendlyError)
}
```

- `CubePublisher` (owned by the app, not a view): `send(cards:)`, `show(layer:)`, `step(by:)`, `interrupt(with:for:)`, `startTimed/stopTimed`; owns `themeTask`, a serial queue for :8080 uploads, cancellation checks; every upload path becomes `send(cards:)` so the twin can never lie.
- `PagePublisher`: `publish(Page, bindings:)`, `switch(to:)`, `refreshCover()`; typed `Profile`/`Widget`/`ModuleBinding`.
- `LinkService`: `@Published state: LinkState` (enum, generation-tagged), `pushCount`, `lastPushAt`; dispatches `PushRequest` to `PushResponder`s (`MacAgent` with async `Process`, `CubePublisher` for next/previous).
- `DeviceWatcher`: one owner of polling; coalesces, pauses during delivery, writes `CubeTwin.reported` + pages; one `CoreBarSession` with a pooled client for a burst of reads.
- `Diagnostics`: pure `[DoctorItem]` from `(CubeTwin, LinkState, pages, settings, modules)`; `DoctorAction` becomes an enum.
- `Settings`: `struct SettingsModel: Codable` with explicit `migrate`, wrapper owned by the App, debounced saves; `vivoLayerCount`/`vivoRotationOn` removed (twin state, persisted by `CubePublisher` in `twin-cache.json`).
- `FriendlyError`: typed `DeliveryFault` produced by the kit, mapped to text in Core — a table and a unit test.
- Views read `twin`, `settings.vivoCards`, `publisher.progress`; never `UploadDiag`, never string compares. `DeviceStrip` has no `.task`. Card lists become `ForEach` in a `VStack` with explicit move buttons (drag-reorder only when `List` is the page's scroll container).

## Migration plan

**Phase 1 — Stop the bleeding (S, 1–2 days).** Removes: secret leakage, link flapping, main-thread stalls, the "On the cube" lie.
1. Act-aware redaction in `CoreBarClient`; cap `wire.log` ~5 MB with rotation; clear the existing log on first launch of the new build; fix README/MANUAL/SECURITY.
2. `enum LinkState` + generation counter in `startLink`; ignore callbacks from an older generation. `osascript` off the main actor.
3. `enum Delivery` + `struct CubeTwin` in the app target as-is; route all seven upload paths through one `sendPackage(cards:)`; delete `UploadDiag`, `themeIndex`, `lastPublishedVivoLayers`, `UserDefaultsLayerCount`, `settings.vivoLayerCount`.
4. `CoreBarSession.upload` cancellation-aware; gate `sendToCube` with the same serial queue as page publish.

**Phase 2 — Services out of views and out of AppModel (M, ~1 week).** Removes: duplicated polling, mid-publish overwrites, settings lifetime bugs, closures-in-body churn.
1. `DeviceWatcher` owns the 30 s loop; `DeviceStrip`/`StatusView` lose `.task`.
2. `CubePublisher`, `PagePublisher`, `LinkService`, `Diagnostics` as `@MainActor` classes created in `UltraWorkspaceApp.init`; `AppSettings` moves to the App; `AppModel` keeps discovery/pairing/nav/sheets (~150 lines).
3. Typed `Profile`/`Widget`/`ModuleBinding` in `UltraBarKit` with a kitcheck byte-equality fixture.
4. UI: card lists → `ForEach` in `VStack`; activity log → bottom drawer (`VSplitView`) or column with `layoutPriority`; `twin.fault` computed in Core.

**Phase 3 — Testable core + roadmap enablers (L, 1–2 weeks).**
1. `DeckhandCore` library target; `kitcheck unit` covering `Delivery` transitions, `FriendlyError` mapping (incl. the "hotspot"/"host" regression), settings migration fixtures, `DeployPackager` 1–6 layers, `Profile` encoding fixtures, `CubeTwin.fault` matrix; e2e delivery scenario (mock Wi-Fi ≠ 3 → `.undeliverable`).
2. `CardRenderer` as pure `(CardSpec, DataSnapshot) -> RGBA` with a `DataProvider` protocol — the `.deckhandtheme` seam.
3. `CubePublisher.interrupt(with:for:)` + loopback `NotifyServer` (127.0.0.1, bearer token) — `POST /notify` / `POST /image`, HA.
4. Token → Keychain behind `TokenStore` for Developer-ID builds; AccuWeather key alongside.

What not to do: don't split `AppModel` by renaming extensions into more extensions; don't add more `@Published` flags to express delivery; don't fix layout by adding `fixedSize`/`frame(height:)`.
