# UltraWorkspace for Mac — User Manual

Independent, community macOS app for Sanytron **UltraBar X** hardware (CoreBar + QuantumLink modules: VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card). Not affiliated with Sanytron.

---

## 1. Install

1. Open **UltraWorkspace.dmg** and drag **UltraWorkspace** onto the **Applications** folder.
2. The first launch is blocked by macOS because the app is ad-hoc signed, not signed with a paid Apple Developer certificate. To open it the first time:
   - In **Applications**, **right-click** (Control-click) **UltraWorkspace** → **Open** → **Open** in the dialog.
   - If that doesn't offer "Open": **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to UltraWorkspace.
   - You only do this once.
3. On first scan macOS asks for **Local Network** permission — click **Allow** (the app can't find the CoreBar otherwise). On first use of the Music tab it asks for **Automation** permission to control Music — click **OK**.

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

This app controls the CoreBar over **Wi-Fi / your local network**, not over the USB cable. Make sure:

- The CoreBar is connected to the **same Wi-Fi / LAN** as your Mac (check the CoreBar: **Control Center → Wi-Fi**).
- The USB cable can stay connected for power, but discovery and control run over the network.

---

## 3. Pair your CoreBar

1. Open the app and press **Scan** (top-right).
2. Your CoreBar appears under **Discovered** (e.g. `ultrabar`). Click **Pair**.
3. On the CoreBar's screen, tap **Approve** within 30 seconds.
4. Done — the CoreBar moves to **Paired**. The pairing token is stored on your Mac (in a protected, user-only file in Application Support), and the device's certificate is pinned, so a later impostor on the network can't reuse your token.

> The token is deliberately **not** kept in the macOS Keychain. Because this app is ad-hoc signed, the Keychain would re-prompt for your login password on every launch; the file avoids that. A future notarized release can move it back to the Keychain.

---

## 4. Modules — wake them before scanning

**Tip: tap the CoreBar's screen to wake it, and make sure your modules are attached and awake, *before* you scan for modules.** Listing modules is a live scan of the magnetic (and wireless) bus, and a module that has gone to sleep — the **DotKey** is the usual culprit — can be missed. The app remembers modules it has seen before and merges them back in on the next scan, so a one-time sleep won't permanently drop a module, but a fresh scan with everything awake gives the most reliable result.

To (re-)scan: open your CoreBar and press **Refresh modules**. Each module shows a green dot when it's online.

---

## 5. Using the app

Select your CoreBar in the sidebar. The detail area has these tabs:

### Device
- **Modules** — every module the CoreBar reports (VivoCube, SenseCube, KnobKey, DotKey, PC-Boot) with a green dot for online. Use **Refresh modules** to re-scan (see section 4).
- **Display** (VivoCube) — Screen On / Off, Reboot.
- **Push an image** (VivoCube) — pick any image; it's rendered to the cube's pixel format and uploaded. If a module isn't registered yet, the app provisions it automatically and retries. If an image looks wrong, try a different **Canvas** size.

### Widgets / cards (VivoCube)
Cards render on the Mac and are pushed to a VivoCube, either one at a time or on a rotating carousel (set the interval in Settings). Available cards:
- **Weather & time** — Open-Meteo (free, no API key).
- **Music / now-playing** — album art + track.
- **Claude Code usage monitor**.
- **CPU & memory**.
- **Network up/down**.
- New / experimental: **Battery**, **Storage / Disk**, **World Clock**, **Calendar / next event** (and a **Crypto ticker** is planned).

Enable the cards you want in Settings, then **Start** the display to rotate them, or publish one card on demand.

### Music (Apple Music remote, runs on the Mac)
- Play/pause, next, previous, volume.
- Live now-playing.
- **Push now-playing to a VivoCube** — album art + track shown on the cube; optional auto-update when the track changes.

### People
- Save contacts; each gets one-tap **Teams chat / call**, **FaceTime**, **Mail**.

### Settings (gear, top-right)
- **Weather & location** — "Same as this Mac" or a manual city/coordinates for the weather card.
- **Units & clock** — °C/°F, 24-hour.
- **Cards** — which cards rotate, and the rotation interval.
- **CoreBar** info and status.

---

## 6. Weather

The weather card uses **Open-Meteo** (free, no API key). Set your location in **Settings** — "Same as this Mac" uses macOS Location; if Location access isn't granted, the app falls back to approximate **IP geolocation** so the card still works. You can also enter a city or coordinates manually. (This is independent of the CoreBar's own built-in AccuWeather widget, which needs its own API key set on the device.)

---

## 7. Troubleshooting

- **"No CoreBars found"** — CoreBar and Mac must be on the same Wi-Fi; grant **Local Network** permission (System Settings → Privacy & Security → Local Network → UltraWorkspace); press Scan again.
- **App won't open (unidentified developer)** — right-click → Open (see Install), once.
- **A module is missing after a scan** — tap the CoreBar screen to wake everything, make sure the module is attached and powered, then press **Refresh modules** (see section 4).
- **"Module not accepted" on an image push** — the app auto-provisions and retries; if it still fails, re-scan modules first.
- **Pushed image looks off** — change the Canvas size.
- **CoreBar clock wrong** — set time/timezone on the CoreBar itself (it uses NTP); the Mac app can't push time.

---

## 8. What's next (roadmap)

KnobKey → volume and DotKey button → Mac actions (both need inbound button events from the CoreBar), SenseCube sensor readouts, module OTA firmware updates, setting the CoreBar's own big-screen wallpaper/screensaver, and a Stream-Deck-style widget marketplace. See the project README.

Support: this is community software — file issues on the project's GitHub.
