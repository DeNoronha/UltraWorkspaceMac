# Deckhand security notes

What Deckhand (the Mac app, the `UltraBarKit` library, the bar apps in `android/DeckhandMonitor` and the release pipeline) protects against, how, and what it does not protect against. The second half is the older defensive review of the **device** (the vendor's Android apps on the CoreBar), which the threat model below builds on. Reviewed end to end by attack path on 2026-11-04; the fixes from that review are marked *(2026-11-04)*. Nothing here claims more than the code does: where a risk is open it says so.

## Threat model

Deckhand sits between three things that do not trust each other: this Mac, a small Android computer on the desk (the CoreBar), and the Wi-Fi they share. The attackers considered:

- **Someone on the same Wi-Fi** — a guest, an IoT device, a compromised laptop. They can send and receive any packet on the LAN, answer broadcasts, open TCP connections to any port and, with the vendor's shared TLS key (finding 1 below), impersonate the bar.
- **A malicious or compromised bar** — the Android device itself: its replies on `:7431`, what it uploads or pushes, the apps on it, and anything the kiosk pages it opens can do.
- **A web page the user visits on the Mac** — which can make cross-site requests to `localhost` and to LAN addresses, and can point a DNS name of its own at the Mac (DNS rebinding).
- **A malicious app or registry entry** in the future marketplace (`site/marketplace/registry.json`).
- **Supply chain** — Swift and Gradle dependencies, GitHub Actions, the site that serves the DMG, the Fluent Emoji assets.
- **Another user or process on the Mac** — file permissions, what sits in Application Support and Caches.
- **Data exposure** — what leaves the Mac, to which hosts, carrying which identifiers, and what the bar can read from the pages the Mac serves.

Out of scope: a compromised macOS user account (it owns everything Deckhand has), and the vendor's cloud (Deckhand never talks to it except for the public app catalogue).

## Attack paths, protections and residual risks

### 1. The LAN: the control channel to the bar (`:7431`, TLS, line-JSON)

**What an attacker can do.** The bar's TLS private key is the same on every unit and ships inside the launcher APK (finding 1). Anyone on the LAN who extracts it can run a fake bar, answer discovery for the real one, and terminate Deckhand's TLS. If Deckhand then sends the pairing token, the attacker has a non-expiring bearer token for the real bar: every page, every module, and the bar's HID path into a USB-connected PC.

**Protections.** Trust-on-first-use pinning: the SHA-256 of the leaf certificate is recorded at pairing (`Store.certSHA256`) and `CoreBarClient` refuses the handshake on any later mismatch *before* the token is sent (`UltraBarError.certPinMismatch`). The client requires TLS 1.2 or newer, caps a reply line at 4 MB, times out the connect at 10 s and every request individually, and matches replies by request id. Discovery replies are validated *(2026-11-04)*: the `ip` field must be an IPv4 literal (otherwise the sender's address is used), `tcpPort` must be a port, the serial must be present and at most 64 characters, and control characters are stripped from the strings that reach the UI and file names. The serial is also stripped of anything but plain characters before it is used in an upload's multipart header *(2026-11-04)*.

**Residual risks.**
- The pin is only as strong as the key behind it, and that key is shared across all units. Someone who extracts it from a vendor APK can MITM the *first* pairing (there is nothing to pin yet) and, after that, can impersonate the bar to a Deckhand that has pinned the same shared certificate — because every bar presents the same one. Network isolation (below) is the real control; nothing in the client can close this.
- A spoofed discovery reply that names the paired bar's serial with another address used to move everything to that address: the pinned control connection (fails safe: the token is never sent to a different certificate), the plain-HTTP uploads on `:8080` (cube packages and page images — pictures, not secrets), `adb connect` (the Mac's `adb` client would talk to whatever listens on `:5555` there), the beacon and the set of addresses the data API answers. Since 2026-11-05 a paired bar's address is **adopted only after a pinned `AUTH` on it succeeds** (`AppModel.address(for:)` / `confirmAddress`): the stored `lastIp` stays in use, the new address is tried once per scan with the pin and the stored token, and only a bar that presents the pinned certificate *and* accepts the token moves the address (one Activity line: "CoreBar moved to …"). A bar that is not paired yet (nothing to pin) still uses the discovered address, as does a paired bar without a pin or token. Residual: three views (`AppsView` Web UI button, `InstalledView`, the sidebar's launcher-version line) still read the discovered address directly for display and for the vendor web UI link; `SidebarView` and `SettingsView` show the adopted one.
- Pairing itself is physical (an Approve on the bar); tokens never expire and the bar does not rate-limit `AUTH` (finding 3). Revoke old controllers on the bar now and then.

### 2. The LAN: the bar apps' data API (`:7432`) and the beacon (`UDP 5320`)

Since bar apps 2.0 every app carries its own page; the Mac serves no pages. While Deckhand runs, `MonitorServer` listens on TCP 7432 on every interface and answers the data requests of the five Mac-data apps (`/monitor/stats.json`, `/<page>/data.json` for Claude, Music, Calendar and Tasks, `/music/art.jpg`), `/config.json` for the on-bar apps, and two actions; it sends a UDP beacon with its address every 5 s (broadcast plus a unicast to the bar).

**What an attacker could read.** There is no login, so the server answers by peer address. The data is: Mac stats and host name; the Claude data (project folder names, the first prompt of each session cut to 70 characters, the last reply cut to 140, how long ago); calendar titles and times for three days; the user's open Linear issues (identifiers, titles, states, due dates, and the issue UUIDs); what Music plays, with the album art; and in `/config.json` the weather location rounded to three decimals (about 100 m), units, the flight radius, the coins and the news source.

**Protections.**
- Only the selected bar's address and this Mac get an answer; every other host gets 403 (`MonitorServer.setAllowedPeers`, set by `AppModel.startBarDataServer` before the server starts and on every beacon round). Until 2026-11-06 reads were open to the LAN unless *Serve the pages only to the bar* was on, so a page could be previewed in a browser; with no pages to preview that option is gone and the restriction always applies. Checked by kitcheck from loopback and from the Mac's own LAN address.
- Actions are `POST` with the header `X-Deckhand: action`, which the bar apps send and a cross-site page cannot (no CORS preflight passes). The header is parsed as a header rather than searched for anywhere in the request head *(2026-11-04)*. The Linear issue id must be a UUID; the Music commands are a fixed set.
- DNS rebinding is refused *(2026-11-04)*: a request whose `Host` is a DNS name (anything but an IP literal or `localhost`) gets `421`, on this server and on the Preview server. The responses carry no CORS headers, so a page on another origin cannot read them either way.
- Every response carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and `X-Frame-Options: DENY`, and is JSON or a JPEG, never HTML. The pages on the bar draw everything on a canvas (`fillText`), so a calendar title or a Claude transcript line cannot inject markup.
- Requests are bounded: 64 KB of head, 15 s to finish a request, the query string dropped, control characters stripped from the logged path, one request per connection. Nothing on disk is served; the Preview server serves only images published in memory on an ephemeral port.
- The bar apps (`android/DeckhandMonitor`) load their page from a private `https://deckhand.invalid` origin answered inside the app, forward only the five apps' data requests to the Mac, and accept a beacon only when it names its own sender on a private LAN address, so another host on the Wi-Fi cannot point them elsewhere. The JavaScript bridge exposes `close()` and `version()` only.

**Residual risks.**
- The allowed peer is the bar's *address*; since 2026-11-05 that address moves only after a pinned, authenticated connection confirms it (path 1), so a spoofed discovery reply does not change it. A host that takes over the bar's address on the LAN can read the data.
- Plain HTTP: anyone on the path can read the data in transit. Put the bar and the Mac on a network of their own if that matters.

### 3. A malicious or compromised bar

**What it can do.** Everything it says over `:7431` is parsed by Deckhand; it pushes `PUSH_MESSAGE` requests over the persistent link; it serves icon URLs and web-UI session tokens in its app list; it reads whatever the data API serves (path 2) and can tap the actions.

**Protections.**
- `PC_CONTROL` pushes: `execCmd`, `startApp`, `openFile` and `inputText` are refused outright and logged by name only (the refused parameters are not written to the log any more, since they could be anything the bar wanted typed) *(2026-11-04)*; `openBrowser` is honoured for `http(s)` URLs only; Deckhand's own commands are a fixed list (next/previous card, Music transport, mute, two page switches). `SET_VOLUME` is clamped to 0–100.
- App-list icon URLs are kept only when they are `http(s)` *(2026-11-04)*, so the app's image views never load a `file://` or other scheme the bar chose.
- Replies are parsed defensively (any shape, size-capped); the kit never evaluates anything the bar sends. Page ids, app names and versions are shown as text.
- `savePages` refuses an empty list and pages without ids; every `/upload/zip` passes a `subDir` (the device's default wipes the whole external-files directory, finding 4).

**Residual risks.**
- `openBrowser` no longer opens anything by itself *(2026-11-05)*: Deckhand shows an alert with the host and the full URL (Open / Ignore), for `http(s)` URLs with a host only; one request at a time (a second one while the alert is up is dropped and logged); nothing is remembered, so the next request asks again (`AppModel+Link.confirmOpenBrowser`). Residual: a user who clicks Open on an unexpected URL — the dialog says to open only what they expect.
- The *Web UI* button opens `http://<bar>:<port>/?sessionToken=…` in the browser: the bar's own app token ends up in browser history. Minor; it is the bar's token for its own UI.
- The bar can read all the data the Mac serves (path 2). Do not install the Claude, Calendar or Tasks apps on a bar you do not trust.
- The wire log (`wire.log`, user-only) stores decrypted replies with tokens, Wi-Fi passwords, API keys and session tokens redacted (`WireLog.redact`, checked by kitcheck); anything else the bar says is in there, capped at 5 MB.

### 4. The Mac's browser: cross-site requests to `localhost` and the LAN

A page the user visits can send requests to `http://127.0.0.1:7432` and to LAN addresses. Reads come back opaque (no CORS headers). Actions need a custom header, which triggers a CORS preflight that the server never answers with `Access-Control-Allow-*`, so the browser does not send them; a form or image cannot add the header. DNS rebinding — the one way a page could become same-origin with the server — is refused by the `Host` check *(2026-11-04)*. The `Content-Type` a cross-site `fetch` may set cannot contain a colon, so the marker cannot be smuggled there either (and the marker is now a parsed header). Nothing listens on the Mac apart from the bar apps' data API (which answers only the bar and loopback) and the ephemeral Preview server (while an image is being previewed); the control channel and uploads are outbound.

### 5. The future marketplace (`site/marketplace/registry.json`)

Today the registry is a static index on the project's GitHub Pages site; Deckhand does not fetch it yet, and the eleven bar apps are shipped inside `Deckhand.app` and installed over ADB. The vendor catalogue Deckhand *does* read (`BarAppStore`, `https://gatewayssl.dev.aiks360.com`) is strings only: the bar downloads and installs those packages itself; Deckhand never touches the file.

When Deckhand starts fetching the registry, the entries are untrusted input. Recommended, in order: fetch over HTTPS from the project domain only, with a pinned path; treat `icon` and `screenshot` as `https` URLs or relative paths under the site, nothing else; install only `kind: bar-app` entries whose `package` carries an allow-listed prefix (`nl.denoronha.deckhand.`) or whose publisher is on an allow list shown to the user; require a SHA-256 (and preferably a signature over the registry or per APK) and verify it before `adb install`; cap download sizes; never execute or `open` anything from an entry; show publisher, licence and source before installing. `requires.wifiAdb: true` already says what an install needs; an entry must not be able to turn Wi-Fi ADB on by itself.

### 6. Supply chain

- **Swift**: `Package.swift` has no dependencies. `UltraBarKit`, the app and `kitcheck` are built from this repository with the system toolchain.
- **Android**: Gradle 9.8.2 through the wrapper (`validateDistributionUrl=true`, and `distributionSha256Sum` pinned to the published checksum of `gradle-9.8.2-bin.zip` *(2026-11-05)*; the wrapper refuses a distribution that does not match) and AGP 9.4.1 from `google()`/`mavenCentral()`. No library dependencies (plain Kotlin, no AndroidX). Debug-signed APKs; the bar accepts them because it is an engineering build.
- **GitHub Actions** (`.github/workflows/pages.yml`): `actions/checkout`, `configure-pages`, `upload-pages-artifact` and `deploy-pages` are pinned to full commit SHAs with the major tag in a comment *(2026-11-05)*, so a moved tag cannot change what runs. Permissions are minimal (`contents: read`, `pages: write`, `id-token: write`). The job downloads the newest non-draft release's `Deckhand.dmg` with the workflow token and publishes it on the site with `latest.json` (tag, size, date, and since 2026-11-05 the DMG's `sha256`); the download buttons show the first twelve characters of the hash (the full one in the tooltip), so a downloaded file can be compared with `shasum -a 256 Deckhand.dmg`. Anyone who can create a release on `origin` still controls what the site serves — the hash is computed from what was released, it does not say who released it; the DMG is Developer-ID signed and notarized, so Gatekeeper checks *a* valid signature but not *whose*. Recommended: sign tags.
- **Release**: `make-app.sh` signs with the first Developer ID identity in the keychain (hardened runtime, timestamp, the two entitlements for Calendar and Location); `make-dmg.sh` notarizes with the `deckhand-notary` keychain profile and staples; a failed verify aborts. Releases go to `origin` only; the vendor's `upstream` push URL is `DISABLED`.
- **Fluent Emoji**: ten PNGs downloaded unmodified from the `main` branch of `microsoft/fluentui-emoji` (MIT, sources in `android/DeckhandMonitor/tools/fluent/SOURCES.md`), composited by a local script into launcher icons. They are image data, not code; the risk is a wrong or non-free image, not execution. Recommended: record the commit they were taken from.
- **Services**: everything below is fetched over HTTPS with Foundation's default trust; no certificate pinning, no API keys except the ones the user pastes.

### 7. Another user or process on the Mac

Deckhand is not sandboxed (a Developer-ID app with the hardened runtime). What it stores, all under `~/Library/Application Support/UltraWorkspaceMac/` unless noted:

- `tokens/<serial>.token` — the pairing token, `0600`, directory `0700`. Not the Keychain, on purpose: an ad-hoc-signed development build would re-prompt for the login password on every rebuild. A notarized release could move it back.
- `tokens/secret-<name>.token` — the Linear personal API key, `0600`. Linear personal keys are full-access keys: the one you paste can do anything your account can, not just read issues and mark them done.
- `corebars.json` — paired bars with cert pins, last addresses, the bar's hotspot credentials and every Wi-Fi password sent to a cube: `0600`.
- `settings.json` — preferences including the AccuWeather key and the manual location: `0600` *(2026-11-04; it was world-readable)*.
- `contacts.json` — the People list: `0600` *(2026-11-04)*.
- `wire.log` — the decrypted control channel, redacted, 5 MB cap: `0600`. Versions before 2026-11-03 logged the token in clear; the app scrubs an old log once.
- `endpoints/` — module serials and gateway config; default permissions (no secrets).
- `~/Library/Caches/Deckhand/tiles-v2/` — map tiles around the weather location: default permissions. The set of tiles reveals the location to about street level.
- `~/.claude/projects/**/*.jsonl` is read (never written): the first 8 KB and last 64 KB of each transcript, and the `usage` lines for today's token count. Only the per-session summary described in path 2 ever leaves the process.

Files are written atomically and then `chmod`ed; between the two there is a window of milliseconds with default permissions. The Store directory itself is created with default permissions; the secrets inside are `0600`.

### 8. ADB (the Android debug bridge)

The bar apps' installs, *Restart bar launcher* and *Keep the screen on while someone is at the desk* use the local `adb` binary (found at fixed paths, never `PATH`) against `<bar-ip>:5555`. Wi-Fi ADB is off by default on the bar and is off again after every reboot unless *Keep on after reboots* was used (it sets `persist.adb.tcp.port=5555` and switches USB debugging on); while it is on, **anyone on the LAN has a root shell on the bar**. Deckhand runs a fixed set of commands with literal arguments (`logcat -s <tag>`, `dumpsys power`, `input keyevent KEYCODE_WAKEUP`, `settings put system screen_off_timeout <int>`, `am force-stop`/`am start` of the launcher, `install -r <bundled apk>`, `uninstall <own package>`, `getprop`/`setprop persist.adb.tcp.port`, `settings put global adb_enabled 1`, `pm disable-user --user 0`/`pm enable` of a firmware app (never the launcher, hub, keyboard or Android's own packages), `pm list packages -d`, the firewall rules below, `cat /proc/sys/kernel/random/boot_id`), each with a timeout. Turn Wi-Fi ADB off when you do not use it, or turn on *Bar hardening*.

**The bar's listening services** (read on the bar, 2026-11-06): `adbd` on `:5555` as root with no key check (`ro.adb.secure` is empty on this eng build, and it is a read-only property), the vendor launcher's upload server on `:8080` (no authentication), the hub's control channel on `:7431` (TLS + token), an audio HAL service on `:14035` and the UltraRadio app on two high ports, all on every interface.

**Bar hardening** (Settings → Bar hardening, off by default) puts a firewall in front of all of them. Deckhand adds an iptables chain `deckhand_in` at the top of `INPUT`: on the bar's home-network interface (`wlan0`) new TCP connections are dropped unless they come from this Mac's address (the one the bar reaches it on); loopback, the bar's own hotspot for the VivoCube (`wlan1`), replies to connections the bar opened itself and all UDP (the beacon) pass. Over IPv6 no new TCP connection is accepted on `wlan0`. Limits: Android does not keep iptables rules across a reboot and `netd` rebuilds the tables while the bar starts, so Deckhand sets the rules again when the link comes back (after `sys.boot_completed`) and checks them every two minutes; between a bar restart and that moment the services are open as before. Anything else on the LAN (the vendor's own PC or phone app, another Mac) can no longer reach the bar while the firewall is on. If this Mac changes address it is locked out too: restart the bar, the rules are gone, and Deckhand sets them again with the new address. A key check on adb itself (`ro.adb.secure=1` with this Mac's key in `adb_keys`) would need a change to the bar's boot image and is not done.

### 8a. Local helpers Deckhand runs

Besides `adb`, Deckhand runs one other local program: when cmux is installed, `/Applications/cmux.app/Contents/Resources/bin/cmux list-windows` and `cmux workspace list --window <id> --json` and `cmux sidebar-state --workspace <ref>` (every 5 s, for the running / waiting / idle status) (fixed path, never `PATH`, 3 s timeout, at most every 30 s while the Claude bar app asks for data), to list the Claude Code sessions open in cmux and show them under their workspace names. Only each workspace's custom title and directory are used; nothing is sent anywhere else.

### 9. What leaves the Mac, and to whom

Since bar apps 2.0 (Deckhand 0.3) six bar apps fetch public data from the bar itself, so these leave the **bar**, not the Mac: `api.adsb.lol` and `api.adsbdb.com` (Flights; coordinates rounded to three decimals), `tile.openstreetmap.org` (tiles cached on the bar for 30 days), `api.coingecko.com` (Crypto), `api.open-meteo.com` (Weather), the chosen news source (Headlines), `bible-api.com` (Verse), and `ipwho.is` only on a bar that has never received settings from Deckhand. User-Agent `Deckhand-bar/2.0 (+site)`. The settings document Deckhand pushes (location rounded to about 100 m, units, coins, news source, radius) contains nothing secret; the Linear key never leaves the Mac. The push uses `am broadcast` over ADB to a receiver guarded by `android.permission.DUMP`, so only the shell user can change the apps' settings.

On the Mac:

Outbound connections the app makes (no telemetry, no account, nothing else):

- **The bar on your LAN** — UDP 5319 (discovery, broadcast or unicast), TCP 7431 (TLS control; one connection per request plus one persistent link that answers the bar's pushes), TCP 8080 (plain-HTTP upload of cube packages and page images), TCP 5555 (ADB, only for the features above), UDP 5320 (the beacon, while Deckhand runs).
- `api.open-meteo.com`, `geocoding-api.open-meteo.com` — weather and city lookup; receives the coordinates or the city you typed.
- `ipwho.is` — IP geolocation, only when macOS Location is unavailable and no manual city is set; receives your public address (that is the point).
- `api.coingecko.com` — prices and today's chart for the coins you pick (coin ids only).
- `api.linear.app` — with your personal API key: one read query, and one mutation when you press Done on the bar.
- `gatewayssl.dev.aiks360.com` — the vendor's public app catalogue (apps and screensavers), a POST with page numbers only; icon URLs from it are rewritten to `https`.
- Apple: Calendar (EventKit), Location (CoreLocation), Music (Apple Events) and notifications, all local, each behind its own TCC prompt (`packaging/Info.plist`).

Nothing identifies the Mac or the user to these services beyond the request itself; there is no device id, no account, no analytics.

## Mitigations you control (no device changes)

- Turn on **Settings → Bar hardening** so only this Mac can open connections to the bar (section 8).
- Put the CoreBar on an **IoT VLAN / guest SSID** with no route to your PCs/NAS, and put the Mac that runs Deckhand on it only while you use the bar. Never port-forward the bar's ports.
- On a shared network, do not install the Claude, Calendar and Tasks bar apps.
- Turn Wi-Fi ADB off after installs.
- Optionally block the bar's outbound to `*.aiks360.com` (its cleartext backup, finding 5) and the telemetry hosts.
- Review and revoke paired controllers on the bar periodically.

## The device: UltraBar X (vendor software) — defensive review

A read-only review of the CoreBar's decompiled software (the vendor's Android apps `com.ultrabar.launch` launcher and `com.ultrabar.hub` relay). These are findings about the **device**, which Deckhand only talks to. No exploits were produced. Severities are the reviewer's.

### Architecture

- `:7431` (TLS, line-JSON) is served by the **hub** app (Netty; TLS 1.3 only — a 1.2 ClientHello gets a `protocol_version` alert; Deckhand's floor is 1.2). This is the control channel; it can also inject HID keystrokes into a connected PC.
- `:8080` (HTTP) is served by the **launcher** (AndServer) for module/image upload and static serving.
- A separate plugin server is loopback-only (127.0.0.1:39001). No PHP anywhere — it's Android/Java, as expected.

### Findings

1. **Hardcoded, shared TLS private key in the APK** (HIGH). The `:7431` server loads `assets/ssl/server.crt` + `server.key`; the same private key ships on every device. Combined with the client's trust-on-first-use pinning, a LAN attacker who extracts the key could MITM `:7431`, steal the bearer token, and read/alter traffic. The device negotiates TLS 1.3 (the client allows ≥ 1.2), but there is no mutual TLS. **The vendor's own macOS client makes this worse**: it embeds a root CA (`cb_root_ca.crt`, CN `ultrabar.local`, RSA-4096, valid to 2126) but then disables peer verification and calls `ignoreSslErrors()` unconditionally, so it accepts any certificate (CONFIRMED from the binary); its pairing request also uses one fixed UUID (`550e8400-e29b-41d4-a716-446655440000`) for every installation, so the device cannot tell vendor-client installs apart.
2. **Unauthenticated `:8080` upload** (HIGH). Anything on the LAN can `POST` — `/upload?serialNo=` accepts up to 100 MB `.tgz`, stores it in the cache dir (served back at `/tgz/`) and makes an attached VivoCube download and apply it (unauthenticated module content delivery, and each accepted upload rewrites the module's flash); `/upload/zip` writes files into app storage. No auth filter exists.
3. **Token / capability model** (MEDIUM-HIGH). Pairing needs a physical on-device Approve (good — an unpaired peer can't self-authorize), but tokens are non-expiring UUID bearer secrets, `act=100` auth has no rate-limit/lockout, and a valid token can inject HID keystrokes into the connected PC. In the other direction, a device (or anyone who can MITM `:7431`, see 1) can send the PC client `PUSH_MESSAGE` requests of type `PC_CONTROL` with `execCmd{cmd}`, `startApp{path}`, `openBrowser{url}`, `inputText{text}`; the vendor client executes these. Deckhand refuses `execCmd`, `startApp`, `openFile` and `inputText` outright (since 2026-11-03) and only honours `openBrowser` for http(s) URLs; its own pages never emit the others.
4. **`subDir` path handling and the default wipe** (MEDIUM). Zip-entry traversal is blocked, but the `/upload/zip?subDir=` parameter isn't canonicalized; with `isFull=true` it recursively deletes the resolved directory → arbitrary-directory deletion (within app-accessible storage) plus constrained image-file writes. The server defaults are `subDir=""` and `isFull=true`, and the vendor client sends neither parameter, so every vendor "Deploy project" deletes the **entire** external-files directory (CONFIRMED) — including any other client's assets. Weak zip-bomb limits (50 MB compressed cap only).
5. **Cleartext cloud backup** (MEDIUM). `BackupConfigUtils` POSTs `{serialNo, application, content}` over plain `http://` to `gateway.dev.aiks360.com` with no auth header, keyed only by serialNo. The vendor desktop client additionally talks to `https://gatewayssl.dev.aiks360.com/api/v1/base-service/pub/…` for the icon library (`icon/tags/locales/allGrouped`, `icon/v2/page`), the CoreBar app store (`apps/100/fetchListV2`, `apps/100/<id>/fetchLastVerV3` — APK `fileUrl` + `sha256`, which the device then downloads via act 30600) and the PC plugin store (`plugin/page`); it stores the pairing token encrypted with a custom cipher inside its project file (`*.umpf`, SQLite), not in the Keychain.
6. **Engineering build shipped to customers** (HIGH, confirmed on the unit 2026-11-06 over ADB): `ro.build.type=eng`, `ro.build.tags=test-keys`, `ro.secure=0`, `ro.debuggable=1`, SELinux `Permissive`, and `adbd` runs as uid 0 — so Wi-Fi ADB (port 5555) is a root shell with no prompt. The same build runs `dnsmasq` on the hotspot interface (192.168.43.x) for the modules. TheDeveloperIncognito additionally reports hard-coded Bluetooth-Mesh keys (NET_KEY/APP_KEY/GTW_DEVICE_KEY) in the launcher, a hidden factory QA app (`ultrabar.tester`), a second, RSA+AES-encrypted WebSocket control channel inside the hub that neither client uses, and that two of his units present the same certificate fingerprint as this one — empirical proof that the TLS key is shared.
7. **adb-over-TCP helper** (LOW). `RootAdbUtils` can `su` to enable adbd at boot, but no caller was found (appears dead).
8. **Good**: fastjson 1.2.83 is present but **autotype is OFF** (parsed to fixed classes) → the fastjson deserialization RCE is **not exploitable as configured**. OAuth secrets live in a native lib, not plaintext. No backdoor accounts/API keys found in Java. Telemetry SDKs bundled: Tencent Bugly (crash) and iFlytek AIUI (voice).

### Implications for Deckhand

Deckhand pins the device cert on first pairing and never sends the token on a cert mismatch, which is the right client-side posture (and stricter than the vendor client, which verifies nothing). But because the device's TLS key is shared, that pin is weaker than it looks — the real protection is network isolation above. Deckhand does not weaken the device; it uses the same documented channels. Two operational consequences of the vendor-client analysis: Deckhand always passes a `subDir` on `/upload/zip` (never the wiping default), and running the vendor app's Deploy on the same CoreBar erases Deckhand's uploaded assets and profiles — the two clients cannot co-own a device.

## Mock CoreBar

The mock in `mock-corebar/` is a test double and is **more permissive than the device**: it accepts any `AUTH` token, auto-approves pairing, answers both discovery probes, and does not enforce the device's per-route upload limits (100 MB `.tgz`, 50 MB `.zip`) — it only has a generic 64 MB multer cap and otherwise rejects nothing. It also writes every uploaded body unmodified to `mock-corebar/captures/` (git-ignored), so anything the vendor app deploys against it ends up on disk in clear. Do not expose it beyond localhost.

## Capturing the device's traffic yourself

`scripts/capture-ultrabar.sh` (run with `sudo`) writes rotating pcap files to `~/Documents/DNC-captures/`. Default mode captures packets between this Mac and the CoreBar (`--host <ip>`); `--shared` captures on `bridge100` when the CoreBar is joined to the Mac's Internet Sharing hotspot, which is the only way to see the device's cloud/DNS traffic from a Mac (Wi-Fi is switched, so a Mac otherwise only sees its own packets). TLS payloads stay opaque; hosts, SNI, DNS, timing and sizes are visible. Open the files with Wireshark (`brew install --cask wireshark`). Deckhand's own control-channel traffic is already logged decrypted in `wire.log`.

## Checks

`swift build && .build/debug/kitcheck` covers the request parsing of the LAN servers (Host literal check, header parsing, action marker, peer rule), the live data server (routing, 403/405/421, nosniff headers, action from loopback, forged marker, request timeout, allowed peers: 200 from loopback and from the bar's address, 403 from any other address), discovery-reply validation, wire-log redaction and the Wi-Fi config codec. `kitcheck e2e <ip>` runs the protocol against the mock.
