# Deckhand — UX review

> **Status (3 Nov 2026):** implemented in the UI rewrite — goal-based sidebar with a device menu (Screens / Controls / Sensors / Library / Health), the device status strip with one fault + one action on every device page, the VivoCube twin from property-9 read-backs with ◀ ▶, the ordered picked list (max 6, drag, remove, Picture as a card), the switch-mode radio, inline publish steppers for both publish paths, confirmation only when something would be lost, per-row AccuWeather key, Maintenance disclosure, KnobKey/DotKey bindings tables, Status auto-run with severity order and action buttons, protocol ids scrubbed from user-facing strings, status bar as a safe-area inset, Activity as a toolbar toggle, first-run connect flow with progress and countdown, accessibility labels and keyboard shortcuts (⌘↩ primary action, ⌘R check again). Still open: editable bindings (row 21), the global "Publish changes" button (22), `Form(.grouped)` everywhere (20), a full first-run wizard with module tiles (19). The evening consistency pass of 3 Nov (`docs/reviews/ux-consistency-2026-11-03.md`) then put Send to cube next to Publish page in the header, the progress row first under the device strip, mirrored the sections on both screens (Cards on the bar / Cards on the cube, Switching, Maintenance), moved the Wi-Fi pill into the strip, made the library add buttons plain, and added the Light, Presence and Sound level bar cards. On 4 Nov the Library grew into four pages laid out alike — Installed, Widgets, Apps and Screensavers, each a list with the chosen item beside it, a switch (Installed on the bar / On the cube / On the CoreBar page) and its settings —, the status line and the link badge moved into the toolbar (the bottom bar is gone), Settings gained Debug bridge (ADB), every Remove asks first, and Refresh (⌘R) and Update all are shared by the three bar-facing library pages. The "Today:" descriptions below quote the UI as it was on 2 Nov and are kept as the record of what was reviewed.

Reviewed 2026-11-02 against `Sources/UltraWorkspaceApp/*` (ContentView.swift at commit bebfa0e plus the uncommitted Status/Doctor work), MANUAL.md, docs/ROADMAP.md, docs/WIDGETS.md, the app screenshots and the device photos from 1–2 November. Read-only critique; nothing in the source was touched. Opinions are deliberate — push back where you disagree, but every claim below quotes a real label or line.

---

## 1. Executive summary

Deckhand works, and the device photos prove it: the Deckhand page with Mac CPU, Next widget, Play/Pause, world clock and weather is on the CoreBar, and the cube shows the weather card. The problem is not capability; it is that the UI is a transcript of the protocol. The five biggest usability problems, in order:

1. **There is no feedback loop.** Every action ends in a sentence in the "Activity" column ("Package accepted — waiting 10s for the VivoCube to apply it…") and the user has to walk over to the desk, or photograph it, to learn whether it worked. Nothing in the app shows *what the device is showing now*, *whether the last publish was applied*, or *whether the cube can even receive uploads* (the "hotspotIp is empty" failure in screenshot 42 is buried in a log line while the page still invites you to "Publish & rotate").
2. **The information architecture mirrors the protocol, not the user's goals.** "Overview" is actually the CoreBar-page editor; the VivoCube page mixes a maintenance toolbox (Screen On/Off, Reboot, Recover display, Panel size test, Wi-Fi) with the one thing people come for (choose what the cube shows); "Widgets" is a settings page for 13 renderers that cannot put anything on a device; KnobKey/DotKey are read-only lecture pages even though their bindings are already being written (hidden in a caption on the Overview page). The sidebar has a "Scan for CoreBars" and a toolbar "Scan" and an empty-state "Scan now" for a device that, once paired, never needs scanning again.
3. **The vocabulary is wrong for everyone except the author.** "Refresh / set up", "Publish & rotate", "Recover display", "Panel size test…", "List pages", "Refresh cover only", "layer 1 / widget 101", "property 9", "30710", "act 1108" all appear in buttons, tooltips or status lines. "Rotate is onduidelijk" is the user telling you that "rotation" is a protocol concept (layer switching), not a user concept ("show these in turn").
4. **Choice-by-checkbox hides order and count.** On the VivoCube, 13 checkboxes in enum order decide which 6 (silently truncated — `"using the first 6 ticked widgets"` is a log line) go on the cube and in what order (also enum order, hence "order of widgets seemed random"). On the CoreBar page the same list exists twice (a drag list and an "Available" list) plus a 2-paragraph caption explaining that "Order here = left-to-right".
5. **Destructive and diagnostic actions sit next to everyday ones with equal weight.** "Reboot" (destructive role), "Recover display", "Screen Off" (which the Manual says will keep your cube dark "until you press Screen On again") and "Panel size test…" are first-class buttons above the widget picker; "Publish Deckhand page…" always triggers a destructive-styled confirmation that lists what will be *lost*, even on the 20th identical re-publish. Meanwhile the one truly risky thing — the official app's Deploy wiping Deckhand's assets — is a caption in orange.

Fix these in this order: (1) a device-state header + "what's on the screen now" twin, (2) a goal-based sidebar (Screens, Controls, Widgets, Status), (3) a rename pass, (4) a picked-list editor for both screens, (5) button hierarchy and an "Advanced" disclosure for maintenance.

---

## 2. Mental model & information architecture

### What the user is trying to do

First run, in order: **connect** ("find my bar, approve, done") → **see my hardware** ("that's my bar, my cube, my knob, my keypad, my sensor — all green?") → **put something useful on each screen** ("weather on the cube; clock, CPU and a play button on the bar") → **make the knob and buttons do things** ("knob = volume, button 1 = next widget") → **keep it running** ("is it still live? if not, why, and what do I press?").

Steady state (every day after that): glance to confirm it's live, occasionally change what a screen shows, occasionally fix a black cube.

### What the current sidebar exposes

```
CoreBars
  ultrabar  5001G2…0145   ✓         ← device picker (always 1 device)
  Scan for CoreBars                       ← scanning after pairing is never needed
  Add by IP…                              ← developer/mock affordance
ultrabar
  Overview                                 ← actually: CoreBar page editor + pages list + AccuWeather key + bindings caption
  KnobKey  ●                               ← 3 lines of prose, "not available yet" (but it IS bound)
  SenseCube ●                              ← live tiles (good)
  VivoCube ●                               ← preview + maintenance + Wi-Fi + size test + rotation + custom image
Configure
  Widgets                                  ← settings for 13 renderers; cannot publish anything
  People                                   ← Teams/FaceTime launcher, unrelated to the hardware
  Status                                   ← new, being built
  Logs                                     ← wire log
About Deckhand
```

Problems: the device is both a section header ("ultrabar") and a selectable row with a checkmark (two different selection models in one sidebar — `Button` rows under "CoreBars", `.tag` rows under the device); modules are listed in bus-discovery order and the order changes between launches (screens 28 vs 33 vs 44 show three different orders); three Scan entry points; "Overview" is the most important page but the name says nothing; and the hardware pages are organised by *module* while the user thinks in *screens* and *controls*.

### Proposed IA

Organise by what the user wants to change, not by which module answers which protocol call. One CoreBar is the norm; keep multi-bar support in a popup in the header, not as a sidebar section.

```
┌──────────────────────┬──────────────────────────────────────────────────────────────┐
│ ▣ ultrabar      ⌄    │  Toolbar: [Publish changes]  (only when dirty)   [?]  [⚙]     │
│ ● Live · 1 h 12 m    │                                                              │
├──────────────────────┼──────────────────────────────────────────────────────────────┤
│ SCREENS              │  DEVICE STRIP (always visible, per selected device)          │
│  ▭ CoreBar page      │  ● Reachable  ● Live link · 212 answered · 3 s ago           │
│  ◎ VivoCube          │  Showing: Deckhand page · Cube: CPU & memory (2 of 4)        │
│ CONTROLS             │  Last applied 08:35 ✓          [Fix…] appears only on fault  │
│  ◌ KnobKey           ├──────────────────────────────────────────────────────────────┤
│  ⋮⋮ DotKey           │                                                              │
│ SENSORS              │   page content                                               │
│  ▤ SenseCube         │                                                              │
│ LIBRARY              │                                                              │
│  ▦ Widgets           │                                                              │
│  ♟ People            │                                                              │
│ HEALTH               │                                                              │
│  ✚ Status            │                                                              │
│  ≡ Logs              │                                                              │
└──────────────────────┴──────────────────────────────────────────────────────────────┘
```

- **Device chooser** becomes a header popover (name, serial, IP, "Add another CoreBar…", "Forget this CoreBar"). Scan/pair lives *only* in the first-run empty state and inside "Add another CoreBar…". Remove the toolbar "Scan" and the sidebar "Scan for CoreBars" once at least one bar is paired.
- **Screens** is the group people open 90 % of the time. "CoreBar page" and "VivoCube" are the only two things that *display*; put them first and give them the same editing pattern (a "What's on it" list with drag, a live twin, one Publish button).
- **Controls** = KnobKey and DotKey: each page shows the bindings that are actually written in `moduleBindings()` today (knob = Mac volume, press = mute; keys 1/2 = widget 1/2, key 3 = next, hold = standard page) as *read-only rows with the current value*, instead of the "Needs the profile-write path… on the roadmap" prose that is now simply false.
- **Status** is the device-truth page (see §4). The per-device strip at the top of every page is the short version of it.
- Keep the sidebar order of modules fixed (VivoCube, KnobKey, DotKey, SenseCube) — sort by type, not by `AttachedModule` discovery order.
- The right-hand **Activity** column (`ActivityLog`, ContentView.swift:877) goes away from the Screens pages. It is a log, not feedback. Replace it with a one-line result under the Publish button plus a toast; keep the full log on the Logs page.

### VivoCube screen — wireframe

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ VivoCube                                                          ● Wi-Fi ok │
│ Shows one card at a time · 240×240                                           │
├─────────────────────┬────────────────────────────────────────────────────────┤
│   ON THE CUBE NOW   │  WHAT THE CUBE SHOWS                                   │
│  ┌───────────────┐  │  ⋮⋮ 1 Weather & time            ◎ now        ⓧ        │
│  │   22:31       │  │  ⋮⋮ 2 CPU & memory                           ⓧ        │
│  │   ☁ 11°C      │  │  ⋮⋮ 3 Music                                  ⓧ        │
│  └───────────────┘  │  ⋮⋮ 4 Calendar                               ⓧ        │
│  Card 1 of 4        │  (+ Add a card…)           4 of 6 slots used           │
│  applied 08:35 ✓    │                                                        │
│  [◀] [▶]            │  Switch card:  (•) every [30 s ⌄]  ( ) only by button  │
│                     │                                                        │
│                     │  [ Send to cube ]   last sent 08:35 · applied ✓         │
│                     │                                                        │
│                     │  ▸ Maintenance (screen, restart, Wi-Fi, test picture)  │
└─────────────────────┴────────────────────────────────────────────────────────┘
```

Key moves: the preview is no longer "pick any of 13 widgets from a popup" (CubePreview, ContentView.swift:582) but *the card the device reports it is on* (property 9 read-back, which `readLayerWidget` already does), with ◀ ▶ that call `setLayer` — now the Mac has the same buttons the DotKey has. The picker is a picked list (order visible, slot count visible, max 6 enforced at add time), not 13 checkboxes. "Rotate" disappears as a word: it becomes "Switch card: every 30 s / only by button". Publish is one button whose label stays stable ("Send to cube"), with the result on the same line. Start/Stop goes away as a concept: if "every 30 s" is selected, the app switches; if "only by button", it doesn't. Maintenance (Screen On/Off, Restart, Wi-Fi, Test picture) collapses under a disclosure.

### CoreBar screen — wireframe

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ CoreBar page                                            Showing: Deckhand ✓  │
│ A row of the bar's own cards. About 4 fit; more scroll sideways.             │
├──────────────────────────────────────────────────────────────────────────────┤
│  PREVIEW (1424×280 strip, drawn from the card list)                          │
│  ┌──────┬──────┬──────┬──────┬──────┐                                        │
│  │08:35 │ 9°   │ 9 %  │ ▶⏸  │ ⏭   │ … (dimmed: scrolls)                     │
│  │clock │weath.│ CPU  │music │ next │                                        │
│  └──────┴──────┴──────┴──────┴──────┘                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│  CARDS ON THE PAGE (drag to reorder)                 ADD A CARD              │
│  ⋮⋮ Clock (Deckhand picture)            ⓧ           + World clock           │
│  ⋮⋮ Weather (bar's own)   ⚠ needs key   ⓧ           + Mac memory  ⌁ Mac     │
│  ⋮⋮ Mac CPU               ⌁ Mac         ⓧ           + Mac storage ⌁ Mac     │
│  ⋮⋮ Play / Pause          ⌁ Mac         ⓧ           + Temperature (Sense)   │
│  ⋮⋮ Next cube card        ⌁ Mac         ⓧ           + …                     │
│                                                                              │
│  ⌁ Mac = updates only while Deckhand runs                                    │
│                                                                              │
│  [ Publish page ]   last published 08:35 ✓ · 5 cards                         │
│                                                                              │
│  ▸ Pages on the bar (Standard, Deckhand — switch)                            │
│  ▸ Weather card key (AccuWeather, paid after trial)                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

The preview strip is rendered locally from the card list (you already know every card type's shape and have the icons; a schematic mock is enough — it does not have to be pixel-exact). The "On the page" / "Available" split already exists (ContentView.swift:316–343); put them side by side instead of stacked, and drop the "Order here = left-to-right on the CoreBar. Publish the page after changing it." caption because the preview strip says it.

---

## 3. Terminology

Rule of thumb: a word may appear in the UI only if the person at the desk would use it to describe what they see on the hardware. Everything else moves to tooltips, "Advanced", Logs or the Manual.

| Current term (where) | What it actually means | Plain word to use | Verdict |
|---|---|---|---|
| **provision**, "Refresh / set up" (CoreBarView header, `refreshModules`, status "setup: …") | Re-scan the magnetic bus and write the module list into the gateway config | "Find modules" (button), "Looking for modules…" (progress) | Rename. Never show "setup:" diagnostics in the status line. |
| **profile** / **page** ("CoreBar pages", "Pages on the CoreBar", `Standard Mode default`) | A vendor profile = a strip of cards with module bindings | "Page" is fine; never say "profile". Show page *names* only; hide ids like `deckhand.page`, `default`. | Keep "page", drop the id column. |
| **layer** ("layer 1 / widget 101", "uploaded once as layers", "Layers in the last package") | Slot N in the cube's image package | "Card 1 of 4" | Jargon — remove from UI; keep in Logs. |
| **widget** (used for *both* Deckhand's 13 renderers *and* the vendor's cards on the bar, and in "VivoCube widgets 1/2") | Two different things | Deckhand renderer → "card" (it's a picture on a screen); vendor card → "card" too, qualified by where it lives ("bar's own card"). The library page can stay "Widgets" if you prefer, but on device pages say "card". | Disambiguate. |
| **rotation**, "Widget rotation", "Publish & rotate", "Start rotation", "Stop", "Display stopped." | A Mac timer that switches the displayed slot | "Switch card every 30 s" / "only by button" | Remove the noun entirely. The user said it out loud. |
| **publish** ("Publish to VivoCube", "Publish Deckhand page…", "Publish & rotate") | Upload + apply | "Send to cube" / "Publish page" (one verb per screen) | Acceptable for the bar; for the cube "Send" reads better because nothing becomes public. |
| **PC_CONTROL**, `VIVO_CUBE_TOGGLE`, `CHANGE_PROFILE`, "act 1000000 / SET_VOLUME" (KnobKey/DotKey pages, Overview caption) | Binding types | "Button → Mac action", "Button → cube card 1", "Hold → Standard page" | Jargon — remove. |
| **cover**, "Refresh cover only", "Clock-card cover (480×480, weather & time)", `deckhand/cover.png` | The picture on the clock card | "Clock picture" | Rename; "Refresh cover only" → "Update clock picture" under Advanced. |
| **"Recover display"** (bandage icon) | Screen on + point at slot 1 | "Fix black screen" | Rename and move into the Status page's fault row; keep a copy under Maintenance. |
| **"Panel size test…"** (menu of 9 sizes) | Upload diagnostic | "Send test picture" (one size, 240) | The question it answered is answered (ROADMAP: panel is 240). Remove the menu; keep a single test under Maintenance/Status. |
| **"List pages"** | Read page ids | — | Remove as a button; read pages automatically when the page opens and in Status. |
| **"Screen On" / "Screen Off"** | Property write that the CoreBar persists | "Screen: on/off" toggle with a note "stays off until you turn it on" | Make it a toggle that reflects the read-back state (property 4), not two buttons. |
| **"Live link"**, "Link off", "Linking…", "Reconnecting (…)", "12 answered" | Persistent TLS connection answering device queries | "Connected · answering the bar", "Not connected", "Reconnecting…" | Keep the concept; say what it means for the user ("the bar's Mac cards update"). "answered" needs a noun: "212 requests answered". |
| **Mock / "Add by IP…"** ("Useful for a mock CoreBar on localhost…") | Developer path | "Connect by address…" with no mention of mocks or Docker | Keep, move into the Add-CoreBar flow, strip the dev copy. |
| **"needs Mac"** badge | Card fed over the link | "⌁ live from Mac" with a legend | Fine idea, better label. |
| **Open-Meteo / AccuWeather / Claude Code monitor** | Data sources | Keep; they are brands the user will search for. | Keep. |
| Numbers in copy: 30710, 1108, 1103, 7431, "property 9", "code 200", "state:200", "BadTokenException" | Protocol ids | — | Logs only. Today they leak via `say()` into the status bar ("Pages written ({"act":1108,…})"). |

Also drop from the UI: "(ad-hoc) BATCH_SAVE_PROFILE", "hotspotIp is empty" (say "the cube is not on Wi-Fi"), "RGB565", "tar/gzip", "1424×280" in page subtitles (keep in tooltips), "2.0″ square · 240×240" (the user cannot do anything with it).

---

## 4. Feedback & state — the photo problem

Today the only feedback channel is `AppModel.say()` → one status-bar line + the Activity list. Both are *narration*, not *state*: they tell you what Deckhand *did*, not what the device *is*. The device does report quite a lot back, and the code already reads most of it: token check, page list (30710), VivoCube screen (property 4), slot/widget (property 9), Wi-Fi SSID and state (property 7 + `Proto.Property.wifi`), uptime, SenseCube readings, and the upload reply text. None of that is on the Screens pages.

### What every device page must show (header strip)

A fixed, always-visible strip under the page title, refreshed on open and every ~30 s while the page is in front:

- **Reachable** — token check result and IP ("● ultrabar · 192.168.50.54", or "○ not reachable — on the same Wi-Fi?").
- **Link** — "● Connected · answering the bar (212 requests, last 3 s ago)" / "○ not connected: Mac cards on the bar won't update".
- **Showing** — what the device reports: for the bar, the current page name as far as Deckhand knows (you can only know it when Deckhand switched it; say so: "Deckhand page (set 08:35)"); for the cube, "Card 2 of 4 — CPU & memory" from property 9 and the last package's names (`vivoLayerNames`).
- **Last applied** — timestamp of the last upload *plus* the settle result. Today "accepted" means the CoreBar took the HTTP POST; the cube applies it later. Represent this honestly as two states.
- **One fault, one action.** If any of the above is red, show exactly one sentence and one button: "Cube is not on Wi-Fi — [Set cube Wi-Fi…]", "Screen is off — [Turn on]", "Showing a card that is not in the last package — [Fix black screen]", "Certificate changed — [Pair again]".

### The device twin

Keep a **twin** of each screen that is built from device read-backs, not from what Deckhand intended:

- **VivoCube twin**: the image Deckhand rendered for the slot the cube says it is on (the new `vivoLayerImages[layer]`), with "Card n of m", a screen-off overlay when property 4 = 0, and a "Wi-Fi disconnected — may still show the old picture" banner when the Wi-Fi state ≠ 3. Put this on the VivoCube page *in place of* the free-choice preview, not only on Status.
- **CoreBar twin**: a schematic strip rendered from `settings.coreCards` plus the known page name, with the scroll cut-off drawn, and a banner if `corebarPages` does not contain `deckhand.page` any more ("the official app deployed since — publish again").

Do not pretend precision you don't have. Where the device cannot tell you (page contents, whether the cover image actually rendered), label it "as sent 08:35", never "showing".

### Progress states for multi-step actions

Replace "Package accepted — waiting 10s for the VivoCube to apply it…" (a sentence that needs the Manual to decode) with an inline stepper under the Publish button:

```
Rendering 4 cards ✓ → Uploading (46 KB) ✓ → Cube applying… ◌ (about 10 s) → Showing card 1 ✓
```

The same for the CoreBar: "Clock picture ✓ → Button icons ✓ → Pages written ✓ → Switching to Deckhand page ✓". Red step + one next action on failure ("Upload refused: the cube is not on Wi-Fi — [Set cube Wi-Fi…]"). The "Rendering → Uploading → Applying → Showing" states already exist as `say()` calls in `startThemeRotation` and `publishDeckhandPage`; they just need to be an enum on the model rather than strings.

### Error states

Every error today is `"… failed: \(error.localizedDescription)"`. Three rules: (1) say what, not which call ("Could not list pages: 30710 did not answer" → "The bar did not answer"); (2) one next action as a button, not a hint in prose; (3) never two parallel channels — pick the inline result row, and let the status bar mirror it.

### Critique of the Status / Doctor page being built

The idea is right and overdue: it is the first place in the app where the *device* is the source of truth. Specific points on `StatusView.swift` / `AppModel+Doctor.swift`:

- **It must not be a separate destination the user has to remember.** Make the header strip described above the "always-on" version and link it to Status ("Details…"). If the only place that tells me the cube is off Wi-Fi is a page called Status under "Configure", the photo habit stays.
- **Run automatically**, not on "Run checks". It already runs `onAppear`; drop the button to "Check again" with a timestamp, and re-run on a timer while the page is visible (SenseCube already polls every 5 s — same pattern).
- **Order by severity, not by the order of checks.** Put fails first, then warnings, then the all-green list collapsed. Right now a red "Wi-Fi" sits under a green "Reachable" in a group list.
- **Every red/orange row needs its one action button** in the row: "Set cube Wi-Fi…", "Turn screen on", "Fix black screen", "Publish page", "Pair again". `DoctorItem` needs an optional `action: (title, closure)`.
- **Drop the protocol residue from the detail strings**: "30710 did not answer", "property 9 unreadable", "TLS + token accepted", "layer 2 / widget 102 → CPU & memory". Say "The bar did not answer", "Could not read the cube's current card", "Connected and paired", "Card 2: CPU & memory".
- **The twin is parsing a display string** (`Int($0.detail.components(separatedBy: " ").dropFirst().first…)` on the "Showing" item). Store `vivoLayerShowing: Int?` on the model and read it; don't scrape your own UI text.
- **Add what is missing**: app version + macOS version; whether Location/Calendar/Automation permissions are granted (the weather fallback chain depends on it); the pairing age and certificate pin; the DotKey/KnobKey *bindings as published* (so a user can see "key 3 → next card" without reading Overview captions); time since the last cover refresh; and a "Deckhand page present on the device" line that is already half there — make it the explicit "official app deployed since?" check from the ROADMAP's co-existence section.
- **"Copy report"** is good. Also include the last 30 wire-log lines (redacted) rather than 12 activity lines, and the settings that matter (cards list, cube card list, interval). Add "Reveal log file" next to it. Consider a `deckhand://` or `.txt` export so a support request is one drag.
- **Keyboard shortcut ⌘⇧R** for "Run checks" collides with nothing, fine, but it is undiscoverable; the menu bar should have a "Device" menu with it.

---

## 5. Flows

### (a) First launch & pairing

Today: window opens with an empty sidebar ("None yet — press Scan ↻"), an `Unavailable` empty state ("Connect your UltraBar… then Scan and Pair (tap Approve on the device)") and a `ConnectionHelp` block with a USB safety warning. Scan runs 8 s with no progress indication beyond the status bar; a discovered bar appears in the sidebar with a borderless "Pair" button; a sheet says "Tap Approve on 'ultrabar' within 30 seconds…" with an indeterminate spinner; on success it silently selects the bar, loads cached modules, and runs a 16 s bus scan — all reported as status-bar sentences. Nothing then tells the new user what to do next.

Problems: three Scan entry points; the macOS Local Network permission prompt arrives mid-scan and nobody explains that "No CoreBars found" after denying it is a permissions problem; no countdown in the 30 s approval sheet; the USB warning is a wall of text at the very moment the user only wants to connect; after pairing the user lands on "Overview", the most jargon-dense page.

Redesign as a four-step sheet (`.sheet` on first launch and from "Add another CoreBar…"):

1. **Find** — "Looking for CoreBars on your network…" with a progress bar (8 s), results list, "Can't see it? [Enter its address…]" (the Add-by-IP path) and the Local Network permission check with a "Open System Settings" button if denied.
2. **Approve** — big device name, a 30 s countdown ring, a photo/illustration of where "Approve" appears on the bar.
3. **Find modules** — automatic; show the four module tiles appearing with green dots; a "Tap the bar's screen to wake sleeping modules" tip only if a known module is missing.
4. **Put something on it** — the only step that matters: two tiles, "Cube: Weather & time [Send]" and "Bar: Clock + CPU + Play/Pause [Publish]", each a one-click default. Finish lands on the CoreBar page with the twin showing what was just sent.

Put the USB safety warning on its own line in step 1 ("Power the bar from its PC-LINK port via your Mac — never a fast charger [Why?]") and in Settings; not as a full `GroupBox` in the empty state.

### (b) Putting widgets on the VivoCube

Today (`RotationView`, ContentView.swift:654): 13 checkboxes in `Theme.allCases` order, a caption "Tick up to 6 widgets. They are uploaded once as layers; rotation then just switches layers (no re-flash). Contents refresh every few minutes.", a "Show each for" picker (15 s / 30 s / 1 min / 3 min) that is disabled with one tick, a button whose label flips between "Publish to VivoCube" and "Publish & rotate", a "Stop" button that appears only while running, and "Showing: …" in a caption. Over-ticking is accepted and truncated with a log line. Order = enum order (`setEnabled` re-sorts by `Theme.allCases`). The preview above shows whichever of the 13 you pick in a popup, unrelated to what's ticked or what's on the cube. The "custom image" uploader is a separate single-slot path that silently replaces the package.

Redesign:

- A **picked list** ("What the cube shows", max 6, drag to reorder, ⓧ to remove, "+ Add a card…" opens a popover of the 13 with thumbnails). Order is visible, and `settings.vivoThemes` becomes ordered rather than filtered-by-enum. "4 of 6 slots" counter; the + is disabled at 6.
- **Custom image = a card type**, not a separate section. "Picture…" in the Add popover, occupying a slot like any other card. This removes "Push a custom image" and the surprise of it wiping the package.
- **Switch mode** as a radio, not a timer-shaped picker: "( ) Stay on one card  (•) Switch every [30 s]  ( ) Switch only with the DotKey / bar button". The word "rotate" disappears.
- **One button, stable label**: "Send to cube". Its state line underneath carries the stepper (render → upload → applying → showing). No "Stop": switching off the timer is the radio, and "the app must be running for timed switching" is a one-line note.
- **Twin on the left**: the card the device reports (property 9) with ◀ ▶ that call `setLayer` and "Card 2 of 4 · applied 08:35". Preview-on-demand of any renderer moves to the Widgets library page where it belongs.
- Keep `vivoRotationOn` resume on launch (good), but *say so* in the strip ("Switching every 30 s since 08:35").

### (c) Building the CoreBar page

Today (`CoreBarPagesView`, ContentView.swift:269): a headline with "List pages"; two paragraphs of explanation; a 150 px "clock-card cover" preview with three buttons ("Publish Deckhand page…", "Refresh cover only", "Refresh preview"); "Cards on the Deckhand page" with a 2-line caption and an orange "5 cards: the CoreBar shows about 4…" warning; a drag `List` (height computed by hand) and an "Available" list; another caption; an inline AccuWeather key field with a link and a 3-line orange price warning; a caption listing module bindings; "Pages on the CoreBar" rows with `id` and "Show" link buttons; a 4-line orange destruction warning; and a destructive `.alert` on every publish.

Problems: the editor is right (drag, add/remove) but surrounded by six captions totalling ~140 words of orange and grey; the primary action sits next to the preview, above the thing it publishes; "Publish" is styled destructive and always confirms, so the confirmation stops meaning anything after the second time; the AccuWeather key lives on the page builder rather than on the Weather card it belongs to; module bindings are a caption and not editable; page ids are shown.

Redesign:

- Structure: twin strip → cards list (left: on page, right: add) → one "Publish page" button with inline stepper → disclosures for "Pages on the bar", "Weather card key", "Advanced".
- **Confirm only when it matters**: on first publish and whenever `corebarPages` contains pages other than `default` and `deckhand.page` (i.e. something made in the official app would be lost). Otherwise publish directly. Make the alert's button say what it does ("Replace pages") and list the pages that will be removed, not a paragraph about the protocol's inability to read them back.
- **Per-card settings in the row**: the Weather (bar's own) row shows "⚠ needs key" and a disclosure that contains the AccuWeather field, the trial/paid note in one line, and "Get a key" link. The Clock row shows the clock picture thumbnail with "Update picture" (the old "Refresh cover only"). This empties the page of the two long orange paragraphs.
- **Scroll cut-off** drawn in the preview strip; drop the orange "scrolls sideways" label.
- "Show" link per page → a segmented "Showing on the bar: [Standard] [Deckhand]" control, reflecting `currentPageId`.
- Remove "List pages" and "Refresh preview" as buttons; both happen automatically.
- The "Publishing rewrites ALL pages…" and "The official app's Deploy deletes Deckhand's images" facts belong in (1) the first-publish confirmation and (2) a Status check ("Deckhand page missing — the official app deployed since?"), not permanently on the page.

### (d) Assigning KnobKey / DotKey actions

Today: `KnobKeyView` and `DotKeyView` (ContentView.swift:466–484) are `DeviceInfo` prose ("Feasible: bind a rotation direction to 'PC volume'… Needs the profile-write path (BATCH_SAVE_PROFILE) — on the roadmap"). Meanwhile `moduleBindings()` *does* bind them, and the only place a user learns this is one caption on Overview ("Modules on this page: KnobKey → Mac volume (button = mute), DotKey buttons 1/2 → …").

Redesign in two steps:

- **Now (S)**: replace the prose with a read-only bindings table mirroring `moduleBindings()`, with a diagram of the module (knob: turn / press; DotKey: ● ● ▬ keys, press / hold), each row "Turn → Mac volume", "Press → Mute", "Key 1 → Cube card 1", "Key 2 → Cube card 2", "Key 3 → Next cube card", "Hold key 3 → Standard page". Add "These apply while the Deckhand page is on the bar" and a "Last used 3 s ago" from `lastVolumePushAt`. That is the single highest-value quick win in the app: it turns a "not available yet" page into a "here is what your hardware does" page without any new protocol work.
- **Next (M/L)**: make each row a popup with the actions the firmware actually supports via `PC_CONTROL`/`VIVO_CUBE_TOGGLE`/`CHANGE_PROFILE` and the Deckhand command set (next/previous card, play/pause, next/previous track, mute, switch page, open URL, open app). Hot-key combinations typed over USB-HID can be offered only if the vendor packs are imported (ROADMAP "plugin packs") — don't promise them in copy until then. Changing a binding marks the CoreBar page dirty and the global "Publish changes" button lights up (bindings live in the profile, so they ship with the page publish — say so inline: "Saved with the next page publish").

### (e) Recovering from problems

Today the recovery knowledge is spread over: the "Recover display" tooltip, the Manual's Troubleshooting section, the Network caption ("hotspotIp is empty"), the Display caption ("Screen Off is remembered…"), and `say()` strings. The user has to diagnose first and then find the right button.

Redesign — diagnose for them, then offer the one button:

| Symptom the user sees | What the app can detect | Strip message + action |
|---|---|---|
| Black cube | property 4 = 0, or property 9 points outside the last package, or Wi-Fi state ≠ 3 | "Cube screen is off — [Turn on]" / "Cube is pointing at a card that no longer exists — [Fix]" / "Cube lost Wi-Fi — [Set cube Wi-Fi…] (or detach and re-attach it)" |
| Stale content (yesterday's weather, old time on the clock picture) | last upload age vs. refresh cadence, `deckhandPagePublished` + cover-refresh timestamp, link state | "Cards haven't been refreshed since 23:10 (Mac was asleep) — [Refresh now]" |
| Bar shows the standard page / no Deckhand page | `corebarPages` lacks `deckhand.page` | "The Deckhand page is gone from the bar (official app deployed?) — [Publish page]" |
| Device offline | token check fails / link reconnecting | "ultrabar is not answering on 192.168.50.54 — same Wi-Fi? [Check again] [Enter new address…]" |
| Certificate changed | `tc.mismatch` | "This bar's certificate changed — [Pair again]" |
| Modules missing | cached vs. scanned set differs | "DotKey didn't answer — tap the bar's screen to wake it, then [Find modules]" |

Keep "Restart cube" (rename of Reboot) under Maintenance as the last resort with a confirm, never as a first-class button in the Display row.

---

## 6. Visual / HIG

- **Form & grouping.** Device pages are hand-built `VStack`s with `Divider()`s and `.font(.headline)` labels; Settings uses `Form(.grouped)`. Use `Form { Section { } }` with `.formStyle(.grouped)` on the VivoCube, CoreBar and Status pages too: it gives consistent insets, section headers/footers (the right place for one-line captions), and dark/light/Liquid Glass materials for free. The hand-measured `.frame(height: CGFloat(max(1, onPage.count)) * 30 + 12)` list goes away with a `Section` + `ForEach` + `.onMove`.
- **Button hierarchy.** Everything is `.bordered`. Make exactly one button per page `.borderedProminent` (Send to cube / Publish page), everything else `.bordered` or `.borderless`, destructive only for Restart/Forget. Today "Reboot" (destructive role but same visual weight), "Recover display", "Screen On/Off", "Panel size test…" and "Publish & rotate" are visually identical.
- **Copy length.** Count the captions: VivoCube page has 5 paragraphs before the first choice; CoreBar page has 6 captions plus 3 orange `Label`s plus an alert paragraph. HIG footers should be one sentence; anything longer is a Help link or a "Learn more" popover. Orange text is used for price warnings, scroll warnings and data-loss warnings alike — reserve colour for things that need action.
- **Colour & badges.** Three traffic-light dots (sidebar online, status bar link, Status page) without legends. Pair every dot with a word in the strip. The orange "needs Mac" capsule is good; make it a consistent `Label` with a legend.
- **Empty states.** Good: `Unavailable` ("Connect your UltraBar"). Missing: a VivoCube with zero cards ("Nothing on the cube yet — add a card"), a CoreBar page with zero cards, Status before the first run (currently a 2-line paragraph), People ("Add someone below."). Use the `ContentUnavailableView` pattern (macOS 14+) with a custom fallback on 13.
- **Preview fidelity.** The old round mask (screens 36/37, `Circle().stroke`) has been replaced by a square, good; the 2.0″ caption and "240×240" are developer facts, drop them. Screenshot 37 shows a preview rendered upside-down and mirrored — presumably fixed, but it shows why the twin must come from the device-side pipeline (encode → decode), not a separate NSImage path.
- **Liquid Glass.** `GlassSurface` is used only on the status bar overlay. On macOS 26 the standard `NavigationSplitView` sidebar and toolbar already get glass; the custom status bar glass over scrolling content doubles the material and makes the bottom caption unreadable (see screenshot 44's cropped last Activity line under the bar). Prefer `.safeAreaInset(edge: .bottom)` for the status bar so content never scrolls under it, and drop the custom glass there. Don't add `.glassEffect` to the Form sections.
- **Window & layout.** `HSplitView` with a permanently visible Activity column eats 40 % of the width on every device page. Move Activity to an inspector (`.inspector` on macOS 14+, toggle in the toolbar) or to the Logs page. Min width 820 is fine; the content column should be allowed to use it.
- **Sidebar consistency.** Paired CoreBars are `Button`s with a manual checkmark, modules are `List` selection rows. Use one selection model. Keep the module order fixed by type. Show the friendly name only; serials belong in tooltips and in the device popover.
- **Accessibility.** No `accessibilityLabel`s on icon-only buttons (`arrow.clockwise`, `minus.circle`, `plus.circle`, the music transport, People's five icon buttons). The 6 px green dots have no text alternative. `Toggle(.checkbox)` rows are fine; the drag handles need `accessibilityAction` for move up/down (and the "I'd rather drag than use arrows" wish still deserves keyboard ⌥↑/⌥↓). Dynamic Type: several `.font(.caption2)` captions at 9–10 pt on dark glass fail contrast; check with the Accessibility Inspector. Colour-only state (green/orange/red dots) needs a glyph or word.
- **Keyboard.** No ⌘-shortcuts for Send/Publish; add ⌘↩ on the page's primary action and ⌘R for "Check again".
- **Status bar.** `lineLimit(1)` on `statusLine` truncates most `say()` strings (the longest are 180+ characters). With the inline stepper the status bar can show only the last short result.

---

## 7. Quick wins vs. redesign

| # | Change | Effort | Impact | Where |
|---|---|---|---|---|
| 1 | Rename buttons: "Refresh / set up" → "Find modules"; "Recover display" → "Fix black screen"; "Publish & rotate"/"Publish to VivoCube" → "Send to cube"; "Publish Deckhand page…" → "Publish page"; "Refresh cover only" → "Update clock picture"; "Screen On/Off" → a toggle "Screen" | S | High | ContentView.swift:217, 299, 301, 406–411, 689 |
| 2 | Replace the KnobKey/DotKey prose with a read-only bindings table from `moduleBindings()` (+ "last used n s ago") | S | High | ContentView.swift:466–484 (`KnobKeyView`, `DotKeyView`); AppModel+Pages.swift:157 |
| 3 | Show the device twin on the VivoCube page: card the device reports (property 9 → `vivoLayerImages`), "Card n of m", ◀ ▶ calling `setLayer`; move the 13-widget preview popup to the Widgets page | M | High | ContentView.swift:582 (`CubePreview`); AppModel+Themes.swift `readLayerWidget`/`setLayer`; StatusView.swift:52–69 (reuse) |
| 4 | Device status strip (reachable · link · showing · last applied · one fault + action) at the top of every device page, driven by `runDoctor` items | M | High | new `DeviceStrip` view used by `Header` (ContentView.swift:863); AppModel+Doctor.swift |
| 5 | Inline publish stepper (render → upload → applying → showing) replacing `say()` narration for the two publish paths | M | High | AppModel+Themes.swift:21–81 (`startThemeRotation`), AppModel+Pages.swift:57–148 (`publishDeckhandPage`); add a `PublishProgress` enum on AppModel |
| 6 | VivoCube: picked list (ordered, max 6, drag, remove) instead of 13 checkboxes; make `vivoThemes` ordered (stop re-sorting by `Theme.allCases` in `setEnabled`) | M | High | ContentView.swift:654–711 (`RotationView`); AppSettings.swift:94–99 |
| 7 | Replace "rotation" controls with a radio "Stay on one card / Switch every [30 s] / Switch only by button"; remove "Stop" | S | High | ContentView.swift:678–699 |
| 8 | Confirm the CoreBar publish only on first publish or when foreign pages exist; otherwise publish directly; alert button "Replace pages" | S | Medium | ContentView.swift:372–377; AppModel+Pages.swift:57 |
| 9 | Move AccuWeather key + paid note into a disclosure on the "Weather (bar's own)" card row; remove the orange paragraph | S | Medium | ContentView.swift:347–353 |
| 10 | Remove "List pages", "Refresh preview", the 9-size "Panel size test…" menu; keep one "Send test picture" under a Maintenance disclosure | S | Medium | ContentView.swift:281, 304, 429–438 |
| 11 | Collapse Display (screen toggle, Restart, Fix black screen) and Network (Wi-Fi) into "▸ Maintenance" on the VivoCube page, below the cards list | S | Medium | ContentView.swift:404–438 |
| 12 | Sidebar: single selection model, fixed module order by type, remove "Scan for CoreBars"/toolbar Scan when paired, device popover with Add/Forget; drop "Add by IP…" dev copy | M | Medium | ContentView.swift:46–147 (`SidebarView`), 22–29 (toolbar), 153–173 (`AddByIPSheet`) |
| 13 | Replace the always-on `ActivityLog` split with an inspector toggle; status bar as `safeAreaInset`, not an overlay | S | Medium | ContentView.swift:220–227, 399–451, 30, 934–949 |
| 14 | Status page: auto-run + timer, severity ordering, action button per red/orange row, plain-English details, don't parse the "Showing" string | S–M | High | StatusView.swift; AppModel+Doctor.swift:19–93 |
| 15 | Status report: add versions, permissions, bindings, cover-refresh age, "Deckhand page present" check, last 30 wire-log lines | S | Medium | AppModel+Doctor.swift:96–107 |
| 16 | Scrub protocol ids from all user-facing strings (`say()` calls with 30710/1108/property 9/code 200/"hotspotIp") | S | Medium | AppModel+Pages.swift:23–24, 132; AppModel+Themes.swift:46, 78, 144, 156–157; AppModel+VivoWiFi.swift:13; CoreBarSession.swift upload errors |
| 17 | CoreBar page: side-by-side "On the page / Add a card" with a schematic 1424×280 preview strip showing the 4-card cut-off; remove the three order/scroll captions | M | Medium | ContentView.swift:308–346 |
| 18 | Custom image becomes a card type in the Add popover (occupies a slot) instead of "Push a custom image" | M | Medium | ContentView.swift:443–446; AppModel.swift:266 (`chooseAndUploadImage`); Theme.swift |
| 19 | First-run wizard (Find → Approve with countdown → Find modules → Put something on it) replacing `Unavailable` + sidebar Pair | L | High (for new users) | ContentView.swift:896–910, 36–40 (pairing sheet); AppModel.swift:122–187 |
| 20 | Convert device pages to `Form(.grouped)` with `Section` footers; one `.borderedProminent` primary per page; accessibility labels on icon buttons; ⌘↩ on the primary action | M | Medium | ContentView.swift (all device views), SettingsView.swift pattern as reference |
| 21 | Editable bindings for KnobKey/DotKey (popup per control; marks page dirty; ships with page publish) | L | High | new `BindingsEditor`; AppModel+Pages.swift:157–197; AppSettings (persist bindings) |
| 22 | Global "Publish changes" toolbar button that appears when the cube list, card list or bindings are dirty, and does the right publish(es) | M | Medium | ContentView.swift:22 (toolbar); AppModel (dirty flags per target) |

Suggested first sprint (all S/M, no protocol work): 1, 2, 3, 7, 8, 9, 10, 11, 14, 16. That alone removes the photo trips for the common cases, deletes most of the jargon, and makes the KnobKey/DotKey pages truthful.
