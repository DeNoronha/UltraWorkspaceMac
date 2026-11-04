# Deckhand — senior developer code review (2026-11-03)

Read-only review by the senior-developer agent at commit `aa70724` (Swift 6.4.2 CLT, macOS 13 target). Line numbers refer to that commit. Items marked ✅ were fixed the same day (commit noted).

Build: clean of errors. Warnings after a clean rebuild: 22 × "'weak' ownership of capture 'self' differs from implicitly-captured strong reference" (AppModel+Doctor.swift ×20, AppModel+Link.swift:17,27); 1 × "will never be executed" at kitcheck/E2E.swift:270 (false positive, e2e passes); Discovery.swift: unused `withUnsafeMutableBytes` result + deprecated `String(cString:)`; 5 linker "search path not found" warnings from the CLT layout. Package.swift is `swift-tools-version: 6.0` (Swift 6 language mode).

## Executive summary

1. **The layout regressions are one bug class, and two live instances remain.** Any `Text(...).fixedSize(horizontal: false, vertical: true)` inside an `HStack` with a flexible sibling can be measured at width 0 and report a mile-high minimum; every page is `VStack { Header; DeviceStrip; ScrollView }`, so anything above the ScrollView with a huge minimum pushes the window. `StatusView.row` (line 61) and `ProgressRow` (ContentView:287, used beside the Send/Publish buttons) still do what DeviceStrip did before `6186dab`; the ProgressRow one fires precisely when the cube is off Wi-Fi.
2. **The main thread is being blocked by the device.** Every `GET_VOLUME`/`SET_VOLUME` push (every 5 s while the Deckhand page is up) runs `/usr/bin/osascript` synchronously on the main actor; `AppleMusic.nowPlaying()` runs NSAppleScript on the main thread every 3 s for the app's whole life (and triggers the Music automation prompt at first launch); card rendering, RGB565 encode, tar + bit-by-bit CRC32 + gzip all run on the main actor.
3. **Two real security/honesty problems.** `wire.log` (and "Copy report") contained the cube's Wi-Fi password hex and the AccuWeather key while the Wi-Fi sheet says "not stored on this Mac" (✅ redaction + 5 MB cap in `36ae3a8`; the sheet copy still needs correcting); and `handlePCControl` executes device-sent `openFile`/`startApp` (SECURITY.md itself says these must be opt-in). The author's own CoreBar hotspot password is hard-coded as a constant.
4. **State is triplicated and the "truth" strings are stringly-typed.** Which card is showing lives in `vivoLayerIndex`, `themeIndex`, `vivoLayerShowing`, `currentThemeLabel`; the layer count in `lastPublishedVivoLayers`, `settings.vivoLayerCount` and `UserDefaultsLayerCount.read()` (re-reads settings.json from disk on every DotKey press). Link health is `linkState == "Live link"` in 6 places. The rewrite left ~20 dead members.
5. **The protocol layer is solid** (actor-isolated client, TOFU pinning that never sends the token on mismatch, single-resume continuations, bounded waiters, e2e against a mock) but spent wastefully: every `CoreBarSession` call opens a fresh TLS + auth connection, so `refreshDeviceState()` is 5 connects every 30 s and `runDoctor` ~12 connects + an Open-Meteo call + a CoreLocation request every 30 s on the Status page.

## Findings

### Critical

**C1. `handlePCControl` executes device-chosen files and apps** — `AppModel+Link.swift:109-115`. `openFile` → `NSWorkspace.shared.open(URL(fileURLWithPath:))`, `startApp` → `openApplication(at:)` with whatever path the CoreBar (or anything that can speak to :7431 — the vendor TLS key is shared across all devices, so MITM is realistic) pushes. Deckhand's own pages never emit these. Fix: drop the branches (keep `openBrowser` restricted to http(s)) or gate behind an explicit per-path allowlist; log and `say` the refusal like `execCmd`.

**C2. Wi-Fi password and AccuWeather key in `wire.log` and the Status report** — ✅ fixed in `36ae3a8` (act-aware redaction, 5 MB cap, old log scrubbed, docs corrected). Still to do: `VivoWiFiSheet` (VivoCubeView.swift:200) copy "not stored on this Mac" is only true now that the log is redacted; say "sent to the cube only; redacted from Deckhand's log".

**C3. Hard-coded hotspot credentials of one physical unit** — `AppModel.swift:77` `coreBarHotspot = ("AndroidAP_7757", "<password of that unit>")`, used by `hotspotAction` and "Back to the CoreBar hotspot". For any other CoreBar the one-click "fix" writes wrong credentials and takes the cube off the network; it is also a real password in a public MIT repo (and in `kitcheck/main.swift:68`). Fix: per-CoreBar setting (prompt once, store in `Store.PairedCoreBar`), prefilled from the cube's current config if it starts with `AndroidAP`; never ship a literal.

### High

**H1. Two remaining min-height blow-up instances.** `StatusView.swift:56-65` (`Text(item.detail)…fixedSize` in an HStack with Spacer + Button) and `ProgressRow` (`ContentView.swift:287`, failure text, inside `HStack { Button; ProgressRow }` in VivoCubeView:25-32 and CoreBarPageView:25-31). Rule, app-wide: never `fixedSize(vertical:)` a `Text` whose parent is an `HStack` with flexible siblings; give it `.frame(maxWidth: .infinity, alignment: .leading)` and `.fixedSize()` only the button. OK as-is: Panel footer, AboutView, SettingsView, WidgetsView blurb, CoreBarPageView:164 (parent has fixed width). Also: `.layoutPriority(1)` on the page ScrollView; raise the window `minWidth` when Activity is open (`UltraWorkspaceApp.swift:21`).

**H2. Blocking `osascript` on the main actor for every volume push** — `AppModel+Link.swift:57-63,153-168`; also `runDoctor` (Doctor:184). Fix: async helpers in `Task.detached`, or CoreAudio `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (no subprocess, no Automation prompt); answer `GET_VOLUME` from a cache.

**H3. Music polling runs for the app's lifetime on the main thread and prompts at first launch** — `ContentView.swift:25` → `startMusicPolling()` (Music:18-34): NSAppleScript every 3 s even without a music card; `autoPushNowPlaying` never true. Fix: poll only while a music card is in use, off-main; or delete the loop and refresh where the card renders (Themes:287 already does).

**H4. `refreshDeviceState`/`runDoctor` open 5–12 TLS connections per cycle** — Doctor:30-43, :102-204; from `DeviceStrip.task` (:35) and `StatusView.task` (:47-52) every 30 s; `SenseReader` 3 more every 5 s. With the bar unreachable one `refreshDeviceState` can take ~90 s. Fix: `CoreBarSession.withClient { c in … }` (one connect, N requests); gate polling on `link.state == .connected`; `Task.checkCancellation()` between reads.

**H5. `resolveWeather` → `MacLocation().once()` every 30 s and on every render** — Weather:55, MacLocation:11-28: new `CLLocationManager` per call, authorization request from a timer, `CLGeocoder` (rate-limited), then `ipwho.is`. Fix: one long-lived `MacLocation`, cache location/place ~15 min and `OpenMeteo.Now` 5–10 min.

**H6. `wire.log` unbounded; `FileHandle.write(_:)` can crash** — ✅ cap/rotation in `36ae3a8`. Still: use `try? handle.write(contentsOf:)`; skip act 20 heartbeats unless verbose; make the `DateFormatter` static.

**H7. `CoreBarSession.upload` retry loops ignore cancellation** — CoreBarSession:403-424. `try? await Task.sleep` returns immediately in a cancelled task, so the retries become back-to-back POSTs; worst case ≈ 65 s uncancellable with the stepper stuck on "Uploading". Fix: `try Task.checkCancellation()` at each retry and after each sleep; propagate `CancellationError` as "cancelled".

### Medium

- **M1. Link state race on reconnect/switch** — Link:11-37, CoreBarLink:49-55,90: the old `runLoop`'s final `.stopped` can land after the new link's `.connected`. Fix: `onState = nil` in `stop()`, or `guard self.link === l` in the callback.
- **M2. `linkState` is a user-facing string used as program state** — compared in DeviceStrip:16,22, Doctor:47,126, ContentView:343-355. Fix: `@Published var link: CoreBarLink.State`, strings derived in `LinkBadge`.
- **M3. Triplicated showing-card / layer-count state** — `vivoLayerIndex`, `themeIndex` (write-only), `vivoLayerShowing`, `currentThemeLabel`; `lastPublishedVivoLayers`, `settings.vivoLayerCount`, `UserDefaultsLayerCount.read()` (Link:137-144, re-parses settings.json per button press). Fix: one `vivoShowing: Int?` + computed name; count = `vivoLayerNames.count` with the setting as launch seed only.
- **M4. `AppSettings` created in `ContentView` while `AppModel` is app-level** — ContentView:7 vs UltraWorkspaceApp:5; long-lived Tasks capture the window's instance. Fix: own it in `UltraWorkspaceApp`.
- **M5. Settings saved synchronously on every keystroke** — AppSettings:16-42; `saving` guard dead; `vivoSwitchMode` migration both branches `.timed`; `accuWeatherKey` in a 0644 JSON. Fix: debounce 300 ms; 0600 file or Keychain for the key.
- **M6. Picker hazards** — CoreBarPageView:57 selection `""` never a tag (console warning each render); VivoCubeView:138 `vivoSeconds` may be a legacy value not among 15/30/60/180 (snap on load); VivoCubeView:134-143 an interactive Picker inside a radio-group option label (unsupported on AppKit) → radio group + separate interval picker.
- **M7. `List` with hand-computed `frame(height: n*28 + 10)` inside a `ScrollView`** — VivoCubeView:113, CoreBarPageView:144; taller rows (Weather key editor, Picture note) cause nested scrolling and a clipped last row. Fix: measure rows, or `.scrollDisabled(true)` + generous height, or move per-row extras out of the List.
- **M8. Heavy work on the main actor during Send** — Themes:114-147: renderers, `DeviceImage.encode` ×6, PNG previews, `buildTgz` with bit-by-bit CRC32 over ~700 KB, gzip. Fix: render on main, `Task.detached` for encode + tgz; table-driven CRC32.
- **M9. `checkToken` cannot distinguish "token rejected" from "no answer"** — CoreBarSession:31-48; Doctor:122-124 then says "Not reachable" and offers "Check again" instead of "Pair again". Fix: `.accepted / .rejected / .certMismatch / .unreachable(Error)`.
- **M10. `postUpload` success and `FriendlyError` are substring matching** — CoreBarSession:628; Progress:50-60 matches `"pin"` ("pinned", "mapping"), `"host"` ("hotspot"), `"auth"` ("author"). Fix: parse `(state, msg)` as JSON; map `UltraBarError` cases with a `switch`.
- **M11. Stepper/twin drift in the timed loop** — Themes:56-71: the periodic re-upload resets the cube to layer 1 but `step` keeps counting → next tick jumps; the clock card is up to 5 min stale by design. Fix: realign `step` after a refresh; say the staleness in the UI or re-render that layer more often.
- **M12. `LogWatcher` republishes 1 000 strings every second** — LogsView:12-18, `id: \.offset`. Fix: sequence number from `WireLog`, stable per-line ids.
- **M13. `[weak self]` noise** — the 22 warnings come from `DoctorAction { [weak self] … }` inside Tasks already holding `self`. Drop them (AppModel lives for the app).

### Low

- L1 `Store.loadToken` reads from disk on every `session(for:)` (every 5 s from SenseReader). Cache per serial.
- L2 `Store.saveToken` writes with default umask before chmod 0600 (moot thanks to the 0700 dir); create with attributes instead.
- L3 `PreviewServer.start()` blocks with a semaphore under a lock; only reachable from dead code — remove from the app target.
- L4 `AppleShowScrollBars = Always` changes ScrollView content width by 15 px, which alters Text measurement; keep only as a product decision.
- L5 `vivoWiFi: [String: ModuleWiFi?]` double optional → `[String: ModuleWiFi]`.
- L6 `pair()` ignores a `code != 200` reply to act 101 and waits the full 30 s.
- L7 `publishNeedsConfirmation` can be false while foreign pages exist if `corebarPages` hasn't loaded.
- L8 `safeAreaInset(.top)` on the sidebar List with a borderless Menu is a known source of 1-px jumps; fall back to `VStack { chooser; List }` if it jitters.
- L9 "last request N s ago" is computed in `body` and only refreshes on other changes; use `TimelineView(.periodic(by: 5))`.
- L10 `ClaudeUsage.snapshot` reads up to 80 files of up to 50 MB fully on every render of that card; stream and cap.
- L11 `MissingModule`/`ConnectView` call `model.scan()` on every `onAppear` (8 s UDP listen per re-entry).
- L12 Dead code to delete (≤1 reference each): `showingSettings`, `showingAbout`, `coreThemes`, `coreSeconds`, `RotationTarget`, `themes(for:)`, `enabledList(for:)`, `isEnabled(_:for:)`, `setEnabled(_:_:for:)`, `seconds(for:)`, `autoPushNowPlaying`/`lastPushedKey`/`pushNowPlaying`/`stopMusicPolling`/`canvasSize`, `pushWeather`/`setWeatherAuto`/`weatherAutoUpdate`/`weatherTask`/`lastWeather`, `previewCoreBarScreen`, `chooseAndUploadImage`+`buildTgz`, `provisionModules`, `startThemeRotation`, `pushTheme`, `publishAddon`, `previewWideImage`, `themeIndex`, `deviceStateAt`, `CoreBarPageView.UI.pages/advanced`, `VivoCubeView.UI.maintenance`, `StatusView.UI.showFine`, `AppSettings.saving`, `Proto.actListModules`, `previewScreen(path:)`. Removing these shrinks `AppModel` by roughly a third.

## Do this first

1. Delete the `openFile`/`startApp` branches in `handlePCControl` (C1).
2. ✅ Redact property-7 values/results and `apiKey`; cap `wire.log` (C2, H6). Fix the Wi-Fi sheet copy.
3. Replace the hard-coded hotspot credentials with a per-CoreBar setting (C3).
4. Apply the one layout rule everywhere: fix `StatusView.row` and `ProgressRow`; raise `minWidth` when Activity is open (H1).
5. Move `osascript`/NSAppleScript off the main actor, cache volume, stop the unconditional Music poll (H2, H3).
6. `CoreBarSession.withClient`, batch `refreshDeviceState`/`runDoctor`, gate polling on link state, cancellation-aware loops (H4, H7).
7. Cache location + weather, one `MacLocation` (H5).
8. `linkState` as enum; fix the stop/start race (M1, M2).
9. Collapse the showing-card / layer-count triplicates; delete the dead code list (M3, L12).
10. Fix the three Picker hazards; own `AppSettings` at App level (M6, M4).

## What is good — keep it

- `CoreBarClient`: actor isolation, `ConnectOnce` single-resume continuation, `.waiting` treated as failure with a hard connect timeout, bounded line waiters, TOFU pinning evaluated inside the TLS verify block so the token is never sent on a mismatch. Better than the vendor client; do not touch during UI work.
- `CoreBarLink`: clean reconnect loop with capped backoff, heartbeat tied to the connection, push correlation by `id`.
- `kitcheck e2e` against the Node mock is the right test strategy for a CLT-only project; extend it rather than adding XCTest.
- `savePages` refusing an empty list, `uploadPageAsset` always passing a `subDir`, `provision` merging remembered modules, the `"hotspotIp"` / `module not found` recovery paths, and the "state:200 only means queued → wait, then read property 6" honesty in `sendToCube`.
- `StepProgress` + `ProgressRow`, `DeviceStrip` one-fault/one-action, `deviceFault`'s ordering, and the plain-English copy. Keep `Panel`, `Header`, `EmptyState` as the only layout primitives.
- `DeployPackager`, `DeviceImage`, `ZipWriter`, `Discovery`, `PreviewServer`: small, correct, hardware-documented.
- Tokens as 0600 files in a 0700 directory with the Keychain rationale documented; cert pins alongside.
