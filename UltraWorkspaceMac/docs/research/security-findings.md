# UltraBar X "CoreBar" — Defensive Security Assessment

Read-only review of decompiled (UNTRUSTED) code. No code was executed, no network calls made, no exploits produced. Findings are at the class/finding level.

## Scope / architecture as observed

- **lineos-src** = the CoreBar launcher/OS, package `com.ultrabar.launch` (the on-screen Android launcher). LAN-exposed service: **AndServer HTTP on :8080** (module/image upload + static file serving). Also UDP discovery/announcer. A separate `com.ultrabar.server.PluginServer` exists but binds **127.0.0.1:39001** (loopback, not LAN).
- **bridge-src** = the relay/"hub", package `com.ultrabar.hub`. LAN-exposed service: **Netty TCP+TLS control channel on :7431** (line-JSON). It relays authenticated LAN messages to attached hardware over USB/serial, including **HID keyboard emulation** into a host PC.
- Cloud: `*.dev.aiks360.com` (config backup + OTA version). Cloud itself is out of scope (no code); client-side behavior is noted.
- No PHP anywhere (as expected on Android). Server on :8080 is **AndServer (com.yanzhenjie.andserver)**, not Jetty/NanoHTTPD.

Key third-party libs seen: fastjson **1.2.83** (both apps), OkHttp/okio, Retrofit2, Netty (TLS on bridge), Jackson (`com.fasterxml.jackson`, used by PluginServer), Glide, Tencent **Bugly** (crash telemetry), **iFlytek AIUI** (voice/ASR), kotlin stdlib.

---

## Findings (ranked by severity)

### 1. [HIGH] Unauthenticated HTTP upload on :8080 — module/firmware push + image unzip
- **Evidence:**
  - `com/ultrabar/launch/common/http/WebServerManager.java` (binds `PORT = 8080`, no auth/interceptor).
  - `com/ultrabar/launch/common/http/controller/UploadControllerAdapter.java` (routes `/upload`, `/upload/zip`).
  - `com/ultrabar/launch/common/http/controller/UploadControllerUploadZipHandler.java` (reads `subDir`, `isFull`, `file`; no auth check).
  - `com/ultrabar/launch/common/http/service/UploadServiceIns.java` (`uploadConfig`, `uploadZip`, `unzipWithStructure`).
- **Impact:** Anything on the LAN can POST. `/upload?serialNo=` saves up to a **100 MB `.tgz`** and then calls `module.upgrade(http://ip:8080/...)` to push it to an attached VivoCube sub-module — i.e. **unauthenticated module/firmware delivery to peripherals**. `/upload/zip` writes attacker files into app storage.
- **Mitigation:** Firewall :8080 so only the paired controller host can reach it; require a token/pairing check in the handlers (none exists today); network-segment the device.

### 2. [HIGH] Hardcoded, shared TLS server private key in APK assets (:7431)
- **Evidence:** `com/ultrabar/hub/server/tcp/NettyServer.java` → `getSslContext()` does `SslContextBuilder.forServer(assets.open("ssl/server.crt"), assets.open("ssl/server.key"))`. The server cert **and private key ship inside the app** (`assets/ssl/server.key`), so every device shares the same key.
- **Impact:** With trust-on-first-use on the client side, a static shared key means an attacker who extracts `server.key` from the APK can **impersonate any CoreBar / MITM the :7431 TLS channel** on the LAN, decrypting traffic and stealing the bearer session token (Finding 3). TLS1.3-only is good, but the shared static key negates confidentiality/authenticity against a motivated LAN attacker. No client-certificate (mutual TLS) auth.
- **Mitigation:** Generate a per-device key at first boot; pin the device's own cert in the controller after pairing (proper TOFU with per-device identity). Treat the bundled key as compromised.

### 3. [MEDIUM-HIGH] :7431 pairing/token model — physical approval good; no rate-limit, non-expiring bearer tokens; post-auth = HID injection
- **Evidence:** `com/ultrabar/hub/server/tcp/handler/TokenAuthHandler.java`:
  - `act=101` pairing requires a **physical on-device confirm dialog** (10 s auto-deny) before a token is issued — good; an unpaired LAN peer cannot self-authorize.
  - Tokens are `UUID.randomUUID()` (122-bit, not brute-forceable), stored in app prefs (`Config.authorizationCodes`), **never expire**, matched by plain `equals`.
  - `act=100` token validation (`isValid`/`fail`) does **not close the connection on failure** and there is **no attempt rate-limit/lockout** — unlimited online guessing (infeasible vs UUID, but poor hygiene). `MAX_AUTH=10` is a device-count cap, not an attempt cap.
  - After auth the handler removes itself and traffic reaches `BusinessProcessor` → `com/ultrabar/hub/server/tcp/processor/BusinessProcessor.java`, which relays to hardware incl. **`HidKeyboardOut` keystroke injection into the attached host PC**.
- **Impact:** A paired (or token-stealing, see Finding 2) client gets powerful control incl. keystroke injection into the connected computer. Tokens are long-lived bearer secrets transported in-band.
- **Mitigation:** Add failed-auth rate limiting / disconnect; expire & allow revocation of tokens; bind tokens to the per-device cert; let the user review/revoke authorized devices.

### 4. [MEDIUM] `subDir` path traversal on /upload/zip (arbitrary-directory delete; constrained write)
- **Evidence:** `UploadServiceIns.uploadZip()`: `externalFilesDir = new File(externalFilesDir, File.separator + str)` where `str` = `subDir` request param — **no canonicalization/traversal check on `subDir`**. When `isFull=true`, `deleteDirFiles(externalFilesDir)` recursively deletes that resolved path.
- **Note (what IS safe):** Zip-**entry** names are correctly guarded against zip-slip: `if (!file2.getCanonicalPath().startsWith(canonicalPath)) throw SecurityException`. And extraction only writes image extensions (`jpg/jpeg/png/webp/gif`).
- **Impact:** A traversal `subDir` (e.g. `../..`-style) lets an unauthenticated LAN peer target directories outside the intended profile folder: **recursive deletion** of any dir the app can write (DoS / data loss), and writing image-extension files there. Scope is limited to the app's accessible storage, not full-filesystem.
- **Mitigation:** Canonicalize `externalFilesDir` after appending `subDir` and verify it stays under the base dir (same check already applied to entries); reject `subDir` containing path separators/`..`.

### 5. [MEDIUM] Zip-bomb / resource limits on unzip are weak
- **Evidence:** `UploadServiceIns`: `MAX_ZIP_SIZE = 52428800` (**50 MB, compressed-size cap only**). `unzipWithStructure` has **no per-entry size cap, no total-decompressed cap, no entry-count cap**.
- **Impact:** Decompression amplification / storage exhaustion, bounded somewhat by the 50 MB compressed input and image-only writes, but still a DoS lever on a low-resource device.
- **Mitigation:** Cap decompressed total bytes and entry count; stream with a hard output-size ceiling.

### 6. [MEDIUM] Cleartext HTTP config backup to a "dev" cloud, keyed only by serialNo
- **Evidence:** `chief/utils/BackupConfigUtils.java` POSTs `{serialNo, application, content}` as JSON to **`http://gateway.dev.aiks360.com/api/v1/base-service/pub/backup/put`** (and `/backup/get`) via `OkHttpUtils.sendPostJson` — **plaintext HTTP, no Authorization header, `/pub/` (public) path, a `dev` hostname**. `chief/utils/FetchVersion.java` uses `https://gatewayssl.dev.aiks360.com/.../pub/` for version.
- **Impact:** Device config/profile backups travel in cleartext (sniff/tamper on any network hop) and appear retrievable from the cloud by anyone who knows the `serialNo`. Cloud-side authz is out of scope, but the client shows no auth and a dev endpoint. Potential exposure of device config / integration settings.
- **Mitigation:** Use HTTPS + authenticated, per-device credentials for backup; move off the `dev` endpoint for production; don't rely on serialNo as a secret.

### 7. [LOW] fastjson 1.2.83 present — autotype NOT enabled as configured
- **Evidence:** `com/alibaba/fastjson/JSON.java` → `VERSION = "1.2.83"` in both apps. `ParserConfig`: `AUTO_SUPPORT`/`SAFE_MODE` default from system properties (autotype **off** by default). No `setAutoTypeSupport(true)`, `Feature.SupportAutoType`, or `setSafeMode` anywhere in `com.ultrabar.*`. Control-channel parsing binds to fixed classes (`JSONObject.parseObject(str)` then reads `act`/`id`/`data` in `TokenAuthHandler`; `parseObject(str, DataFlow.class)` / `AckMessage.class` in `BusinessProcessor`).
- **Impact:** The classic fastjson autotype deserialization RCE is **not exploitable as configured** (autotype disabled, no polymorphic `@type` handling on attacker JSON). Residual risk: 1.2.83 is a legacy/EOL 1.x line; any future code that flips on autotype or uses `@type` would reintroduce RCE exposure.
- **Mitigation:** Keep autotype disabled (ideally enable `safeMode`); plan migration to a maintained JSON lib; add a build check that forbids enabling autotype.

### 8. [LOW] Root-assisted ADB-over-TCP enablement code present
- **Evidence:** `com/ultrabar/launch/common/utils/RootAdbUtils.java` runs `su` (`Runtime.getRuntime().exec("su")`) to `setprop persist.adb.tcp.port <port>` and restart `adbd` (`tryEnableAdbOnBoot`, within 40 s of boot). **No caller found in the decompiled sources** (apparently unused/dead, or invoked from code not in this dump).
- **Impact:** If ever active on a rooted unit, it exposes **adbd over TCP on the LAN** — a near-full-control vector (ADB has its own RSA auth, but this is a large surface). Currently appears dormant.
- **Mitigation:** Confirm it is not invoked in production builds; never enable network ADB on shipping devices; firewall the ADB port.

### 9. [LOW] Unauthenticated static file serving on :8080
- **Evidence:** `com/ultrabar/launch/common/http/config/WebServerConfig.java` registers `StorageWebsite` for `cacheDir` at `/tgz` and `filesDir/backup/module` at `/module` — no auth.
- **Impact:** Anyone on the LAN can download uploaded modules/backups (info exposure).
- **Mitigation:** Restrict/authenticate these paths; firewall :8080.

### 10. [INFO] Loopback plugin server auto-accepts registration
- **Evidence:** `com/ultrabar/server/PluginServer.java` binds `127.0.0.1:39001`, **plaintext** line-JSON, `DefaultRegisterHandler` returns `success=true` for any register; session tokens are random UUIDs.
- **Impact:** Not LAN-exposed (loopback), so low risk; relevant only to a local malicious app on the device. Worth noting the trust model is "any local process may register as a plugin."
- **Mitigation:** Keep bound to loopback; if local app isolation matters, authenticate plugin registration.

### 11. [INFO] Telemetry components
- **Evidence:** `com/tencent/bugly/*` (crash reporting) and `com/iflytek/*` (AIUI voice/ASR) are bundled. These ship device/crash and (for voice) audio-derived data to their respective clouds.
- **Impact:** Standard third-party telemetry; data egress to Tencent/iFlytek. Not analyzed in depth (SDKs, not app code).
- **Mitigation:** Review/disable if telemetry/voice egress is unwanted; block those hosts at the firewall.

---

## Bottom line

- **fastjson autotype RCE:** present library (1.2.83) but **autotype is disabled and never turned on** → not exploitable as configured.
- **Unauthenticated :8080 upload:** **real and unauthenticated** — any LAN host can upload modules/images and trigger a module push to peripherals.
- **Path traversal:** zip-**entry** traversal is **correctly blocked**; the **`subDir` parameter is not** (arbitrary-directory recursive delete + constrained image-file write).
- **Biggest systemic weakness:** the **shared, hardcoded TLS key** on :7431 undermines the otherwise-sensible physical-approval pairing.

## User-controlled mitigations (no device changes needed)
1. Put the CoreBar/hub on an **isolated VLAN / IoT SSID** with no access to PCs, NAS, or other trusted hosts.
2. **Firewall both ports** so only the single paired controller (e.g. the Mac app's host) can reach **:7431** and **:8080**; drop everything else, including from other LAN devices.
3. Block/monitor outbound to `*.aiks360.com` (and Tencent/iFlytek) if you want to limit cloud egress; note backup traffic is cleartext HTTP.
4. Review and periodically **revoke paired devices** on the hub; treat the bearer token as a long-lived secret.
5. Keep the device off guest networks and never expose these ports through the router/port-forwarding.
