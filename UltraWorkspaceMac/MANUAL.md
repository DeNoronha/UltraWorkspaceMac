# Deckhand — User Manual

Deckhand is an independent, community macOS app for Sanytron **UltraBar X** hardware (CoreBar + QuantumLink modules: VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card). Not affiliated with or endorsed by Sanytron. The vendor's product page, with photos of the bar and each module, is at https://www.sanytron.com/products/ultrabar-x-the-modular-desktop-command-center.

---

## 1. Install

1. Open **Deckhand.dmg** and drag **Deckhand** onto the **Applications** folder.
2. A notarized build (the DMG's "Read Me First" says so) opens like any other app. An ad-hoc-signed build — the first prerelease, or one you built yourself without a Developer ID — is blocked by macOS on the first launch. To open it the first time:
   - In **Applications**, **right-click** (Control-click) **Deckhand** → **Open** → **Open** in the dialog.
   - If that doesn't offer "Open": **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Deckhand.
   - You only do this once.
3. On first scan macOS asks for **Local Network** permission — click **Allow** (the app can't find the CoreBar otherwise). On first use of the Music controls (Widgets → Music) it asks for **Automation** permission to control Music — click **OK**. The Calendar widget asks for **Calendar** access the first time you enable it.

Deckhand runs on macOS 13 or later. On macOS 26 and later it uses the system's Liquid Glass styling; on older versions it looks like a standard macOS app.

---

## 2. Connect the hardware

### Power & the USB cable — read this first

The CoreBar has **two** USB ports. They are not interchangeable:

| Port | Use it for | Rule |
|------|------------|------|
| **USB-OTG** | **Power / charging** — a fast charger (PD / QC, 9–20 V) or the 12 V adapter. | Fast charging is OK here. |
| **PC-LINK** | **Connecting to your computer** (and 5 V power from the computer). | **5 V only.** A computer's USB port or a plain 5 V adapter. |

> ⚠️ **Never plug a phone/MacBook/laptop PD fast-charger into PC-LINK.** PC-LINK is 5 V-only; a 9–20 V charger will permanently damage the mainboard and can overheat. Connecting PC-LINK to a **computer USB port is safe and correct** — that's what it's for. A computer port supplies 5 V and never forces higher voltage into a device.

So: **CoreBar PC-LINK → your Mac's USB port** is the right, safe connection. Leave it on PC-LINK; don't move it to USB-OTG for the Mac link.

### Network (how the app actually talks to the CoreBar)

Deckhand controls the CoreBar over **Wi-Fi / your local network**, not over the USB cable. Make sure:

- The CoreBar is connected to the **same Wi-Fi / LAN** as your Mac (check the CoreBar: **Control Center → Wi-Fi**).
- The USB cable can stay connected for power, but discovery and control run over the network.

The same guidance is shown in the app under **Settings → Connecting**.

---

## 3. Connect your CoreBar

The first time, Deckhand shows **Connect your UltraBar**:

1. **Find the bar** — Deckhand looks on your network for about 8 seconds (a progress bar shows it). Your bar appears with a **Pair** button. macOS asks for *Local Network* access the first time; if you declined, use **Local Network permission…** to allow it. Can't see the bar (other subnet, VPN)? **Connect by address…** takes its IP address (shown on the bar under Settings → Network).
2. **Approve on the bar** — press **Pair**; the bar shows an Approve button for 30 seconds (Deckhand shows the countdown). Tap it.
3. Deckhand then finds the modules on its own and opens the **CoreBar**.

The pairing key is stored in a protected, user-only file in Application Support, and the bar's certificate is pinned, so an impostor on the network can't reuse your key. The paired bar is shown at the top of the sidebar; its menu has **Add another CoreBar…**, **Find modules** and **Forget this CoreBar…**.

---

## 4. Modules — wake them before looking

**Tap the bar's screen and press a DotKey key before you press Find modules.** Finding modules is a live scan of the magnetic bus, and a module that has gone to sleep — usually the **DotKey** — can be missed. Deckhand remembers every module it has ever seen on your bar and keeps it in the bar's configuration, so a one-time sleep won't drop a module; a scan with everything awake just gives the most reliable result.

**Find modules** is in the bar's menu (top of the sidebar), under **Maintenance** on the CoreBar page, and in the sidebar when no modules are known yet. The scan takes about 16 seconds and also registers the modules on the bar so they can be controlled. A module that did not answer is marked *asleep* in the sidebar.

---

## 5. Using the app

One window, a sidebar on the left, grouped by what you want to change:

- **Screens** — **CoreBar** (the strip on the bar) and **VivoCube** (the small square screen module).
- **Controls** — **KnobKey**, **DotKey**: what the knob and keys do.
- **Sensors** — **SenseCube**.
- **Library** — **Widgets** (the cards Deckhand can draw) and **People**.
- **Health** — **Status** and **Logs**.

Every device page starts with a **status strip**: whether Deckhand is connected and answering the bar, what the device is showing right now (read back from the device, not assumed), when something was last sent, and — only when something is wrong — one sentence and one button that fixes it ("The cube is not on Wi-Fi — Set cube Wi-Fi…", "The cube's screen is off — Turn on", "The Deckhand page is gone from the bar — Publish page"). The **Activity** list (toolbar button) shows what Deckhand did; the strip shows what the device *is*.

### CoreBar
The bar's big screen shows a page: a row of the bar's own cards. About four fit; more scroll sideways. There is no full-screen picture — Deckhand's own picture (weather & date, free, refreshed hourly) is the **Clock** card's picture.

- **Preview** — drawn from your card list, one screenful (four cards) at a time; ◀ ▶ step through the screenfuls the bar scrolls sideways through. It is not read back from the bar.
- **Cards on the bar** — drag to reorder, ✕ to remove, **Add a card…** below the list. ⌁ marks cards fed live by this Mac (CPU, memory, storage, network, the two buttons): they update only while Deckhand runs; the others keep running when the Mac is off.
- **Weather (bar's own)** is drawn by the bar from **AccuWeather, which is not free** (14-day trial, paid afterwards). Press **Key…** on that row to paste the key; it is sent to the bar with the next publish. Deckhand's own weather on the Clock card costs nothing.
- **Publish page** (⌘↩) — draws the clock picture, uploads the button icons, writes the pages and shows the Deckhand page; the steps are shown under the button. Deckhand asks for confirmation only when it matters: the first time, or when the bar has pages made in the official app (those would be removed — the bar cannot send pages back). The knob and keys get their bindings with every publish (see Controls).
- **Start page** — publishing marks the Deckhand page as the bar's start page, so the bar boots into it; Deckhand also selects it again every time it (re)connects to the bar. Use **Show** in *Pages on the bar* to switch to Standard Mode for a moment.
- **Pages on the bar** / **Maintenance** — the page list, **Find modules**, **Re-read pages**, **Redraw preview**. The official app's Deploy removes Deckhand's pictures; publish again afterwards.

### VivoCube
Shows one card at a time.

- **On the cube now** — the card the cube *reports* it is on, with the picture Deckhand sent for it, "Card 2 of 4" and ◀ ▶ to step through them from the Mac (the DotKey and the bar's button do the same on the device). A dark picture with "Screen off" means the screen is off; an orange Wi-Fi note means the cube is not connected and may still show an old picture.
- **Cards on the cube** — an ordered list of up to 6 cards: drag to reorder, ✕ to remove, **Add a card…** to add (the **Picture** card asks for an image file). The order here is the order on the cube.
- **Switching** — **Stay on one card**, **Switch every** 15 s / 30 s / 1 min / 3 min (a timer on this Mac; Deckhand must be open), or **Only with the DotKey or the bar's button**.
- **Send to cube** (⌘↩) — draws the cards, uploads them as one package, waits about 10 seconds for the cube to apply it and shows card 1. The steps appear under the button; a failure is one sentence with the next thing to do. The cards' contents are redrawn every few minutes while timed switching runs.
- **Maintenance** — **Cube screen** switch (off stays off until you turn it on), **Fix black screen** (screen on + card 1; use it when the cube shows black after a reboot), **Restart cube**, **Send test picture**, and **Wi-Fi**: which network the cube is on and whether it is connected. Fresh cubes sit on the bar's own hotspot, which the bar switches off when idle; uploads then cannot reach the cube. **Set cube Wi-Fi…** joins it to your own **2.4 GHz** network (a combined 2.4/5 GHz name may not work; the bar must be on the same network); the password goes to the cube only.

### SenseCube
Live **temperature**, **humidity** and **light**, read every 5 seconds while the page is open. **Add all five** puts the Temperature, Humidity, Light, Presence and Sound level cards on the CoreBar page (the bar draws them itself). Presence (radar) and sound level are push-only: the bar can show them, Deckhand cannot read them. Vibration is only an event on the bar.

### KnobKey and DotKey
What each control does, as it is bound today: knob **turn → Mac volume**, **press → mute**; DotKey **key 1 / 2 → cube card 1 / 2** (switched on the bar itself), **key 3 → next cube card**, **hold key 3 → Standard page**. These bindings are part of the CoreBar page and are active while that page is on the bar; publish it once to activate them. Changing them is planned.

### Widgets
Two sections: **For the VivoCube** (pictures Deckhand draws — only cards that stay valid for 5 minutes, because the cube gets a new picture every 5 minutes at most; live readings and clocks are deliberately not offered there) and **For the CoreBar** (cards the bar draws itself and updates live; add them to the Deckhand page from here or from the CoreBar page). The cube cards Deckhand can draw, with a preview and settings: **Weather**, **Music (album art)**, **Claude Code monitor**, **Crypto**, **Calendar**, **Date** and **Picture** (your own image). **Add to the cube** puts the selected card in the cube's list. A third section, **Apps on the bar**, lists one **Open <app>** card per app installed on the bar (Sonos, UltraNotes, UltraBar Radio, …): on the page it is the app's own icon, and tapping it opens that app on the bar — this works on the hardware (confirmed 2026-11-03). The list is read from the bar when Deckhand connects and after **Re-read pages**; Home Assistant never appears in it (the bar keeps it out of the app list).

- **Weather** — location (**Same as this Mac** or **Manual**) and units; current conditions only, no clock. See section 6.
- **Music** — play/pause, previous, next and volume for Apple Music.

### Two very different screens

- **VivoCube (240×240).** Deckhand draws every pixel: each card is a picture rendered on the Mac and sent as a package (up to 6 cards). The cube only shows what was last sent. Cards are **redrawn and re-sent every 5 minutes at most** (longer when the switch interval × number of cards exceeds that), so "live" numbers such as CPU, network or token counts are snapshots, not a live meter. Cards that change slowly (weather, calendar, crypto day chart, date) suit the cube; a per-second gauge does not.
- **CoreBar (1424×280).** The bar draws its own fixed-size cards (clock, weather, world time, timer, CPU, memory, network, SenseCube, PC buttons, scenes) and updates them live from the data the bar pulls over the link (CPU every 3 s, network every 5 s). Deckhand cannot place its own pictures on the bar; the only picture it can inject is the **cover of the clock card** (a rounded square, with a blurred copy as the card background), which is where the "Clock picture" comes from. A cube card cannot be shown on the bar one-to-one, nor a bar card on the cube. Filling the whole bar screen is only possible through the bar's screensaver app, which Deckhand does not control.

### Apps

Sidebar → Library → **Apps**. Two lists. **Installed** is everything the bar reports as installed (also screensavers and apps that are not in the marketplace): version, an orange **update** tag when the marketplace has a newer version, **Update** (blue), **Remove** (red outline), and **Web UI** for apps that serve their own web page on the bar (Home Assistant, UltraNotes, UltraBar Radio). **Marketplace** lists only what is not installed yet, with **Install**: the bar fetches and installs the app itself (it needs internet; one at a time, about ten seconds). Apps the bar offers as a page card then appear under Widgets → Apps on the bar; adding them to the page is done there or on the CoreBar page, not here.

### People
Save contacts; each gets one-click **Teams chat / call**, **FaceTime**, **Mail**. Stored locally on your Mac.

### Status
Asks the bar and its modules what they are doing (and again every 30 seconds while open): connection, pages on the bar, the cube's Wi-Fi, screen and current card, the last upload result, SenseCube readings, the KnobKey link, modules seen before but missing now, and whether weather resolves. Problems come first, each with its one button. **Copy report** puts everything — plus your card lists and the last log lines — on the clipboard as text: paste that instead of taking a photo of the device.

### Logs
Every message between this Mac and the bar, with the pairing key, the cube Wi-Fi password and the weather key redacted; the file is capped at 5 MB.

### Settings (sidebar → Deckhand → Settings)
Name, serial and address of the bar; the connection and USB-port guidance; what can only be set on the bar itself (time & time zone, Wi-Fi, Bluetooth).

### About
**About Deckhand** (sidebar → Deckhand) shows the version, repository link and license (MIT).

---

## 6. Weather

The weather widget uses **Open-Meteo** (free, no API key). Set your location in **Widgets → Weather**:

- **Same as this Mac** uses macOS Location (macOS will ask for permission). If Location access isn't granted, the app falls back to the manual city if you entered one, and otherwise to approximate **IP geolocation** (ipwho.is) so the widget still works.
- **Manual** takes a city name, or latitude/longitude for an exact spot.

This is independent of the CoreBar's own built-in AccuWeather widget, which needs its own API key set on the device.

---

## 7. Troubleshooting

- **Firmware matters.** The bar's launcher version is the `ver` in the sidebar/discovery (for example `1.0.9(9)`). Cards added in later releases do not exist on older launchers: on **1.0.3** the five SenseCube cards never appear, on **1.0.9** they do. Settings → About on the bar may show no update even when one exists; the release APKs are on the vendor's GitHub release page and can be installed over ADB (see `docs/vendor_docs/` and PROTOCOL.md).
- **A hiss or click from the bar when you tap Next card or Play / pause** is the launcher's own tap sound (new in 1.0.9, played at 30 % of the bar's media volume). It ignores the bar's "Click sound" switch; lower the bar's media volume under Settings → Sound on the bar if it bothers you.
- **SenseCube temperature reads several degrees too high** (and humidity too low): the cube warms up on the bar. SenseCube firmware V2 adds a calibration; the OTA file is in the vendor release.

- **"No CoreBars found"** — CoreBar and Mac must be on the same Wi-Fi; grant **Local Network** permission (System Settings → Privacy & Security → Local Network → Deckhand); press **Look again**. If broadcast is blocked, use **Connect by address…**.
- **App won't open (unidentified developer)** — right-click → Open (see Install), once.
- **A module is missing after a scan** — tap the CoreBar screen to wake everything, make sure the module is attached and powered, then press **Find modules** (see section 4).
- **"Module not accepted" on an image push** — the app auto-provisions and retries; if it still fails, re-scan modules first.
- **VivoCube upload is refused ("error 4")** — the cube itself says it is not on Wi-Fi, usually because it is stuck at "still connecting" (the strip and Maintenance → Wi-Fi show this). Deckhand now re-sends the cube's own Wi-Fi settings before every upload when it sees that state, which completes the join; you can also press **Set cube Wi-Fi…** and send the same network again. Wait until the status reads "connected", then send the cards again.
- **VivoCube upload says "busy" or "hotspot has no IP"** — the bar's hotspot is down, so it has no path to the cube. Wake the bar (press a key) or check its hotspot, then try again; wait at least 10 seconds between uploads.
- **VivoCube stays black** — open the VivoCube page: the status strip names the cause (screen off, not on Wi-Fi, or pointing at a card that no longer exists) with a button that fixes it; **Maintenance → Fix black screen** does the same by hand (then re-publish if needed). Avoid **Screen Off** while a rotation runs. If it is still black, press **Restart cube** under Maintenance on the VivoCube page and publish again.
- **Pushed image looks off** — re-publish the widget; if a custom image still looks wrong, try a square source image (Deckhand renders 240 × 240; transparency is flattened).
- **The Deckhand page shows no picture on the clock card** — press **Update picture** on the Clock card (re-uploads `deckhand/cover.png`); if the official app deployed in between, its Deploy deleted Deckhand's images — publish the page again. There is no error message because the CoreBar does not acknowledge previews.
- **My CoreBar images / pages disappeared** — most likely the official UltraWorkSpace app deployed in between; it erases other apps' files. Re-publish from Deckhand.
- **CoreBar clock wrong** — set time/timezone on the CoreBar itself (it uses NTP); the Mac app can't push time.
- **Weather shows the wrong place** — allow Location access, or set a manual city in **Widgets → Weather**.

---

## 8. What's next (roadmap)

Choosing your own KnobKey and DotKey bindings (today they are fixed), presence-based wake, module OTA firmware updates, installing apps on the bar from Deckhand (today only from the bar's own Marketplace or the `kitcheck app` tool), a notarized release, and a Stream-Deck-style widget marketplace. This section can lag behind the code; the current status is in `docs/ROADMAP.md` in the repository.

Support: this is community software — file issues at https://github.com/DeNoronha/UltraWorkspaceMac/issues.
