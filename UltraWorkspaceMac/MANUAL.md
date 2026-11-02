# Deckhand — User Manual

Deckhand is an independent, community macOS app for Sanytron **UltraBar X** hardware (CoreBar + QuantumLink modules: VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card). Not affiliated with or endorsed by Sanytron.

---

## 1. Install

1. Open **Deckhand.dmg** and drag **Deckhand** onto the **Applications** folder.
2. The first launch is blocked by macOS because the app is ad-hoc signed, not signed with a paid Apple Developer certificate. To open it the first time:
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

## 3. Pair your CoreBar

1. Open the app and press **Scan** (toolbar) or **Scan for CoreBars** in the sidebar. The scan listens for about 8 seconds.
2. Your CoreBar appears under **CoreBars** (e.g. `ultrabar`). Click **Pair**.
3. On the CoreBar's screen, tap **Approve** within 30 seconds.
4. Done — the CoreBar is now paired. The pairing token is stored on your Mac (in a protected, user-only file in Application Support), and the device's certificate is pinned, so a later impostor on the network can't reuse your token.

> The token is deliberately **not** kept in the macOS Keychain. Because this app is ad-hoc signed, the Keychain would re-prompt for your login password on every launch; the file avoids that. A future notarized release can move it back to the Keychain.

### Add by IP (when the scan can't see the CoreBar)

If the CoreBar is on another subnet, behind a VPN, or broadcast discovery is blocked, use the sidebar's **Add by IP…**. Enter the CoreBar's IP address (look it up on the device under Wi-Fi); Deckhand sends the discovery probe directly to that address and then pairs as usual. This is also how you connect to the mock CoreBar used for testing.

---

## 4. Modules — wake them before scanning

**Tip: tap the CoreBar's screen to wake it, and make sure your modules are attached and awake, *before* you scan for modules.** Listing modules is a live scan of the magnetic (and wireless) bus, and a module that has gone to sleep — the **DotKey** is the usual culprit — can be missed. The app remembers modules it has seen before and merges them back in on the next scan, so a one-time sleep won't permanently drop a module, but a fresh scan with everything awake gives the most reliable result.

To (re-)scan: open your CoreBar's **Overview** page and press **Refresh / set up**. The scan takes about 16 seconds and also writes the found modules into the CoreBar's configuration so they can be controlled. Each module shows a green dot when it's online.

---

## 5. Using the app

Deckhand is one window with a sidebar on the left:

- **CoreBars** — discovered and paired CoreBars, plus **Scan for CoreBars** and **Add by IP…**.
- **Your CoreBar** (named after the device) — **Overview**, then one entry per module: **VivoCube**, **SenseCube**, **KnobKey**, **DotKey**.
- **Configure** — **Widgets**, **People**, **Logs**.
- **About Deckhand** at the bottom. The **Settings** gear and **About** are also in the toolbar.

### CoreBar → Overview
- **Live link** (status bar, bottom right) — Deckhand keeps one connection open to the selected CoreBar and answers what the device asks: Mac CPU/memory/storage/network for the CoreBar's own cards, volume for the KnobKey, and button presses from PC_CONTROL cards (open a website, play/pause Music, next VivoCube widget). “Live link · 12 answered” means it is working; “Reconnecting” means the CoreBar is unreachable.
- **Cards on the Deckhand page** — tick which of the CoreBar's own cards the Deckhand page shows (clock with Deckhand cover, weather, world clock, SenseCube temperature/humidity, Mac CPU/memory/storage/network, and two button cards). Cards marked *needs Mac* only update while Deckhand runs; the others keep running when the Mac is off.
- **Two weather options** (Overview → CoreBar pages): (1) *Clock + Deckhand weather cover* — Deckhand's own weather (Open-Meteo, free) drawn on the clock card and refreshed every hour while the Mac is on; (2) *Weather — CoreBar's own card* — fetched by the CoreBar itself from **AccuWeather, which is not free**: the developer portal gives a 14-day trial, after that it is a paid subscription (the old free tier was retired in 2025). Paste the key in **AccuWeather API key** and publish; remove it (and untick the card) before the trial ends if you don't want to pay.
- **Modules on the Deckhand page** — KnobKey turns change the Mac's volume (button = mute); DotKey buttons 1 and 2 switch the VivoCube to widget 1/2 directly on the device, button 3 steps to the next widget, a long press returns to the standard page.
- **CoreBar pages** — **List pages** asks the CoreBar which pages exist. **Publish Deckhand page…** (asks for confirmation) rewrites the pages to: the standard page (clock + weather) and a *Deckhand* page whose clock card shows Deckhand's picture (weather & time, refreshed with **Refresh cover only**). **Show** next to a page switches the big screen to it. There is no full-screen image on the CoreBar — pages are strips of the device's own cards.
- **Widget rotation (CoreBar)** — the controls are visible, but publishing to the big screen persistently is not implemented yet; your selection is saved for when it is. Note that the CoreBar's pages are strips of its own cards (clock, weather, buttons…), not full-screen pictures: when this lands, Deckhand's image will appear as the clock card's picture, and full-screen stays a one-shot preview.
- **Modules** — every module the CoreBar reports, with a green dot for online, and an **Open** link to its page. **Refresh / set up** re-scans (see section 4).
- An activity log on the right shows what the app is doing.

> ⚠️ **If you also use the official UltraWorkSpace app**: its *Deploy project* rewrites the whole CoreBar — pages, automations, module setup — and deletes every image file other apps uploaded to it, including Deckhand's. Likewise, once Deckhand writes pages it will replace what the official app deployed. Use one app per CoreBar, or expect to re-publish from Deckhand after each official deploy.

### VivoCube
- A live preview of the current widget.
- **Display** — **Screen On**, **Screen Off**, **Reboot**, **Recover display**.
  - **Screen Off** is remembered by the CoreBar: it re-applies it to the cube after every reboot, reconnect or widget update until you press **Screen On** again. So don't use Screen Off while a rotation is running, or the cube stays dark.
  - **Recover display** is for a cube that stays black: the CoreBar also remembers which layer/widget the cube should show, and if that no longer exists in the last package it keeps re-selecting nothing. The button reads back that state, turns the screen on and points the cube at the first widget again. Use it before re-publishing.
- **Refresh / set up once after updating** — module bindings (DotKey → VivoCube widgets, SenseCube cards) rely on a module id that older Deckhand versions did not write to the CoreBar; press **Refresh / set up** once, then publish the Deckhand page again.
- **Network** (VivoCube page) — shows which Wi-Fi the cube is on. Fresh cubes sit on the CoreBar's own hotspot, which the CoreBar switches off when idle; widget uploads then fail with “hotspotIp is empty” until the CoreBar reboots. **Set VivoCube Wi-Fi…** joins the cube to your own 2.4 GHz network (the CoreBar must be on the same network); the password goes to the cube only and is not stored on the Mac. After that, uploads travel over your network.
- **Cards on the Deckhand page** — the cards on the page are listed in screen order; **drag** them to reorder, use − to remove and + (under *Available*) to add; publish afterwards.
- **Panel size test…** (diagnostic) — pushes a test pattern of a chosen size with a red frame at the edge. The VivoCube panel is 240 × 240 (verified): the 240 pattern fills it, larger ones are not shown. Useful only to check that uploads still work.
- **Widget rotation** — tick the widgets you want on this cube and set the interval (15 s, 30 s, 1 min, 3 min). With one widget ticked the button reads **Publish to VivoCube**; with several it reads **Publish & rotate** and a **Stop** button appears while the rotation runs. How it works: all ticked widgets (up to 6) are sent to the cube **once** as separate layers; after about 10 seconds for the cube to apply them, Deckhand only tells it which layer to show at each interval — the cube isn't re-flashed every step. The contents (weather, music…) are refreshed every few minutes. The log line "Package accepted — waiting 10 s" is normal: the CoreBar acknowledges the upload immediately, the cube then downloads and applies it itself over Wi-Fi.
- **Push a custom image** — **Choose image…** picks any picture; it's rendered to the cube's pixel format (opaque; transparency is flattened) and uploaded. If a module isn't registered yet, the app provisions it automatically and retries. If the upload is refused with "busy" or "not connected to the network", the cube's own Wi-Fi link is the problem, not the image: the cube fetches new images over Wi-Fi, not over the magnetic connector.

### SenseCube
Shows the live **temperature**, **humidity** and **ambient light** read from the sensor, polled every 5 seconds while the page is open (there is also a **Refresh** button). Presence (mmWave radar), sound level and vibration are handled on the device only and cannot be read over the network protocol, so they are not shown.

### KnobKey and DotKey
Information pages for now. The CoreBar does not send raw knob or key events to the Mac; it only sends pre-mapped requests (volume up/down, "run this on the PC", "how busy is the CPU?") once a control is bound to a "PC" target in the device profile, and the Mac has to answer each of them over a connection it keeps open. Hot-key combinations never go through the Mac app at all — the CoreBar types them itself as a USB keyboard over the PC-LINK cable. Writing that profile and keeping that connection open are on the roadmap, so **KnobKey → volume** and **DotKey → Mac actions** are not available yet.

### Widgets
Pick a widget on the left to see its description and settings. All 13 widgets ship today: **Weather & time**, **Music (album art)**, **Claude Code monitor**, **CPU & memory**, **Network**, **Battery & power**, **Storage**, **World clock**, **Crypto ticker**, **Calendar**, **Disk I/O**, **Top CPU**, **Uptime**.

- **Weather & time** — location (**Same as this Mac** or **Manual** city / coordinates), units (°C / °F) and the 24-hour clock switch live here. See section 6.
- **Music (album art)** — the Apple Music remote: play/pause, previous, next, volume − / +, with the current track shown above the buttons. Publish the Music widget to a VivoCube from that cube's page.

Where a widget appears, and how fast it rotates, is set per device: sidebar → **VivoCube** (or **CoreBar**) → **Widget rotation**.

### People
Save contacts; each gets one-tap **Teams chat / call**, **FaceTime**, **Mail**. Stored locally on your Mac.

### Logs
Every message between this Mac and the CoreBar, with the pairing token redacted. Useful when reporting a problem.

### Settings (gear, toolbar)
- **CoreBar** — name, serial and address of the selected CoreBar.
- **Connecting** — the network and USB-port guidance from section 2.
- **On the CoreBar itself** — things the protocol can't set from the Mac: **time & timezone** (set on the CoreBar, kept by NTP), **Wi-Fi**, **Bluetooth**.
- **About** — a short note; widget settings are in **Widgets**, rotation on each device's page.

### About
**About Deckhand** (sidebar bottom or toolbar) shows the version, a link to the repository and contact, and the license (MIT).

---

## 6. Weather

The weather widget uses **Open-Meteo** (free, no API key). Set your location in **Widgets → Weather & time**:

- **Same as this Mac** uses macOS Location (macOS will ask for permission). If Location access isn't granted, the app falls back to the manual city if you entered one, and otherwise to approximate **IP geolocation** (ipwho.is) so the widget still works.
- **Manual** takes a city name, or latitude/longitude for an exact spot.

This is independent of the CoreBar's own built-in AccuWeather widget, which needs its own API key set on the device.

---

## 7. Troubleshooting

- **"No CoreBars found"** — CoreBar and Mac must be on the same Wi-Fi; grant **Local Network** permission (System Settings → Privacy & Security → Local Network → Deckhand); press Scan again. If broadcast is blocked, use **Add by IP…**.
- **App won't open (unidentified developer)** — right-click → Open (see Install), once.
- **A module is missing after a scan** — tap the CoreBar screen to wake everything, make sure the module is attached and powered, then press **Refresh / set up** (see section 4).
- **"Module not accepted" on an image push** — the app auto-provisions and retries; if it still fails, re-scan modules first.
- **VivoCube upload says "busy" or "not connected to the network"** — the cube downloads new images over its own Wi-Fi link. Check the cube's Wi-Fi in the official app or on the CoreBar, then try again; wait at least 10 seconds between uploads.
- **VivoCube stays black** — press **Recover display** on the VivoCube page (then re-publish if needed). Avoid **Screen Off** while a rotation runs. If it is still black, press **Reboot** on the VivoCube page and publish again.
- **Pushed image looks off** — re-publish the widget; if a custom image still looks wrong, try a square source image (Deckhand renders 240 × 240; transparency is flattened).
- **The Deckhand page shows no picture on the clock card** — press **Refresh cover only** (re-uploads `deckhand/cover.png`); if the official app deployed in between, its Deploy deleted Deckhand's images — publish the page again. There is no error message because the CoreBar does not acknowledge previews.
- **My CoreBar images / pages disappeared** — most likely the official UltraWorkSpace app deployed in between; it erases other apps' files. Re-publish from Deckhand.
- **CoreBar clock wrong** — set time/timezone on the CoreBar itself (it uses NTP); the Mac app can't push time.
- **Weather shows the wrong place** — allow Location access, or set a manual city in **Widgets → Weather & time**.

---

## 8. What's next (roadmap)

Persistent pages on the CoreBar's big screen (the CoreBar's own cards configured from the Mac, with Deckhand's image as the clock card's picture), KnobKey → volume and DotKey → Mac actions (both need the profile-write path and a permanently open connection), presence-based wake, module OTA firmware updates, measuring the VivoCube's real panel size, a notarized release, and a Stream-Deck-style widget marketplace. This section can lag behind the code; the current status is in `docs/ROADMAP.md` in the repository.

Support: this is community software — file issues at https://github.com/DeNoronha/UltraWorkspaceMac/issues.
