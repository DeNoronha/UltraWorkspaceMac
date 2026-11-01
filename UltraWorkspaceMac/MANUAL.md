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
- **CoreBar screen** — a live preview of what the big (1424 × 280) screen would show, and the button **Show this on the CoreBar screen now**. This is a one-shot, non-destructive preview: the CoreBar displays the image full-screen immediately, nothing is saved, and your pages on the device are untouched. Today the preview shows the weather-only wide layout.
- **Widget rotation (CoreBar)** — the controls are visible, but publishing widgets persistently to the big screen is not implemented yet; your selection is saved for when it is.
- **Modules** — every module the CoreBar reports, with a green dot for online, and an **Open** link to its page. **Refresh / set up** re-scans (see section 4).
- An activity log on the right shows what the app is doing.

### VivoCube
- A live preview of the current widget.
- **Display** — **Screen On**, **Screen Off**, **Reboot**.
- **Widget rotation** — tick the widgets you want on this cube and set the interval (15 s, 30 s, 1 min, 3 min). With one widget ticked the button reads **Publish to VivoCube**; with several it reads **Publish & rotate** and a **Stop** button appears while the rotation runs.
- **Push a custom image** — **Choose image…** picks any picture; it's rendered to the cube's pixel format and uploaded. If a module isn't registered yet, the app provisions it automatically and retries.

### SenseCube
Shows the live **temperature**, **humidity** and **ambient light** read from the sensor, polled every 5 seconds while the page is open (there is also a **Refresh** button). Presence (mmWave radar), sound level and vibration are handled on the device only and cannot be read over the network protocol, so they are not shown.

### KnobKey and DotKey
Information pages for now. The CoreBar does not send raw knob or key events to the Mac; it only sends pre-mapped messages once a control is bound to a "PC" target in the device profile. Writing that profile from Deckhand is on the roadmap, so **KnobKey → volume** and **DotKey → Mac actions** are not available yet.

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
- **Pushed image looks off** — re-publish the widget; if a custom image still looks wrong, try a square source image (the cube is 240 × 240).
- **CoreBar clock wrong** — set time/timezone on the CoreBar itself (it uses NTP); the Mac app can't push time.
- **Weather shows the wrong place** — allow Location access, or set a manual city in **Widgets → Weather & time**.

---

## 8. What's next (roadmap)

Persistent pages and widget rotation on the CoreBar's big screen, KnobKey → volume and DotKey → Mac actions (both need the profile-write path), presence-based wake, module OTA firmware updates, a notarized release, and a Stream-Deck-style widget marketplace. This section can lag behind the code; the current status is in `docs/ROADMAP.md` in the repository.

Support: this is community software — file issues at https://github.com/DeNoronha/UltraWorkspaceMac/issues.
