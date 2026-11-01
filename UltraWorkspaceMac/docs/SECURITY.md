# UltraBar X — security notes (device, not Deckhand)

A defensive, read-only review of the CoreBar's decompiled software (the vendor's Android apps `com.ultrabar.launch` launcher and `com.ultrabar.hub` relay). These are findings about the **device**, which sits on your LAN; Deckhand is just a client that talks to it. No exploits were produced. Severities are the reviewer's.

## Architecture

- `:7431` (TLS, line-JSON) is served by the **hub** app (Netty; the device negotiates TLS 1.3, Deckhand's client allows ≥ 1.2). This is the control channel; it can also inject HID keystrokes into a connected PC.
- `:8080` (HTTP) is served by the **launcher** (AndServer) for module/image upload and static serving.
- A separate plugin server is loopback-only (127.0.0.1:39001). No PHP anywhere — it's Android/Java, as expected.

## Findings

1. **Hardcoded, shared TLS private key in the APK** (HIGH). The `:7431` server loads `assets/ssl/server.crt` + `server.key`; the same private key ships on every device. Combined with the client's trust-on-first-use pinning, a LAN attacker who extracts the key could MITM `:7431`, steal the bearer token, and read/alter traffic. The device negotiates TLS 1.3 (the client allows ≥ 1.2), but there is no mutual TLS.
2. **Unauthenticated `:8080` upload** (HIGH). Anything on the LAN can `POST` — `/upload?serialNo=` accepts up to 100 MB `.tgz` and triggers `module.upgrade()` to an attached VivoCube (unauthenticated module/firmware delivery); `/upload/zip` writes files into app storage. No auth filter exists.
3. **Token / capability model** (MEDIUM-HIGH). Pairing needs a physical on-device Approve (good — an unpaired peer can't self-authorize), but tokens are non-expiring UUID bearer secrets, `act=100` auth has no rate-limit/lockout, and a valid token can inject HID keystrokes into the connected PC.
4. **`subDir` path handling** (MEDIUM). Zip-entry traversal is blocked, but the `/upload/zip?subDir=` parameter isn't canonicalized; with `isFull=true` it recursively deletes the resolved directory → arbitrary-directory deletion (within app-accessible storage) plus constrained image-file writes. Weak zip-bomb limits (50 MB compressed cap only).
5. **Cleartext cloud backup** (MEDIUM). `BackupConfigUtils` POSTs `{serialNo, application, content}` over plain `http://` to `gateway.dev.aiks360.com` with no auth header, keyed only by serialNo.
6. **adb-over-TCP helper** (LOW). `RootAdbUtils` can `su` to enable adbd at boot, but no caller was found (appears dead).
7. **Good**: fastjson 1.2.83 is present but **autotype is OFF** (parsed to fixed classes) → the fastjson deserialization RCE is **not exploitable as configured**. OAuth secrets live in a native lib, not plaintext. No backdoor accounts/API keys found in Java. Telemetry SDKs bundled: Tencent Bugly (crash) and iFlytek AIUI (voice).

## Mitigations you control (no device changes)

- Put the CoreBar on an **IoT VLAN / guest SSID** with no route to your PCs/NAS.
- **Firewall `:7431` and `:8080`** so only the one paired controller host can reach them; drop other LAN sources. Never port-forward these.
- Optionally block outbound to `*.aiks360.com` (and the telemetry hosts); note the backup traffic is cleartext.
- Periodically review/revoke paired controllers on the device.

## Implications for Deckhand

Deckhand pins the device cert on first pairing and never sends the token on a cert mismatch, which is the right client-side posture. But because the device's TLS key is shared, that pin is weaker than it looks — the real protection is network isolation above. Deckhand does not weaken the device; it uses the same documented channels.

## What Deckhand itself sends where

Outbound connections the app makes (nothing else; no telemetry, no account):

- **The CoreBar on your LAN** — UDP 5319 (discovery, broadcast or unicast for Add-by-IP), TCP 7431 (TLS control), TCP 8080 (plain-HTTP upload of widget images and the big-screen zip).
- `api.open-meteo.com`, `geocoding-api.open-meteo.com` — weather + city lookup (Weather widget).
- `ipwho.is` — IP geolocation, only when macOS Location is unavailable and no manual city is set.
- `api.coingecko.com` — BTC/ETH prices (Crypto widget).

Local data: the pairing token is a `0600` file under `~/Library/Application Support/UltraWorkspaceMac/tokens/`, the module cache under `.../endpoints/<serial>.json`; the wire log shown in **Logs** has the token redacted. People (contacts) are stored locally and only open deep links (Teams / FaceTime / Mail).

## Mock CoreBar

The mock in `mock-corebar/` is a test double and is **more permissive than the device**: it accepts any `AUTH` token, auto-approves pairing, and does not enforce the device's per-route upload limits (100 MB `.tgz`, 50 MB `.zip`) — it only has a generic 64 MB multer cap and otherwise rejects nothing. Do not expose it beyond localhost.
