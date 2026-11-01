# UltraWorkspace for Mac — User Manual

Independent, community macOS app for Sanytron **UltraBar X** hardware (CoreBar + QuantumLink modules). Not affiliated with Sanytron.

---

## 1. Install

1. Open **UltraWorkspace.dmg** and drag **UltraWorkspace** onto the **Applications** folder.
2. The first launch is blocked by macOS because the app isn't signed with a paid Apple Developer certificate. To open it the first time:
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
4. Done — the CoreBar moves to **Paired**, the pairing token is stored in your macOS **Keychain**, and the device's certificate is pinned (so a later impostor can't get your token).

---

## 4. Using the app

Select your CoreBar in the sidebar. The detail area has three tabs:

### Device
- **Modules** — every module/device the CoreBar reports (VivoCube, SenseCube, KnobKey, DotKey, …) with a green dot for online.
- **Display** (VivoCube) — Screen On / Off, Reboot.
- **Push an image** (VivoCube) — pick any image; it's rendered to the cube's pixel format and uploaded. If it looks wrong, try a different **Canvas** size (the VivoCube's native resolution isn't published).

### Music (Apple Music remote, runs on the Mac)
- Play/pause, next, previous, volume.
- Live now-playing.
- **Push now-playing to a VivoCube** — album art + track shown on the cube; optional auto-update when the track changes.

### People
- Save contacts; each gets one-tap **Teams chat / call**, **FaceTime**, **Mail**.

### Settings (gear, top-right)
- **Weather & location** — "Same as this Mac" or manual city/coordinates, used for the app's own weather card.
- **Units & clock** — °C/°F, 24-hour.
- **CoreBar** info and status of device-side settings (time, Wi-Fi, Bluetooth).

---

## 5. Weather

The CoreBar's built-in weather widget uses **AccuWeather**, which needs your own AccuWeather API key and a city set on the device. UltraWorkspace instead plans to render its **own** weather card and push it to a VivoCube using **Open-Meteo** (free, no API key) — set your location in **Settings** and it will use that. (In progress.)

---

## 6. Troubleshooting

- **"No CoreBars found"** — CoreBar and Mac must be on the same Wi-Fi; grant **Local Network** permission (System Settings → Privacy & Security → Local Network → UltraWorkspace); press Scan again.
- **App won't open (unidentified developer)** — right-click → Open (see Install), once.
- **"No devices"** after pairing — press **Refresh modules**. Modules must be attached and powered.
- **Pushed image looks off** — change the Canvas size.
- **CoreBar clock wrong** — set time/timezone on the CoreBar itself (it uses NTP); the Mac app can't push time.

---

## 7. What's next (roadmap)

KnobKey → volume & button → play/pause, DotKey actions, SenseCube sensor readouts, module OTA, a Claude Code monitor widget, Microsoft Teams mute/unmute, and an action marketplace. See the project README.

Support: this is community software — file issues on the project's GitHub.
