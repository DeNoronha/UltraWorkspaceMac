# Code-hygiene review — 2026-11-03 (evening, HEAD ed029c1)

Read-only review by a subagent: dead code, duplication, over-complexity, inconsistencies, and the status of the earlier 2026-11-03 reviews. Method: a script counted whole-word references for every member-level declaration under `Sources/`; every zero/one-hit symbol was re-verified with `grep -rnw --include='*.swift' <symbol> Sources`. No TODO/FIXME markers exist in the tree.

## 1. Dead / unused code

**High**

- **D1. The "live feed" renderer family is unreachable from the app.** `Theme.isLiveFeed` removes cpu/network/battery/disk/worldclock/diskio/topcpu/uptime/clock from `Theme.library` and `AppSettings.vivoCards`; `selectedAddon` only comes from `Theme.library`. So the `renderTheme` cases for those themes never run, and these files are reachable only from the dev CLI `WeatherPreview.run`: BatteryCard, BatteryStats, DiskCard, DiskActivityCard, DiskActivityStats, TopProcCard, TopProcStats, UptimeCard, WorldClockCard, ClockCard, `StatCard.system/.network`, `AppModel.sysStats/netStats/diskStats`, plus the Clock/Date/World-clock settings UI in `WidgetsView.addonSettings`. ≈1,000 lines.
- **D2. `Widgets/CryptoCard.swift`** — zero references; superseded by `CryptoCoinCard`.
- **D3. Weather-push chain** — `setWeatherAuto` (0 hits) is the only caller of `pushWeather` and the only writer of `weatherTask`/`weatherAutoUpdate`.
- **D4. Music auto-push chain** — `autoPushNowPlaying` is never set true, so `pushNowPlaying`, `lastPushedKey`, `canvasSize`, `stopMusicPolling` are dead; the 3-s poll only feeds the Music card preview.
- **D5. AppModel one-shot tools, 0 hits:** `provisionModules`, `chooseAndUploadImage`, `previewCoreBarScreen`, `buildTgz(from:size:)`, `showingSettings`/`showingAbout`. Removing `previewCoreBarScreen` makes `PreviewServer`/`LocalIP` app-side dead (kitcheck still uses them).
- **D6. AppModel+Themes:** `startThemeRotation`, `pushTheme`, `publishAddon`, `previewWideImage` (0 hits each); `themeIndex` is write-only.

**Medium**

- **D7. AppSettings:** `RotationTarget`, `themes(for:)`, `enabledList(for:)`, `isEnabled`, `setEnabled`, `seconds(for:)`, `coreThemes`, `coreSeconds` only reference each other; `saving` is never set true.
- **D8. `Proto` constants with 0 hits** (UltraBarKit/Models.swift): `actGetAppList`, `actGetProfileWidget`, `actModuleStopDiscovery`, `actQueryModuleState`, `actSetCoreBarConfig`, `actSysReboot`, `actWifiScanStart/Stop/Result`, `actListModules` ("deprecated alias" — a trap).
- **D9.** `WorldClockCard.defaultZones` and the `@available(deprecated)` shim `CoreBarSession.previewScreen(path:)`.
- **D10.** `UserDefaultsLayerCount` (AppModel+Link) re-parses settings.json on each DotKey press for a number already in `vivoLayerNames.count`.

Not dead: `hotspotAction` (called from `runDoctor`), `Progress.swift` (`StepProgress`, `FriendlyError`).

## 2. Duplication

- **High — Widgets drawing helpers.** Nine card files carry a private `drawText` + `drawSymbol` + `c()` byte-identical to `CardKit.text/symbol/c` (StatCard, WorldClockCard, BatteryCard, CalendarCard, CryptoCard, UptimeCard, DiskCard, DiskActivityCard, TopProcCard; ~145 lines), and 11 files build their own `CGContext` + gradient + `NSGraphicsContext` scaffold that `CardKit.draw` provides (~200 lines). Only ClockCard, DateCard, CryptoCoinCard use CardKit.
- **Medium — "which card is showing" computed four ways:** `(vivoLayerShowing ?? (vivoLayerIndex + 1))` in Themes and VivoCubeView; the `l >= 1 && l <= vivoLayerNames.count` guard with the same wording in Doctor (3×), DeviceStrip, VivoCubeView (2×). Fix: one `cubeShowing` on `AppModel`.
- **Medium — the cube-offline sentence is phrased five times** (Themes ×2, Doctor ×2, DeviceStrip, VivoCubeView ×2).
- **Low** — `DoctorAction("Set cube Wi-Fi…")` written three times; `Store.setHotspot`/`rememberNetwork` do the same insert; two `SystemStats()` instances on `AppModel`.

## 3. Over-complexity

- **High — `CoreBarSession.upload`** (41 lines, two retry loops, no cancellation checks). The second loop retries *any* rejection 3× with 10-s sleeps, including `reply error:4`/`:2` (cube off-network), which cannot clear on its own: ≥30 s of pure delay before the user sees the message. `try? await Task.sleep` lets a cancelled task spin through the POSTs. Fix: parse the reply once into an enum; retry only the hotspot-no-IP and module-not-found cases; `try Task.checkCancellation()` after each sleep.
- **High — `runDoctor`** (103 lines) and `deviceFault` evaluate the same facts with different wording; `runDoctor` parses `UploadDiag.shared.last` by string prefix. Fix: one `[Fact]` list feeding both.
- **Medium — `publishDeckhandPage`** (92 lines): network steps, a 40-line widget-building switch, page bounce and progress in one closure. Fix: pure `widgets(for:)` builder, kitcheck-testable.
- **Medium — `sendToCube`** (56 lines) mixes precondition, progress, Wi-Fi read, settle sleep and the timed loop; the `step` counter drifts after the 5-min re-upload. Doc comment on `ensureCubeOnWiFi` describes `uploadPackage`.
- **Medium — `WidgetsView.addonSettings`** (96 lines, one switch); a third is for cards that cannot be selected after D1.
- **Low** — `vivoWiFi[serial] ?? nil` double optional in five places; `List` inside `ScrollView` with `count * 28 + 10`; `kitcheck/E2E.swift run` is 262 lines.

## 4. Inconsistencies

- **High — `linkState: String` is program state**, compared literally in Doctor, DeviceStrip, ContentView. Fix: `@Published var link: CoreBarLink.State`, strings only in `LinkBadge`.
- **Medium** — per-view `UI: ObservableObject` flags declared but never read (`CoreBarPageView.UI.pages/advanced`, `VivoCubeView.UI.maintenance`, `StatusView.UI.showFine`); `Draft*` classes for the same purpose under three names.
- **Medium** — `AppSettings` created in `ContentView` while `AppModel` is app-level; 22 model methods take `settings:`.
- **Medium** — three cube-Wi-Fi-state vocabularies (kit `CubeWiFiState.label`, model `cubeWiFiLabel`/`cubeOffline`/`cubePackageStale`, raw `vivoWiFiState == 3`). Fix: expose `CubeWiFiState?` on the model, never the `Int`.
- **Low** — ad-hoc log prefixes; 36 `[weak self]` sites on an app-lifetime object; two bitmap "contracts" in Widgets (`sendPanelSizeTest`, `NowPlayingCard` use a different `bitmapInfo` than CardKit).

## 5. Status of the morning reviews

Fixed: F1/C2/H6 (wire-log redaction), C1 (remote-exec acts refused), C3 (no hotspot literal), H1 (`fixedSize` sites), M6 (radio group + interval picker), M7 half.

Still open: H2 (sync osascript on the push path, NSAppleScript on main every 3 s), H3 (unconditional music polling), H4 (no `withClient`, 30-s DeviceStrip loop), H5 (no location cache), H7 (no cancellation in `upload`), M1 (no generation guard in `startLink`), M2 (`linkState`), M3 (layer-count triplicates), M4, M5, M8 (render/encode/tgz on main actor), M9/M10 (substring matching in `postUpload` and `FriendlyError`), M11 (step drift), M12 (`id: \.offset`), M13, L3, L5, L12. Architecture F2 (`CubeTwin`/`Delivery`) not started.

## Suggested order

1. Delete D2–D10 (~400 lines, no behaviour change) and decide D1 (~1,000 more).
2. Collapse the Widgets helpers onto CardKit.
3. `upload` reply enum + cancellation, and the `linkState` enum.
4. Then the open H2–H5/M3/M4.
