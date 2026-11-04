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
- A spoofed discovery reply that names the paired bar's serial with another address makes Deckhand use that address for the pinned control connection (fails safe: the token is never sent to a different certificate), for the plain-HTTP uploads on `:8080` (the cube packages and page images go to the attacker — pictures, not secrets), for `adb connect` (the Mac's `adb` client would then talk to whatever listens on `:5555` there), for the Monitor beacon, and for the set of addresses allowed to trigger page actions. Not fixed. Recommended: only adopt an address for a paired serial after a successful pinned `AUTH` on it, and keep `Store.lastIp` as the fallback until then (`AppModel.ipForSelected`, `AppModel.swift:164`).
- Pairing itself is physical (an Approve on the bar); tokens never expire and the bar does not rate-limit `AUTH` (finding 3). Revoke old controllers on the bar now and then.

### 2. The LAN: the pages the Mac serves (`:7432`) and the beacon (`UDP 5320`)

With *Serve the pages from this Mac* on, `MonitorServer` listens on TCP 7432 on every interface and serves the eleven bar pages (`/<page>` and `/<page>/data.json`, plus `/music/art.jpg` and `/flights/tile/z/x/y.png`), and sends a UDP beacon with its URL every 5 s (broadcast plus a unicast to the bar). Off by default; the switch is on the Apps page.

**What an attacker can do.** Read the pages. There is no login: the data is readable by anyone on the LAN while the switch is on. That data is: Mac stats and host name; the Claude page (project folder names, the first prompt of each session cut to 70 characters, the last reply cut to 140, how long ago); calendar titles and times for three days; the user's open Linear issues (identifiers, titles, states, due dates, and the issue UUIDs); the weather, the sun and moon data and the Flights data — the last two carry the Mac's **latitude and longitude** (the weather location) in `data.json`; what Music plays, with the album art; headlines; a verse. Before 2026-11-04 anyone on the LAN could also trigger the two actions (play/next/previous in Music, close a Linear issue by UUID), send the bar's Monitor apps to a page of their own with a forged beacon, and use the Flights tile route to make the Mac fetch any OpenStreetMap tile.

**Protections.**
- Actions are `POST` with the header `X-Deckhand: action`, which the served pages send and a cross-site page cannot (no CORS preflight passes). The header is now parsed as a header rather than searched for anywhere in the request head *(2026-11-04)*, and actions are accepted only from the selected bar's address and from this Mac (`MonitorServer.setActionPeers`, set by `AppModel.startMonitor` every beacon round) *(2026-11-04)*. The Linear issue id must be a UUID; the Music commands are a fixed set.
- DNS rebinding is refused *(2026-11-04)*: a request whose `Host` is a DNS name (anything but an IP literal or `localhost`) gets `421`, on the Monitor and on the Preview server. The responses carry no CORS headers, so a page on another origin cannot read them either way.
- Every response carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and `X-Frame-Options: DENY`; HTML pages carry a Content-Security-Policy that allows only inline script and style, same-origin images and same-origin `fetch` *(2026-11-04)*. The pages draw everything on a canvas (`fillText`), so a calendar title, a headline or a Claude transcript line cannot inject markup.
- Requests are bounded: 64 KB of head, 15 s to finish a request, the query string dropped, control characters stripped from the logged path, one request per connection. Nothing on disk is served; the Preview server serves only images published in memory on an ephemeral port.
- The tile route accepts zoom 2–17 only and at most four OpenStreetMap fetches at a time *(2026-11-04)*; tiles are cached for 30 days in `~/Library/Caches/Deckhand/tiles-v2`.
- The bar apps (`android/DeckhandMonitor`) load only `http(s)` URLs whose host is a private IPv4 address, never navigate away from that host, and — in the source as of 2026-11-04 — accept a beacon only when the URL's host is the address the beacon came from, so another host on the Wi-Fi can no longer put its own page on the bar. **This change is in the Kotlin source and compiles; it is on a bar only once the APKs are rebuilt and installed (the bundled 1.6 APKs predate it).** The JavaScript bridge exposes `close()` and `version()` only.
- A `POST` reply now carries its body (it carried only a `Content-Length` before 2026-11-04, found by the new checks).

**Residual risks.**
- Reads are open to the LAN by design while the switch is on. If that is not acceptable on your network, leave the switch off, or put the bar and the Mac on a network of their own. Recommended change: a *pages only for the bar* option that applies the same peer check to `GET` (the mechanism exists in `MonitorServer.peerMayAct`; the app would set it from the selected bar's address and keep loopback for your own browser).
- The allowed action peer is the bar's *address*, which comes from discovery (path 1): a spoofed reply can move it.
- Plain HTTP: anyone on the path can read the pages in transit. The Monitor apps' WebView allows mixed content (`MIXED_CONTENT_ALWAYS_ALLOW`) although the pages are plain HTTP anyway; harmless today, worth removing when the pages ever move to HTTPS.
- The location in `flights/data.json` and `sky/data.json` is the weather location: the Mac's own position when *Same as this Mac* is selected.

### 3. A malicious or compromised bar

**What it can do.** Everything it says over `:7431` is parsed by Deckhand; it pushes `PUSH_MESSAGE` requests over the persistent link; it serves icon URLs and web-UI session tokens in its app list; it reads whatever the pages serve (path 2) and can tap the actions.

**Protections.**
- `PC_CONTROL` pushes: `execCmd`, `startApp`, `openFile` and `inputText` are refused outright and logged by name only (the refused parameters are not written to the log any more, since they could be anything the bar wanted typed) *(2026-11-04)*; `openBrowser` is honoured for `http(s)` URLs only; Deckhand's own commands are a fixed list (next/previous card, Music transport, mute, two page switches). `SET_VOLUME` is clamped to 0–100.
- App-list icon URLs are kept only when they are `http(s)` *(2026-11-04)*, so the app's image views never load a `file://` or other scheme the bar chose.
- Replies are parsed defensively (any shape, size-capped); the kit never evaluates anything the bar sends. Page ids, app names and versions are shown as text.
- `savePages` refuses an empty list and pages without ids; every `/upload/zip` passes a `subDir` (the device's default wipes the whole external-files directory, finding 4).

**Residual risks.**
- `openBrowser` opens any `http(s)` URL in the Mac's default browser on the bar's say-so — a phishing or drive-by vector if the bar (or whoever can speak to `:7431`, path 1) is hostile. Recommended: require a click in Deckhand ("The bar wants to open …") before opening, or restrict to the URLs Deckhand's own cards emit (currently none).
- The *Web UI* button opens `http://<bar>:<port>/?sessionToken=…` in the browser: the bar's own app token ends up in browser history. Minor; it is the bar's token for its own UI.
- The bar can read every page (path 2). Do not enable the Claude, Calendar or Tasks pages on a bar you do not trust.
- The wire log (`wire.log`, user-only) stores decrypted replies with tokens, Wi-Fi passwords, API keys and session tokens redacted (`WireLog.redact`, checked by kitcheck); anything else the bar says is in there, capped at 5 MB.

### 4. The Mac's browser: cross-site requests to `localhost` and the LAN

A page the user visits can send requests to `http://127.0.0.1:7432` and to LAN addresses. Reads come back opaque (no CORS headers). Actions need a custom header, which triggers a CORS preflight that the server never answers with `Access-Control-Allow-*`, so the browser does not send them; a form or image cannot add the header. DNS rebinding — the one way a page could become same-origin with the server — is refused by the `Host` check *(2026-11-04)*. The `Content-Type` a cross-site `fetch` may set cannot contain a colon, so the marker cannot be smuggled there either (and the marker is now a parsed header). Nothing listens on the Mac apart from the Monitor (when on) and the ephemeral Preview server (while an image is being previewed); the control channel and uploads are outbound.

### 5. The future marketplace (`site/marketplace/registry.json`)

Today the registry is a static index on the project's GitHub Pages site; Deckhand does not fetch it yet, and the eleven bar apps are shipped inside `Deckhand.app` and installed over ADB. The vendor catalogue Deckhand *does* read (`BarAppStore`, `https://gatewayssl.dev.aiks360.com`) is strings only: the bar downloads and installs those packages itself; Deckhand never touches the file.

When Deckhand starts fetching the registry, the entries are untrusted input. Recommended, in order: fetch over HTTPS from the project domain only, with a pinned path; treat `icon` and `screenshot` as `https` URLs or relative paths under the site, nothing else; install only `kind: bar-app` entries whose `package` carries an allow-listed prefix (`nl.denoronha.deckhand.`) or whose publisher is on an allow list shown to the user; require a SHA-256 (and preferably a signature over the registry or per APK) and verify it before `adb install`; cap download sizes; never execute or `open` anything from an entry; show publisher, licence and source before installing. `requires.wifiAdb: true` already says what an install needs; an entry must not be able to turn Wi-Fi ADB on by itself.

### 6. Supply chain

- **Swift**: `Package.swift` has no dependencies. `UltraBarKit`, the app and `kitcheck` are built from this repository with the system toolchain.
- **Android**: Gradle 9.8.2 through the wrapper (`validateDistributionUrl=true`, no `distributionSha256Sum` — recommended to add) and AGP 9.4.1 from `google()`/`mavenCentral()`. No library dependencies (plain Kotlin, no AndroidX). Debug-signed APKs; the bar accepts them because it is an engineering build.
- **GitHub Actions** (`.github/workflows/pages.yml`): `actions/checkout@v4`, `configure-pages@v5`, `upload-pages-artifact@v3`, `deploy-pages@v4`, pinned to major tags, not commit SHAs (recommended: pin SHAs). Permissions are minimal (`contents: read`, `pages: write`, `id-token: write`). The job downloads the newest non-draft release's `Deckhand.dmg` with the workflow token and publishes it on the site with `latest.json` (tag, size, date). Anyone who can create a release on `origin` therefore controls what the site serves; the DMG is Developer-ID signed and notarized, so Gatekeeper checks *a* valid signature but not *whose*. Recommended: publish the DMG's SHA-256 in `latest.json` and on the download page, and sign tags.
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

The bar apps' installs, *Restart bar launcher* and *Keep the screen on while someone is at the desk* use the local `adb` binary (found at fixed paths, never `PATH`) against `<bar-ip>:5555`. Wi-Fi ADB is off by default on the bar and is off again after every reboot unless *Keep on after reboots* was used; while it is on, **anyone on the LAN has a root shell on the bar**. Deckhand runs a fixed set of commands with literal arguments (`logcat -s <tag>`, `dumpsys power`, `input keyevent KEYCODE_WAKEUP`, `settings put system screen_off_timeout <int>`, `am force-stop`/`am start` of the launcher, `install -r <bundled apk>`, `uninstall <own package>`, `getprop`/`setprop persist.adb.tcp.port`), each with a timeout. Turn Wi-Fi ADB off when you do not use it.

### 9. What leaves the Mac, and to whom

Outbound connections the app makes (no telemetry, no account, nothing else):

- **The bar on your LAN** — UDP 5319 (discovery, broadcast or unicast), TCP 7431 (TLS control; one connection per request plus one persistent link that answers the bar's pushes), TCP 8080 (plain-HTTP upload of cube packages and page images), TCP 5555 (ADB, only for the features above), UDP 5320 (the beacon, only while the pages are served).
- `api.open-meteo.com`, `geocoding-api.open-meteo.com` — weather and city lookup; receives the coordinates or the city you typed.
- `ipwho.is` — IP geolocation, only when macOS Location is unavailable and no manual city is set; receives your public address (that is the point).
- `api.coingecko.com` — prices and today's chart for the coins you pick (coin ids only).
- `api.adsb.lol` — aircraft near the weather location; receives the coordinates rounded to three decimals (about 100 m) *(2026-11-04)* and the radius. `api.adsbdb.com` — airline and route per callsign seen (callsigns only, letters and digits, cached).
- `tile.openstreetmap.org` — map tiles for the Flights radar, with the User-Agent `Deckhand/0.2 (+site)` OSM's policy asks for; tile coordinates imply the location at tile granularity.
- `bible-api.com` — the day's reference.
- The headline source you chose (`lite.cnn.com`, BBC, NYT, The Guardian, NOS, NU.nl) with a `Deckhand/1.3` User-Agent.
- `api.linear.app` — with your personal API key: one read query, and one mutation when you press Done on the bar.
- `gatewayssl.dev.aiks360.com` — the vendor's public app catalogue (apps and screensavers), a POST with page numbers only; icon URLs from it are rewritten to `https`.
- Apple: Calendar (EventKit), Location (CoreLocation), Music (Apple Events) and notifications, all local, each behind its own TCC prompt (`packaging/Info.plist`).

Nothing identifies the Mac or the user to these services beyond the request itself; there is no device id, no account, no analytics.

## Mitigations you control (no device changes)

- Put the CoreBar on an **IoT VLAN / guest SSID** with no route to your PCs/NAS, and put the Mac that runs Deckhand on it only while you use the bar — or firewall `:7431`, `:8080` and `:5555` on the bar so only the Mac reaches them. Never port-forward these.
- Leave *Serve the pages from this Mac* off unless you use the bar apps, and switch off the Claude, Calendar and Tasks pages on a shared network.
- Turn Wi-Fi ADB off after installs.
- Optionally block the bar's outbound to `*.aiks360.com` (its cleartext backup, finding 5) and the telemetry hosts.
- Review and revoke paired controllers on the bar periodically.

## The device: UltraBar X (vendor software) — defensive review

A read-only review of the CoreBar's decompiled software (the vendor's Android apps `com.ultrabar.launch` launcher and `com.ultrabar.hub` relay). These are findings about the **device**, which Deckhand only talks to. No exploits were produced. Severities are the reviewer's.

### Architecture

- `:7431` (TLS, line-JSON) is served by the **hub** app (Netty; the device negotiates TLS 1.3, Deckhand's client allows ≥ 1.2). This is the control channel; it can also inject HID keystrokes into a connected PC.
- `:8080` (HTTP) is served by the **launcher** (AndServer) for module/image upload and static serving.
- A separate plugin server is loopback-only (127.0.0.1:39001). No PHP anywhere — it's Android/Java, as expected.

### Findings

1. **Hardcoded, shared TLS private key in the APK** (HIGH). The `:7431` server loads `assets/ssl/server.crt` + `server.key`; the same private key ships on every device. Combined with the client's trust-on-first-use pinning, a LAN attacker who extracts the key could MITM `:7431`, steal the bearer token, and read/alter traffic. The device negotiates TLS 1.3 (the client allows ≥ 1.2), but there is no mutual TLS. **The vendor's own macOS client makes this worse**: it embeds a root CA (`cb_root_ca.crt`, CN `ultrabar.local`, RSA-4096, valid to 2126) but then disables peer verification and calls `ignoreSslErrors()` unconditionally, so it accepts any certificate (CONFIRMED from the binary); its pairing request also uses one fixed UUID (`550e8400-e29b-41d4-a716-446655440000`) for every installation, so the device cannot tell vendor-client installs apart.
2. **Unauthenticated `:8080` upload** (HIGH). Anything on the LAN can `POST` — `/upload?serialNo=` accepts up to 100 MB `.tgz`, stores it in the cache dir (served back at `/tgz/`) and makes an attached VivoCube download and apply it (unauthenticated module content delivery, and each accepted upload rewrites the module's flash); `/upload/zip` writes files into app storage. No auth filter exists.
3. **Token / capability model** (MEDIUM-HIGH). Pairing needs a physical on-device Approve (good — an unpaired peer can't self-authorize), but tokens are non-expiring UUID bearer secrets, `act=100` auth has no rate-limit/lockout, and a valid token can inject HID keystrokes into the connected PC. In the other direction, a device (or anyone who can MITM `:7431`, see 1) can send the PC client `PUSH_MESSAGE` requests of type `PC_CONTROL` with `execCmd{cmd}`, `startApp{path}`, `openBrowser{url}`, `inputText{text}`; the vendor client executes these. Deckhand refuses `execCmd`, `startApp`, `openFile` and `inputText` outright (since 2026-11-03) and only honours `openBrowser` for http(s) URLs; its own pages never emit the others.
4. **`subDir` path handling and the default wipe** (MEDIUM). Zip-entry traversal is blocked, but the `/upload/zip?subDir=` parameter isn't canonicalized; with `isFull=true` it recursively deletes the resolved directory → arbitrary-directory deletion (within app-accessible storage) plus constrained image-file writes. The server defaults are `subDir=""` and `isFull=true`, and the vendor client sends neither parameter, so every vendor "Deploy project" deletes the **entire** external-files directory (CONFIRMED) — including any other client's assets. Weak zip-bomb limits (50 MB compressed cap only).
5. **Cleartext cloud backup** (MEDIUM). `BackupConfigUtils` POSTs `{serialNo, application, content}` over plain `http://` to `gateway.dev.aiks360.com` with no auth header, keyed only by serialNo. The vendor desktop client additionally talks to `https://gatewayssl.dev.aiks360.com/api/v1/base-service/pub/…` for the icon library (`icon/tags/locales/allGrouped`, `icon/v2/page`), the CoreBar app store (`apps/100/fetchListV2`, `apps/100/<id>/fetchLastVerV3` — APK `fileUrl` + `sha256`, which the device then downloads via act 30600) and the PC plugin store (`plugin/page`); it stores the pairing token encrypted with a custom cipher inside its project file (`*.umpf`, SQLite), not in the Keychain.
6. **adb-over-TCP helper** (LOW). `RootAdbUtils` can `su` to enable adbd at boot, but no caller was found (appears dead).
7. **Good**: fastjson 1.2.83 is present but **autotype is OFF** (parsed to fixed classes) → the fastjson deserialization RCE is **not exploitable as configured**. OAuth secrets live in a native lib, not plaintext. No backdoor accounts/API keys found in Java. Telemetry SDKs bundled: Tencent Bugly (crash) and iFlytek AIUI (voice).

### Implications for Deckhand

Deckhand pins the device cert on first pairing and never sends the token on a cert mismatch, which is the right client-side posture (and stricter than the vendor client, which verifies nothing). But because the device's TLS key is shared, that pin is weaker than it looks — the real protection is network isolation above. Deckhand does not weaken the device; it uses the same documented channels. Two operational consequences of the vendor-client analysis: Deckhand always passes a `subDir` on `/upload/zip` (never the wiping default), and running the vendor app's Deploy on the same CoreBar erases Deckhand's uploaded assets and profiles — the two clients cannot co-own a device.

## Mock CoreBar

The mock in `mock-corebar/` is a test double and is **more permissive than the device**: it accepts any `AUTH` token, auto-approves pairing, answers both discovery probes, and does not enforce the device's per-route upload limits (100 MB `.tgz`, 50 MB `.zip`) — it only has a generic 64 MB multer cap and otherwise rejects nothing. It also writes every uploaded body unmodified to `mock-corebar/captures/` (git-ignored), so anything the vendor app deploys against it ends up on disk in clear. Do not expose it beyond localhost.

## Capturing the device's traffic yourself

`scripts/capture-ultrabar.sh` (run with `sudo`) writes rotating pcap files to `~/Documents/DNC-captures/`. Default mode captures packets between this Mac and the CoreBar (`--host <ip>`); `--shared` captures on `bridge100` when the CoreBar is joined to the Mac's Internet Sharing hotspot, which is the only way to see the device's cloud/DNS traffic from a Mac (Wi-Fi is switched, so a Mac otherwise only sees its own packets). TLS payloads stay opaque; hosts, SNI, DNS, timing and sizes are visible. Open the files with Wireshark (`brew install --cask wireshark`). Deckhand's own control-channel traffic is already logged decrypted in `wire.log`.

## Checks

`swift build && .build/debug/kitcheck` covers the request parsing of the LAN servers (Host literal check, header parsing, action marker, peer rule), the live Monitor server (routing, 403/405/421, CSP and nosniff headers, action from loopback, forged marker, request timeout), discovery-reply validation, wire-log redaction and the Wi-Fi config codec. `kitcheck e2e <ip>` runs the protocol against the mock.
