# CoreBar local protocol (as implemented here)

Recovered from the decompiled "VivoCube Weather Tool" (.NET), the official UltraWorkSpace 1.0.1.0 macOS binary (Qt, not stripped — the highest authority on what a PC client *sends*), and the LineOS 1.0.9 launcher APK (the authority on what the device *accepts*). Everything below is the **local** PC↔CoreBar protocol; the CoreBar relays to its attached QuantumLink modules (VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card). Statements are tagged **CONFIRMED** (read from code/disassembly, usually matching both sides) or **HYPOTHESIS** (inferred, to be verified on hardware) where the distinction matters; the detailed evidence is in `docs/research/` (`official-client-findings.md`, `vivocube-findings.md`, `corebar-pages-findings.md` and the older reports).

## Transports (device bridges)

The campaign describes four "protocol bridges" on the CoreBar: **USB/HID**, **IP Network**, **Bluetooth Mesh**, and **QuantumLink** (the magnetic module bus). Everything documented below is the **IP Network** bridge — the one this app uses. The USB/HID bridge (USB-C, no drivers; USB identity `VID_1F3A&PID_2000` with a serial/PC-LINK channel) is unmapped here but is the likely route for driverless keystroke macros and PC-stat feeds; Bluetooth Mesh covers wireless management and one-tap PC wake. Note that ADB (port 5555) is closed on the CoreBar.

## Transport (IP Network)

- **Discovery**: UDP on port **5319**. CONFIRMED: the vendor client broadcasts the plain 18-byte ASCII string `discovery.ultrabar` to the **interface broadcast address** (falling back to `255.255.255.255`) every **2000 ms**, ignores datagrams from its own addresses, and de-duplicates replies by `serialNo`. The JSON probe `{"act":"discover"}` (what the weather tool and Deckhand send) also works on the tested firmware. A CoreBar replies with `{"serialNo","ver":"1.0.9(9)","ip","name":"ultrabar","tcpPort":7431}` (`tcpPort` is the field a client must read). The vendor client only broadcasts while its "Search Core Bar" dialog is open; it also offers manual entry of an IP + port, like Deckhand's *Add by IP…* (a unicast of the same probe).
- **Control**: TLS over TCP, default port **7431**, SNI `ultrabar.local`. The device negotiates TLS 1.3; Deckhand allows ≥ 1.2 (`sec_protocol_options_set_min_tls_protocol_version(.TLSv12)`). The CoreBar uses a self-signed cert (the same private key on every device, see `docs/SECURITY.md`). CONFIRMED: the vendor client embeds a root CA (`cb_root_ca.crt`, CN `ultrabar.local`, O sanytron, RSA-4096, valid 2026-07-07 → 2126-06-13) but then disables peer verification and calls `ignoreSslErrors()`, so it effectively verifies nothing. Deckhand is stricter: trust-on-first-use — pin the SHA-256 of the presented leaf certificate at pairing, and on later connections abort *before* sending the token if it no longer matches. Messages are UTF-8 JSON objects, one per line (`\n`-delimited); request key order in the vendor client is `id, act, data`, and `id` is a decimal string from a global counter (Deckhand uses hex strings; the device only echoes it).
- **Connection model**: the vendor client keeps **one persistent connection** per CoreBar and sends `{"act":20,"id":…}` (HEARTBEAT_PACKAGE, no data, no reply expected) every **3 s** when nothing was received for 1.5 s; it declares the link dead after 15 s without any inbound frame and reconnects every 30 s (CONFIRMED). Deckhand instead opens **one connection per operation** (pair/auth, then the request, then close), so it never needs the heartbeat; the trade-off is that device-initiated pushes (`PUSH_MESSAGE` 1000000, 30102, 1635, 30104, 30601) only arrive while such a connection is open.
- **Upload**: HTTP on port **8080**, `POST /upload?serialNo=<serial>`, `multipart/form-data`, field `file`. The device ignores the filename and content type (it only checks the `.tgz` extension and a 100 MB cap): the vendor client sends filename `config.tgz` with `application/octet-stream`, Deckhand sends `<serial>.tgz` with `application/gzip`. Reply semantics are in *Layer package (tgz)* below — `"state":200` means the module **acknowledged** the update command, not that it has applied it.

## Control messages

Every request is `{"act":<int>,"id":"<string>","data":<value>}`; replies echo `id` and usually carry `code` (200 = ok, -1 = fail) plus `msg` and `data`. The vendor client treats a reply as valid only if `act` equals the request's act and `code == 200` (its own error codes: 6000 "Request api timeout", 6001 "CoreBar reply error").

| act    | meaning            | data (request)                                             | reply |
|--------|--------------------|------------------------------------------------------------|-------|
| 101    | pair (REQ_AUTH_TOKEN) | `{id, name}` — CONFIRMED: the vendor client sends a **fixed, hard-coded UUID** `550e8400-e29b-41d4-a716-446655440000` as `id` and `"Ultra WorkSpace"` as `name`; there is **no `clientType`** key anywhere in it (Deckhand's extra `clientType:"pc"` is ignored by the device) | `data.state` truthy and `data.token`, once the user taps **Approve** on the CoreBar; the vendor client waits **15 s** ("authorize on the Core Bar within 15 seconds"), Deckhand waits 30 s |
| 100    | authenticate (AUTH)   | `"<token>"` — a bare string, not an object (CONFIRMED)  | `code == 200` on success; vendor timeout 3 s |
| 20     | HEARTBEAT_PACKAGE  | none                                                        | none (fire-and-forget keep-alive on a persistent connection) |
| 30100  | **MODULE_START_DISCOVERY** — live bus scan | `"can"` (magnetic bus) or `"mesh"` (wireless) | fire-and-forget; results arrive as pushed 30102 messages |
| 30102  | MODULE_START_DISCOVERY_REPLAY | (pushed by the CoreBar)                     | one per found module; `data` is a module endpoint |
| 30300  | **SET_GATEWAY_CONFIG** — provision modules | the `CoreBarConfiguration` object directly | writes the discovered endpoints into the gateway config |
| 30200  | read property      | `{serialNo, deviceId:256 (or sub-device id), propertyId, extra:null}` | `data.result` (integer) |
| 30201  | write property     | `{serialNo, deviceId:256 (or sub-device id), propertyId, value}` | `code` |
| 1300   | GET_DEVICE — logical/integration device list | `{}`                             | `data` = array of `{id, name, deviceType, online, …}` (empty on this firmware for physical modules) |

### Enumerating modules is a live scan, not a config read

On the firmware tested here the static config reads come back **empty**: `GET_DEVICE` (1300) and `QUERY_MODULE_STATE` (30730) return nothing useful for the physical QuantumLink modules, and `GET_COREBAR_CONFIG` (30740) with `{type:"GATEWAY_CONFIG"}` returns `null`. (An earlier version of this client listed modules with 30730 and always got an empty array back.)

The app's `listModules()` still tries the gateway-config read **first** (cheap, and kept for firmwares that do answer), then falls through to the live scan below, and only if that finds nothing to `GET_DEVICE` (1300). On the tested firmware the live scan is the source of truth.

Enumeration is therefore a **live QuantumLink bus scan**:
1. Fire `MODULE_START_DISCOVERY` (30100) with data `"can"` for the magnetic bus and again with `"mesh"` for the wireless bus.
2. The CoreBar then *pushes* `MODULE_START_DISCOVERY_REPLAY` (30102) messages, one per module it finds. Each `data` is a module endpoint carrying a serial (`serialNumber` / `serialNo` / `uid`), an optional `name`, an `online` flag, a `productId`, and an `interfaceType` (`"mesh"` for wireless, otherwise the magnetic/CAN bus).
3. Collect replies for a fixed window (~16 s) and de-duplicate by serial.

### Provisioning (making modules controllable)

A discovered module isn't controllable until its endpoint is written into the gateway config. The app writes it with `SET_GATEWAY_CONFIG` (30300), whose body **is** the `CoreBarConfiguration`:

```json
{"canGateway": {"endpoints": [ … ]}, "meshGateway": {"endpoints": [ … ]}}
```

Endpoints are split into `meshGateway` (those with `interfaceType == "mesh"`) and `canGateway` (the rest).

- `SET_COREBAR_CONFIG` (30741) with `{type:"GATEWAY_CONFIG", value: CoreBarConfiguration}` is accepted per the launcher source, but on the firmware tested it fails server-side with a `ClassCastException` (it wraps the configuration in a `ReadWriteRequest`). That is why the app uses 30300. This is the one place this caveat is stated; the "Device settings" section below refers back here.
- **Asleep-module merge.** Each provision starts from the endpoints last written to that CoreBar (cached per CoreBar on the Mac) and overlays the freshly-discovered ones. A module that is asleep during a scan (often the DotKey) therefore stays in the config instead of being dropped. A freshly-discovered endpoint overrides its remembered copy.
- If an upload is rejected with "module not found", the app provisions once and retries the upload.

### QLinkProductId (physical module type)

Endpoints carry a `productId`; the known integer values are:

| productId   | module        |
|-------------|---------------|
| 268435456   | EXT_SCREEN (the CoreBar's own screen) |
| 268435457   | DOT_KEY       |
| 268435458   | KNOB_KEY      |
| 268435459   | VIVO_CUBE     |
| 268435460   | SENSE_CUBE    |
| 268435461   | PC_BOOT_CARD  |

(`-1` is the gateway itself.)

## Full act-code catalog (`MessageAction`, from LineOS 1.0.9)

The CoreBar's PC-facing command set, recovered from LineOS `com.ultrabar.launch.common.communication.bean.MessageAction`. Response envelope: `{act, id, code, data, timestamp}` (`code == 200` = success). `GET_DEVICE` returns `Device` objects: `{id, name, deviceType (DeviceEnum), online, supportedFeatures, attr}`. `DeviceEnum`: VIVO_CUBE, SENSE_CUBE, PC_BOOT, COMPUTER_INFO, AUDIO_PLAYER, ACTION, SCENE, EMAIL_CARD, SWITCH, LIGHT(/_TEMP/_HS/_HS_TEMP), CURTAIN(_SWITCH), AC, FAN, TEMPERATURE_SENSOR, HUMIDITY_SENSOR, UNKNOWN.

| code | name | code | name |
|------|------|------|------|
| 10 | ERROR | 1617 | GET_KNOB_FUNCTION_DEVICE |
| 11 | EXCEPTION | 20100 | SYS_REBOOT |
| 20 | HEARTBEAT_PACKAGE | 30100 | MODULE_START_DISCOVERY |
| 100 | AUTH | 30101 | MODULE_STOP_DISCOVERY |
| 101 | REQ_AUTH_TOKEN | 30102 | MODULE_START_DISCOVERY_REPLAY |
| 1000 | GET_APP_LIST | 30103 | GATEWAY_SUB_PAIRING |
| 1002 | GET_PROFILE_WIDGET | 30104 | GATEWAY_PAIRING_RESULT |
| 1010 | INTEGRATED_CONFIG_SET | 30200 | MODULE_PROPERTY_READ |
| 1103 | TRIGGER_PROFILE_CHANGE | 30201 | MODULE_PROPERTY_WRITE |
| 1108 | BATCH_SAVE_PROFILE | 30300 | SET_GATEWAY_CONFIG |
| 1204 | SCENE_TRIGGER | 30400 | MODULE_OAT_START (OTA) |
| 1205 | SCENE_ACTION_V2 | 30401 | MODULE_OAT_DATA (OTA) |
| 1300 | GET_DEVICE | 30500 | BATCH_CREATE_SCENE |
| 1500 | LIST_EMAIL_CONFIG | 30600 | APP_MANAGER |
| 1501 | SAVE_EMAIL_CONFIG | 30601 | APP_MANAGER_PROGRESS_EVENT |
| 1502 | DEL_EMAIL | 30700–30721 | SCENE_* dependency queries |
| 1633 | START_SCAN_WIFI | 30730 | QUERY_MODULE_STATE |
| 1634 | STOP_SCAN_WIFI | 30740 | GET_COREBAR_CONFIG |
| 1635 | CUBE_SCAN_WIFI_LIST_RESULT | 30741 | SET_COREBAR_CONFIG |
| 1000000 | PUSH_MESSAGE | 30742 | PREVIEW_SCREENSAVER |
| | | 30750–30752 | THREE_CAPABILITY_* |

### What the vendor client actually uses (CONFIRMED from the UltraWorkSpace 1.0.1.0 binary)

Sent: 20, 100, 101, 1000, 1002, 1010, 1103, 1108, 1205, 1617, 1633/1634, 30100/30101, 30103, 30200/30201, 30300, 30400/30401, 30500, 30600, 30700, 30730, 30750/30751/30752. Consumed as pushes: 1635, 30102, 30104, 30601, 1000000. Reply timeouts are 5 s for most calls, 8 s for 1010/1108/30500, 12 s for 30400, 15 s for 101, 3 s for 100.

- **1617 GET_KNOB_FUNCTION_DEVICE** — `data` = tree node id string; returns the devices a KnobKey rotation can be bound to (`{name, type, id}`; firmware `KnobDevice{id, type}` with types `PC_VOLUME`, `PC_BRIGHT`, `LOCAL_VOLUME`, `AUDIO_PLAYER`, `LIGHT_*`, `AC`, `CURTAIN`, `FAN`).
- **1205 SCENE_ACTION_V2** — `data` = tree node id string; the scene-action catalogue tree (what a DotKey press / automation may do).
- **30700 SCENE_GET_TRIGGER_PARAM** — automation trigger types and their child data (the vendor only calls this root; 30701–30721 are not used by it).
- **30750 / 30751 / 30752 THREE_CAPABILITY_ACTION / PARAM / OPTION** — third-party app capabilities: `getAppCapabilityActions(packageName)`, `…Params {actionId, packageName}`, `…ParamValues {actionId, packageName, describeId, cursor, limit, params}`.
- **30600 APP_MANAGER** — **CONFIRMED on hardware 2026-11-03** (launcher `AppManagerMessage` + `AppRequest`): `{type: 0|1|2, appType: 100, packageName}` with `type` 0 = status (reply `{status:"INSTALLED"|"NOT_INSTALLED", versionCode, versionName}`), 1 = install, 2 = uninstall. The PC sends **no URL**: the bar itself looks the package up in the vendor cloud (`apps/<appType>/<packageName>/fetchLastVerV2`, `appType` 100 = the CoreBar app store), downloads and installs it (MAMate 1.0.2 was INSTALLED within 10 s). The vendor client first calls `fetchLastVerV3` only to show version/size in its dialog. Progress arrives as pushed **30601** `{packageName, type:"DOWNLOAD"|"INSTALL"|"STATUS", result}` with states `DOWNLOADING, INSTALLING, INSTALLED, NOT_INSTALLED, FAIL`; the first push (`STATUS: DOWNLOADING`) comes back on the request's own connection, the rest only on a persistent one. Only one install runs at a time (busy → `onInstallFailed`). `kitcheck app <ip> <serial> status|install|uninstall <packageName>`.
- **30730 QUERY_MODULE_STATE** — `data` = array of module serials → online state (used for the online badge; returned empty on the firmware tested here with Deckhand's call shape).
- **30400 / 30401 module OTA** — see *Module OTA* below.

Not used by the vendor client although the firmware handles them: **1300 GET_DEVICE**, 1204, 1500–1502 (email), **20100 SYS_REBOOT**, 30701–30721, and **30740 / 30741 / 30742** (CoreBar config, screensaver config and screensaver preview). The vendor client never reads configuration back from the device except the catalogue reads (1000, 1002, 1617, 1205, 30700, 30750–30752) and 30730: the PC project file (`*.umpf`, SQLite) is the authoritative copy, and every "Deploy project" rewrites the device.

### Module OTA (30400 / 30401) — CONFIRMED from the vendor client and firmware

- File format: `*.bin`, 64-byte header `UBX-OTA-FILE` — `[0:12]` magic, `[12:16]` productId u32 BE (must equal the module's productId, else "Product ID mismatch"), `[16:32]` versionName (NUL-padded), `[32:36]` versionCode u32 BE, `[36:52]` MD5, `[52:64]` reserved. **MD5 = md5(file[0:36] + file[64:])** (verified on `Sence.Cube_V2_ota.bin`); the client refuses files < 64 B or ≥ 256 KiB.
- **30400 MODULE_OAT_START** `data = {gatewayType:"can"|"mesh", epSn:"<moduleSn>", fileSize, packSize, fileMD5}` (12 s timeout) → reply `data = {epSn, err}` with 0 ok, 1 "Reboot module timeout", 2 "Start OTA timeout", 255 other. The CoreBar reboots the endpoint, waits ≤ 8 s for it, then sends CAN cmd 17 `{sn, fileSize u32, packSize u8, md5}`, so `packSize ≤ 255` (vendor dialog: 200 for `can`, 32 for `mesh` — LIKELY).
- **30401 MODULE_OAT_DATA** `data = {gatewayType, packNumber:<0-based>, isEndPack:<bool>, data:"<hex of ≤ packSize bytes>"}`, sent sequentially; each pack is answered with `{epSn, err}` (0 ok, 254 data timeout, 255 other; 2 retries, 2 s per pack / 5 s for the last one).
- The 24 KB `VivoCube_V2_20260728_ota.bin` linked from the vendor's GitHub is such an STM32 HID blob — it is **not** the VivoCube display firmware and contains no LVGL or `com_res` strings.

The complete QuantumLink module protocol (how the CoreBar talks to each module over the magnetic bus / CAN / Mesh) lives in the `quantum.link` package of the LineOS/CoreBridge APKs: `QLinkVivoCube`, `QLinkSenseCube`, `QLinkKnobKey`, `QLinkDotKey`, `QLinkPCBootCard`, VivoCube widgets (`VCWidget*`), sensors, and `HidKeyboardOut` (USB-HID keystroke output for button macros). This is the reference for building out widget, sensor, KnobKey/DotKey, and OTA support.

`deviceId` for the main device inside a VivoCube is **256** (`Proto.deviceMain`). The SenseCube is different: its main device id is **0** (not 256), and its sensors are addressed as sub-devices **10 / 11 / 12 / …** (see *SenseCube sensors* below).

### Known property IDs (VivoCube main device)

| id | name        | notes                          |
|----|-------------|--------------------------------|
| 3  | runTime     | uptime seconds (read)          |
| 4  | screen      | 0 = off, 1 = on (read/write). **The CoreBar caches the last written value** and re-applies it every time the module asks for status (after every reboot/reconnect/config apply) — see *Black screen* below. |
| 5  | reboot      | write `true`                   |
| 6  | wifi        | Wi-Fi state (read): 0 not configured, 1 connected, 2 not connected, 3 connecting (vendor strings; property number HYPOTHESIS) |
| 7  | wifiConfig  | ssid/password as a hex string (read/write by the vendor client; layout not recovered) |
| 9  | layerWidget | `(layerId << 16) \| widgetId` — which layer/widget the cube shows (read/write). CONFIRMED: this is what the firmware's `VIVO_CUBE_TOGGLE` scene action writes (`VCWidgetMain.writeLayerAndWidgetId`); the CoreBar caches it and re-sends it on every status round, like property 4. Deckhand: `CoreBarSession.setLayer` / `readLayerWidget`. |

## Module image format

CONFIRMED byte-for-byte against the vendor client's `PixmapToLVGLBinUtils::pixmapToLVGLBin`: the `.bin` is an **LVGL v8 image** (`lv_img_header_t` + data size + pixels, `LV_COLOR_DEPTH 16`, `LV_COLOR_16_SWAP 1`).

- Scan for any pixel with alpha ≠ 255 → `hasAlpha`.
- Bytes/pixel: 2 (RGB565, `cf` 4 = `LV_IMG_CF_TRUE_COLOR`) if opaque, 3 (RGB565 + 1 alpha byte, `cf` 5 = `LV_IMG_CF_TRUE_COLOR_ALPHA`) if `hasAlpha`.
- `word` (uint32 LE at offset 0) = `cf | (width << 10) | (height << 21)`, i.e. the LVGL bit layout `cf:5 | always_zero:3 | reserved:2 | w:11 | h:11` (width and height are 11-bit; this is the same value as the older formula `(((width & 0x7FF) | (height << 11)) << 10) | flag`).
- uint32 LE at offset 4 = payload byte count = `width*height*bpp`.
- Pixels row-major, no padding; each RGB565 value written **big-endian** (high byte first): `((R>>3)<<11) | ((G>>2)<<5) | (B>>3)`, then the alpha byte if `hasAlpha`.
- Alpha source: the vendor encoder reads **straight (non-premultiplied) RGBA8888**. Deckhand renders premultiplied, so its alpha output would differ in colour; that is why `DeviceImage.encode` is **opaque-only by default** (`allowAlpha: false`, every pixel forced to alpha 255 → `cf` 4) and alpha is an explicit opt-in that must be tested first.

**The image is an icon, not a framebuffer** (CONFIRMED). The only deployable widget type is `type` 1 = Button, whose unpressed/pressed bitmaps are the `.bin` files; there is no background or full-screen item type and no position/size keys. The vendor client scales the user's icon to `iconScale`% of **240 px** (slider 10–100, default 60 → 144 px, max 100 → 240 px), keeps aspect ratio, trims transparent borders, and renders the pressed bitmap at 0.8×; so 240 × 240 is simply the vendor's 100 % icon size and Deckhand renders its cards at that size (`AppModel.canvasSize`). The **physical panel resolution is not in the client or the launcher** (the vendor UI models the screen as a square whose full width equals a 100 % icon); photos suggest the panel is larger than the 240 px icon (HYPOTHESIS: ≥ 320 px). Nothing stops a client from sending a larger bitmap (11-bit width/height), so Deckhand's **Panel size test…** menu on the VivoCube page pushes opaque 240…480 px test patterns to measure it on the glass.

## Layer package (`tgz`)

A gzip-compressed **ustar** tar (standard octal header fields, standard checksum — the weather tool's `EmulateVendorChecksumBug` flag is not needed and stays off) containing:

- `com_res<widgetId>/default.bin` — the encoded default (unpressed) image.
- `com_res<widgetId>/pressed.bin` — the encoded pressed image (vendor client: 0.8× the default; Deckhand reuses the default bitmap).
- `config.json` = `{"defaultLayer":<D>,"layers":[{"id":<L>,"items":[{"id":<W>,"type":1}]}, …]}`. CONFIRMED: items carry **only** `id` and `type` (`type` must be 1); there are no x/y/w/h/scale keys. Limits enforced by the vendor client: **6 layers × 6 widgets per layer**; layer and widget ids are integers 1…65535 (the firmware rejects anything else because property 9 packs them as `(layer<<16)|widget`).

One package holds **all** layers of the module. Deckhand's rotation builds exactly that: layer *n* carries widget id `100 + n` (`AppModel.widgetId(forLayer:)`), `defaultLayer` 1, at most `AppModel.maxVivoLayers` = 6 layers. The vendor convention `layer 1 / widget 101` for a single-widget deploy is the same thing.

The vendor client also stores the same layer/widget description on the CoreBar: the module endpoint it writes with 30300 carries `extraConfig = {netConfig:{ssid,password}, dataConfig:{layers:[{id, name, default, widgets:[{id, uniqueId, name, type:1, icon, iconScalePercent, iconUnpressed, iconPressed}]}]}}` (endpoint keys in emission order: `interfaceType, uid, name, serialNumber, workMode, productId, netId, extraConfig`). The CoreBar uses `dataConfig` only to instantiate button objects so that key events for those widget ids are dispatched ("widget not found, widgetId:…" otherwise); it is not pushed to the module. Deckhand does not write `dataConfig` today.

### Upload semantics (`POST /upload?serialNo=`) — CONFIRMED from the launcher

1. The CoreBar writes the body to `<cacheDir>/tgz/<serial lowercased>.tgz`, **deleting any previous file first**, and serves `cacheDir` statically under `/tgz` (so the file is reachable at `http://<corebar>:8080/tgz/tgz/<serial>.tgz`).
2. It sends the module `CMD_UPDATE_CONF` (0x31) whose payload is the URL `http://<corebar>:8080/tgz/<serial>.tgz` (the CoreBar's hotspot IP if the module is on the hotspot, else its Wi-Fi IP) and waits up to **5 s** for the module's status byte.
3. The **module downloads and unpacks the tgz itself over its own Wi-Fi link** (not over the magnetic bus) and re-applies the layer config. The CoreBar never parses the package.

Reply `{"state":<int>,"msg":…,"data":…}`:

| state | meaning | vendor UI text |
|---|---|---|
| 200 (`data:""`) | the module **acknowledged** the command (status 0) within 5 s — **not** downloaded, **not** applied yet | "Upload succeeded. Please wait for VivoCube to complete update." |
| -1 | no reply from the module within 5 s (`msg` "write update command success,update timeout") | — |
| 1 | module busy | "VivoCube is currently busy." |
| 2, 4 | module not connected to a network (fix the module's Wi-Fi, not the image) | "VivoCube is not connected to the network." |
| 3 / other | module error N (`msg` "reply error:N") | "Upload error: <msg>" |
| -1 with other `msg` | server-side: "serial required", module not found (not provisioned — Deckhand provisions once and retries), "hotspotIp ip address is empty", file > 100 MB, write failure | — |

`data` is an integer only on `/upload/zip` (count of extracted images); `/upload?serialNo=` always returns `data:""` on success.

Consequences: there is **no queue, busy flag or rate limit on the CoreBar** — a second upload while the module is still fetching the previous one replaces the file under it (truncated archive risk), and **every accepted upload rewrites the module's flash copy** of `com_res<id>/*.bin` (~230 KB per 240 × 240 opaque pair). That is why Deckhand uploads one multi-layer package, waits `AppModel.vivoSettleSeconds` (10 s) for the module to apply it, and then rotates with property 9 instead of re-uploading every interval (contents are re-uploaded only every few minutes).

### Black screen — mechanism and recovery (CONFIRMED mechanism)

`VCWidgetMain.onPropertyReport`: whenever the module sends a status request (property 0, which it does after every reboot/reconnect and plausibly after applying a package), the CoreBar re-writes the system time plus its **cached property 4 (screen state) and cached property 9 (layer/widget)** if they were ever written during the CoreBar process lifetime. A stale "screen off", or a layer/widget id that the newest `config.json` no longer contains, is therefore re-applied forever and the cube stays dark. Recovery: read properties 4 and 9, then write property 4 = 1 and property 9 = `(defaultLayer<<16)|firstWidgetId` — Deckhand's **Recover display** button (`CoreBarSession.recoverDisplay`: screen on + layer 1 / widget 101). Avoid *Screen Off* during a rotation session. Other candidates for a black cube (HYPOTHESES): a truncated tgz from overlapping uploads, flash wear from hundreds of rewrites, or an alpha (`cf` 5) image that the firmware composites over black.

### Switching layers (rotation) — CONFIRMED vendor design

The vendor client never writes property 9 directly; a layer change is the scene action `VIVO_CUBE_TOGGLE` with `values:[{"id":"1","value":"<layerId>"},{"id":"2","value":"<widgetId>"}]`, which the CoreBar turns into `TOGGLE_LAYER` → `writeLayerAndWidgetId(layer, widget)` → property **9** = `(layer << 16) | widget` on deviceId 256. A PC client can do the same with `MODULE_PROPERTY_WRITE` (30201) `{serialNo, deviceId:256, propertyId:9, value:(layer<<16)|widget}`; `widget` should be a widget id that exists in that layer. Property 9 is readable, so the current page can be queried. "Upload up to 6 layers once, then toggle" is the intended operating model; that the firmware shows the toggled layer instantly without a reload is a HYPOTHESIS the vendor's own scene action relies on.

## CoreBar big screen (1424×280)

The CoreBar runs LineOS (`com.ultrabar.launch`); the screen protocol lives there (the bridge APK is just a relay). Unlike modules, the big screen takes **ordinary image files** (jpg/jpeg/png/webp/gif) at 1424×280 — no RGB565/tar.

**There is no full-screen image page** (CONFIRMED). The home screen is a horizontal strip of fixed-size cards (`HomeActivity`, horizontal `RecyclerView`); a profile with one widget shows one card on a dark background, not an edge-to-edge image. The clock (TIME) card is ≈ 540 × 240 px — roughly a third of the screen — and shows its `icon` as a rounded cover image with a blurred, dimmed copy as the card background. A "picture" on the big screen is therefore the TIME widget's `icon`; an "image button" is a `PC_CONTROL` or `SCENE` card with a custom `icon`. True full-screen output exists only as the one-shot `PREVIEW_SCREENSAVER` (30742) or through a separate screensaver APK (below). The vendor client never hard-codes the 1424 × 280 size; only the on-device layout knows it.

**Pages / profiles (Stream-Deck-like).** `AppData` holds a `List<Profile>`; a profile is a page whose `widget[]` is the ordered card strip (order = on-screen order; no x/y).
- `BATCH_SAVE_PROFILE` (1108): `data` = array of `ProfileDTO` — **replaces the whole page list** (`appData.setProfiles`, no merge). A missing or empty `data` array saves an **empty** list and wipes the home screen (CONFIRMED) — never send 1108 without the complete, non-empty array. Reply on success `{"code":200,"data":"success"}`; a validation failure (`ParamException`) comes back as `{"code":-1,"msg":"profile id cannot be empty"|"item is not null"}` and saves nothing. After a save the device re-binds module key maps and exits the screensaver.
- `TRIGGER_PROFILE_CHANGE` (1103): `data` = profile id **string** → `{"code":200,"data":"ok"}` or `{"code":-1,"msg":"profile id error"}`; switches the card strip, exits the screensaver and 500 ms later rebinds module configs. **Nothing is pushed back to the PC** on a profile change (CONFIRMED), and the selection is kept in memory only (the `isDefault` profile returns after a reboot — HYPOTHESIS that nothing persists it). On-device switches (overlay panel, `CHANGE_PROFILE` scene action) are invisible to the client, so track your own 1103 calls.
- **No act returns stored profiles with their widgets** (CONFIRMED by exhausting the launcher's `MessageFactory`). `GET_PROFILE_WIDGET` (1002) is a **catalogue** of placeable nodes (`data` = parent id string; roots `sys.widget.iot` and `sys.widget.apps`; TIME/WEATHER/PC widgets are not in it — clients know them statically). The cheap listing is `SCENE_DEPENDS_PROFILE` (**30710**, no input) → `data:[{label:<name>, value:<id>, last:true}, …]` over all stored profiles: use it to learn the ids on the device, to verify a save, and to detect that another client re-deployed. The device's factory default profile has id `"default"`.
- **Vendor deploy order** (CONFIRMED, "Deploy project"): 30300 SET_GATEWAY_CONFIG (all module endpoints) → 1108 BATCH_SAVE_PROFILE (all profiles) → 1010 INTEGRATED_CONFIG_SET per integration (AccuWeather: `{packageName:"com.ultrabar.weather", apiKey, lat, lon, …}`) → 30500 BATCH_CREATE_SCENE (all automations) → `POST /upload/zip` with `core_bar_assets.zip` → 1103 with the selected profile id. No read-back before writing; whichever client deploys last wins, and on-device edits are overwritten too.

**`ProfileDTO` on the wire** (CONFIRMED from the vendor client's `makeDeployData` and the launcher's `ProfileManager.toProfile`):

```json
{"id":"<string, required, non-empty>", "name":"…", "showName":true, "icon":"<http URL | resId://name | relative path | file:///…>", "iconScale":100,
 "default":true,
 "widget":[{"id":"<unique in profile>", "type":"<WidgetType>", "name":"…", "icon":"…", "iconScale":100, "param":{…}}],
 "module":[{"productId":"<DOT_KEY|KNOB_KEY|VIVO_CUBE|SENSE_CUBE|PC_BOOT>", "serialNo":"<sn>", "config":{…}}]}
```

- `id` must be non-empty (and not `"null"`); `widget` must be an array (may be `[]`); everything else is optional. `default` is what fastjson emits for the bean's `isDefault`; the key `isDefault` is accepted on input too. `iconScale` ≤ 0 is coerced to 100. `showName` defaults to true. `module` null → `[]`. Keys the device ignores on input: `albumId` (**dead** — it exists with default `"time_image_10"` but has no reader and is never copied from the DTO; the vendor client never emits it), `player`, `homeData`. `bgColor` is accepted but unused and never sent by the vendor.
- Built-in widget ids used by the vendor/device: `sys.component.time` (TIME), `sys.component.weather` (WEATHER); other ids are free-form short UUIDs but must be unique within the profile. Keep ids stable across saves: on 1108, a TIME widget with an **empty `icon`** keeps the image currently stored on the device for the same profile id + widget id (`TimeParamConverter`); to reset, send an explicit `"resId://time_image_2"` (built-ins `time_image_2,3,4,5,7,8,9,10,11`).
- Vendor icons are rewritten at deploy to `file://<externalFilesDir>/CoreBarAssets/image/<uuid>.png` — the zip it uploads has the top-level folder `CoreBarAssets/image/`.

**Widget types and `param` schemas** (CONFIRMED from the launcher's parameter beans and the vendor client's `deploymentData`; always send `param` as an object for the types that have one — a missing `param` is tolerated at save time but the card may crash at render):

| `type` | `param` | custom `icon` rendered |
|---|---|---|
| `TIME` | none | **yes** — the clock card's cover/background |
| `WORLD_TIME` | `{"offset":"GMT+0:00"}` (vendor UI calls it `timeZone`; wire key is `offset`) | no |
| `WEATHER` | `{"lat":"<str>","lon":"<str>"}` (empty → network location); API key/units via 1010 `{"packageName":"com.ultrabar.weather","config":{apiKey, isUnitFahrenheit, …}}` | no |
| `TIMER` | `{"time":"HH:MM:SS", "startSceneId"?, "endSceneId"?}` (needs `com.ultrabar.countdown`) | no |
| `SOUNDSCAPE` | `{"id":"sys.app.soundscape.1"}` (needs `com.ultrabar.whitenoise`) | no |
| `PC_CONTROL` | `{"output":5,"keys":[<HID usage ids>]}` = keystrokes the CoreBar emits over USB-HID itself, or `{"output":10,"payload":<any>}` = pushed to the PC as `PUSH_MESSAGE` type `PC_CONTROL` | **yes** (scaled by `iconScale`) |
| `HOT_KEY_GROUP` | `{"button":[<PC_CONTROL-like children>]}` (vendor plugin "shortcut groups"; also carries `pluginUuid`) | **yes** |
| `SCENE` | `{"type":"ACTION"\|"HA_SCENE"\|"LOCAL_SCENE", "actions":[…]}` (vendor sends `{type:"ACTION", deployData:{actions:[…]}}`) | **yes** |
| `CPU`, `MEMORY`, `STORAGE`, `NETWORK` | `{"data":"<string>"}`; values come from `PUSH_MESSAGE` queries to the PC (`ScheduledQueryRegistry`) — without a PC replying they stay empty | no |
| `SENSE_CUBE`, `SENSE_CUBE_TEMP/HUM/ALS/AUDIO/RADAR` | `{"uid":"<module uid>"}` (vendor sends `moduleUid`) | no |
| `PC_BOOT` | `{"uid":"<module uid>"}` | no |
| `APPS` | none; vendor sends `{"package":…}`; **`id` must be the package name** — the launcher matches the saved widget to an installed app by `id` (`HomeDataSource.getProfile`) and draws that app's icon; `com.ultrabar.homeassistant` is excluded from the app list; the `screensaver` app is hidden from the vendor's picker. GET_APP_LIST (1000) on LineOS 1.0.9.9 answers only `{appName, packageName}` (no `allowProfile`/`port`/`sessionToken`, whatever `data` is sent) | no |
| `HA_SCENE` and HA device types (`SWITCH`, `LIGHT*`, `AC`, `FAN`, `CURTAIN*`, `TEMPERATURE_SENSOR`, `HUMIDITY_SENSOR`) | ids from the 1002 tree under `sys.widget.iot` | `HA_SCENE`: yes |
| `AUDIO_PLAYER` | `{"source":…}`; id `sys.player.sonos|music|spotify` | no |
| `EMAIL_CARD` | configured through 1500–1502 | no |
| `SET`, `UNSUPPORTED` | placeholder cards | — |

Automations for 30500 are `{uuid, name, icon, enabled, type:"AUTO", triggers:[{type, desc, params}], actions:[…]}`.

**Asset upload (big screen).** `POST http://<corebar>:8080/upload/zip?subDir=<x>&isFull=<bool>` (multipart, field `file`, a `.zip` ≤ 50 MB). The device unzips into `getExternalFilesDir(null)/<subDir>/…` preserving the zip's folder structure, writes only `jpg|jpeg|png|webp|gif`, skips `__MACOSX`/`.DS_Store`, rejects path traversal, then emits `ReloadProfileEvent` so the current profile repaints (re-uploading the same filename refreshes the card without a 1108). Reply **CONFIRMED**: `{"state":200,"msg":"ok","data":<count of images written>}`, errors `{"state":-1,"msg":"…","data":null}`. Images are then referenced by the relative path `"<subDir>/<file>"` (absolute paths also work but are device-specific). `isFull=true` wipes the target directory first. Uploaded files do **not** appear in the on-device image picker, and the device never serves them back over HTTP (the only static mounts are `/tgz` → cacheDir and `/module` → filesDir/backup/module).

> **Hazard (CONFIRMED):** the vendor client POSTs `core_bar_assets.zip` with **no `subDir` and no `isFull`**; the server defaults are `subDir=""` and `isFull=true`, so a vendor "Deploy project" first runs `deleteDirFiles` on the **whole external-files directory** — every folder Deckhand uploaded (e.g. `deckhand/`) is deleted and the TIME covers that referenced them go blank. Conversely, **Deckhand must always pass a `subDir`** (`subDir=deckhand`, `isFull=false` for incremental adds; `isFull=true` only on its own subdir) and re-upload its assets whenever it (re)connects, since there is no probe to detect the wipe.

**Wallpaper.** No standalone message and no `albumId`: the only persistent "background" is the TIME widget's `icon`. Value resolution (`GlideExtend.loadSmartCore`): `http…` → network; `resId://…` → built-in drawable; a string not starting with `file://` or `/` → `getExternalFilesDir/<string>` if it exists; `file://` or `/…` → absolute path. So: upload a zip with `subDir=deckhand`, set the target profile's TIME-widget `icon` to `"deckhand/<file>.png"`, then `BATCH_SAVE_PROFILE` (1108) with the full profile array. There is no dimension check; the cover is a rounded square with a blurred copy filling the ≈ 540 × 240 card, so keep the image small rather than 1424 × 280.

**Screensaver.** `SET_COREBAR_CONFIG` (30741) `data` = `{type:"BASE_SET", value: ScreensaverConfig}` where `ScreensaverConfig = {featureEnabled, lockTime(TIME_30S…NEVER), packageName, uri, ver}`; `GET_COREBAR_CONFIG` (30740) `{type:"BASE_SET"}` reads it back (default `{featureEnabled:false, lockTime:"NEVER", ver:1}`). CONFIRMED: the launcher renders no screensaver itself — it launches a **separate screensaver APK** with an Android `VIEW` intent `screensaver://<host>/start?24h=0|1` (stop: `…/stop`), where host = `uri` if `ver < 2`, else `packageName`; idle time = `clamp(20, 100, lockTime.seconds/60*20)` s, and `NEVER` still arms the timer while `featureEnabled` is true (disable via `featureEnabled:false`). Installed screensavers are discovered with `GET_APP_LIST` (1000) and `data:"SCREENSAVER"` (or `"ALL"`) → `[{application, appName, versionCode, versionName, icon, systemApp, isScreensaver, isConfig, configBtnName, port, sessionToken, allowProfile}]`; copy `packageName`/`uri`/`ver` from there verbatim into BASE_SET. Whether any store screensaver reads user images from a folder `/upload/zip` can reach is unknown (that APK's storage is private), so a **custom slideshow is unlikely** without analysing such an APK. The vendor client has no code path for 30740/30741/30742 at all.

**Non-destructive preview.** `PREVIEW_SCREENSAVER` (30742) `data` = `{url, mediaType:"IMAGE"|"VIDEO"}` shows a full-screen image/video immediately — one-shot, changes no saved state. **Verified on hardware (2026-11-01): `url` MUST be an http(s) URL** — `FullScreenMediaDialog` fetches it with `HttpURLConnection(new URL(url))` (10 s timeouts) and silently dismisses on anything else (relative paths, `file://`). The handler never calls `reply`, so the device sends **no acknowledgement** for 30742. Files uploaded via `/upload/zip` are *not* served back by the device, so Deckhand serves the PNG itself from the Mac (`UltraBarKit/PreviewServer.swift`, ephemeral port) and passes `http://<mac-lan-ip>:<port>/<name>.png`. This is the safe way to validate upload + sizing/format. **Deckhand implements exactly this** (`uploadScreenZip` + `previewScreen`) and deliberately does NOT yet write profiles. **Verdict after the 2026-11-01 hardware test: 30742 is BROKEN on firmware 1.0.9.9.** The device does fetch the image (the Mac-hosted URL is requested within ~30 ms) but nothing is ever shown: `PreviewScreensaverMessage` constructs `FullScreenMediaDialog` with `AppContext.context` (the `Application`) and the dialog never sets an overlay window type (the knob dialogs in the same APK do), so `Dialog.show()` throws `BadTokenException` right after `onCreate` started the download; the exception is caught and printed. The vendor client never sends 30742 either. No client-side workaround exists; Deckhand no longer exposes it (the `PreviewServer` stays in the kit for future use).

## Device settings — confirmed scope

The :7431 channel is **not** a general system-settings API. Only the act codes registered in the launcher's `MessageFactory` are handled, and there is **no** act code for volume, brightness, Bluetooth, Wi-Fi connect, timezone/24h, locale, or wallpaper — those live only as on-device helpers driven by the launcher UI and the physical knob. Moving them into a desktop app would need new device-side firmware.

Controllable today:
- **Screensaver** — `GET {act:30740, data:{type:"BASE_SET"}}` → `ScreensaverConfig`; `SET {act:30741, data:{type:"BASE_SET", value:{featureEnabled, lockTime, uri, packageName, ver}}}`. `lockTime` is a `LockTime` enum serialized by name: `TIME_30S, TIME_1MIN, TIME_2MIN, TIME_3MIN, TIME_4MIN, TIME_5MIN, NEVER`.
- **Screensaver preview** — `{act:30742, data:{url, mediaType:"IMAGE"|"VIDEO"}}` — handled but broken on tested firmware (dialog never appears; see *Non-destructive preview*).
- **Gateway endpoints** — the launcher registers `{act:30741, data:{type:"GATEWAY_CONFIG", value:CoreBarConfiguration}}` for writes, but it fails with a `ClassCastException` on the tested firmware (see *Provisioning* above), so the app writes with `SET_GATEWAY_CONFIG` (30300), which takes the config as the raw body. The matching read, `GET_COREBAR_CONFIG` (30740) `{type:"GATEWAY_CONFIG"}`, returns `null` on the tested firmware; the app tries it first anyway and falls back to the live scan.
- **Reboot** — `{act:20100}`.
- **Wi-Fi scan/list only** — `{act:1633}` start / `{act:1634}` stop; results pushed as `{act:1635}` (`CUBE_SCAN_WIFI_LIST_RESULT`), each `{name, signal, frequency}`, open networks filtered. No connect path.
- **Screen on/off** — `{act:30201, data:{serialNo, deviceId, propertyId:4, value}}`, addressed to a real module endpoint (rejects `serialNo=="0000000000000000"`; the CoreBar's own local volume/brightness are not reachable this way).

`SET_COREBAR_CONFIG` (30741) `type` enum (`ReadWriteType`) has exactly three members: `BASE_SET` (ScreensaverConfig), `GATEWAY_CONFIG` (CoreBarConfiguration), `APP_LIST` (read-only). Reply envelope: `{act, code(200|-1), msg, data, id, timestamp}` — payloads come back in `data`.

## SenseCube sensors (read)

Read with `MODULE_PROPERTY_READ` (30200), `data = {serialNo, deviceId, propertyId}`; the value comes back raw in `data.result` (the app does the scaling — the device only scales on its internal push path, not on reads). The SenseCube's main device id is **0** (not 256); the sensors are sub-devices with their own ids (10 / 11 / 12 / …), and the app reads them with `deviceId` 11 / 12 / 10 (`CoreBarSession.readSenseCube`).

| deviceId | propId | sensor | unit (raw → value) | pollable |
|---|---|---|---|---|
| 10 | 1 | illuminance | lux (as-is) | yes |
| 11 | 1 | temperature | raw ÷ 10 = °C | yes |
| 12 | 1 | humidity | raw ÷ 10 = %RH | yes |
| 15 | 2 | shock-wake state | 0 / ≠0 | yes |
| 13 | 2 | presence (mmWave) | bool | event-only |
| 14 | 1 | ambient audio (SPL) | dB | event-only |
| 15 | 3 | shock/vibration | event id | event-only |
| any | 0 | min report interval | ms (write to configure) | config |

Example — temperature: `{"act":30200,"data":{"serialNo":"<SN>","deviceId":11,"propertyId":1}}` → `{"code":200,"data":{...,"result":235}}` = 23.5 °C. No battery property (mains/USB powered). Presence/audio/vibration are event-only and do **not** appear to be forwarded over :7431 (they drive on-device widgets / scene triggers); over the protocol the SenseCube is effectively poll-only for temp/humidity/light.

## CoreBar inputs (DotKey / KnobKey)

The launcher does **not** push raw key/knob events over :7431. Raw input is consumed on-device and bound, via the active Profile's module config, to on-device scenes/controllers. The client only receives **semantic, pre-mapped** messages, and only when a control is bound to a "PC" target:

- Inbound: `PUSH_MESSAGE` (1000000) arrives as `{"act":1000000,"id":"sys.push-<uuid>","data":{"type":<PushType>,"payload":P}}` on the open control connection. **It is a request the PC must REPLY to** (CONFIRMED): `{"act":1000000,"id":<same id>,"code":200,"data":{"type":<same type>,"payload":<value>}}`. The `type` is the enum **name** as a string. Types the vendor client handles: `TEST` (echo), `PC_CONTROL` (`payload = {action, params}` with `action ∈ openFile{path} | openBrowser{url} | startApp{path, launchMode} | inputText{text} | execCmd{cmd}`), `GET_VOLUME` / `SET_VOLUME`, `GET_MUTE` / `SET_MUTE`, `GET_BRIGHTNESS` / `SET_BRIGHTNESS` (payload int 0–100, reply with the resulting value), and the stat queries `CPU`, `MEMORY`, `STORAGE`, `NETWORK` (reply payload e.g. `{totalReceived, totalSent}` for NETWORK) that feed the on-device CPU/MEMORY/STORAGE/NETWORK cards. Because Deckhand opens one connection per operation, it must keep a long-lived connection open to receive and answer these.
- **KnobKey → Mac**: bind a rotation direction to a `PC_VOLUME` (or `PC_BRIGHT`) device from the 1617 tree in the profile's module config; the device then pushes `SET_VOLUME <int>` on each knob step and polls `GET_VOLUME` at start and every 5 s (reading the reply's `data.payload`). No subscribe needed — pushing starts once the binding exists. Binding keys written by the vendor client (CONFIRMED): module `config = {button:{click|doubleClick|longPress…}, knob:{turnLeft:{enabled, deviceName, deviceId, deviceType}, turnRight:{…}}}`; the firmware's own field names are `clockwise`/`counterclockwise` (LIKELY turnRight → clockwise).
- **DotKey → Mac**: per button `button1..3` → `{keyCode, singleClick|doubleClick|longPress:{enabled, show, name, icon, actions:[…]}}` where each action is `{type, name, objectParams, values:[{param, value}], deployData}` with types `PC_CONTROL`, `VIVO_CUBE_TOGGLE`, `PLUGIN_WIDGET`, `APP_CAPABILITY`. A press reaches the PC only through a `PC_CONTROL` action (pushed as above); **hot-keys never reach the PC over :7431** — `{type:"hotKey", objectParams:{output, keys:[<HID usage ids>], keysDesc}}` is executed by the CoreBar itself as USB-HID keystrokes (usage ids 4..115, modifiers 224..231, Power 102 / Sleep 103 / Wake 104). Single/double/long press is computed on-device.
- **SenseCube taps**: `{detail:[{mode:1..5, enabled, show, actions…}]}` ("Tap Rhythm"); **VivoCube buttons**: per widget `{uniqueId, widgetType, keyCode?, click events…}`.
- Bindings are **settable over the protocol** by writing the profile's `module[]` entries: `BATCH_SAVE_PROFILE` (1108) with `module:[{productId, serialNo, config}]`, then `TRIGGER_PROFILE_CHANGE` (1103). So the Mac app can bind a knob direction to PC_VOLUME, or a key to PC_CONTROL, by writing the profile — then keep a connection open, listen for `act:1000000` and reply.

## Scenes / automations (presence → action)

The device has an automation engine: a `Scene` = `triggers[]` + `conditions[]` + `actions[]`, `type` AUTO (trigger-driven) or MANUAL (button). Saved with `BATCH_CREATE_SCENE` (30500), `data` = an array of `Scene` — this **full-replaces** the scene list (no "get scenes" op, so the client must own the authoritative array, same pattern as profiles).

- **Presence trigger** (works): `{"type":"DEVICE_STATE","params":{"id":"<senseCubeId>","property":"state","from":"UNOCCUPIED","to":"OCCUPIED"}}`. Read helpers: `SCENE_DEPENDS_DEVICES` (30701, data `"SENSE_CUBE"` → id), 30702 (props), 30703 (values).
- **Actions** — the gap for "wake": `START_SCREEN`/`CLOSE_SCREEN` exist in the enum but have **no handler** (dead). Available display actions: `BRIGHT` (target `"corebar"`, sets screen brightness — doesn't dismiss the screensaver), `ACTIVITY` (launch an app — the best candidate to actually wake the panel), `VIVO_CUBE_TOGGLE` (change a VivoCube's shown layer), `CHANGE_PROFILE`. So **motion → wake** is approximate (ACTIVITY or BRIGHT) and must be verified on hardware; it is not a built-in behavior and there's no clean screen-power action.

## Not yet implemented in the app

The protocol for these is mapped above; what is missing is the client-side implementation (and, where noted, hardware confirmation).

- **CoreBar pages** via `BATCH_SAVE_PROFILE` (1108): implemented in Deckhand as "Publish Deckhand page" (standard page re-sent + a Deckhand page whose TIME card cover is our image; user-confirmed because 1108 replaces all pages; `SCENE_DEPENDS_PROFILE` 30710 lists ids first). **CONFIRMED on hardware 2026-11-01 22:39**: 1108 `data:"success"`, 1103 `data:"ok"`, 30710 lists both pages, and the CoreBar shows the Deckhand page with our 480×480 PNG as the clock card's cover (rounded square + blurred copy as card background). Relative icon path `deckhand/cover.png` after `/upload/zip?subDir=deckhand&isFull=false` works; `isDefault` key accepted; re-sending the standard page with an empty TIME `icon` kept the device's own clock image. The schema is now fully known (see *CoreBar big screen*): pages are card strips of vendor widgets, Deckhand's own image can only be the TIME card's cover, there is no wallpaper and no read-back beyond the 30710 id list. What remains is the client policy: own an authoritative `profiles.json`, compare 30710 ids before every 1108, always include the device's existing default profile (id `"default"`, TIME `icon` empty so the on-device choice is kept), upload assets under `subDir=deckhand`, and warn that a vendor "Deploy project" wipes those assets and replaces the profile set. Hardware checklist: `isDefault` accepted, TIME `icon:"deckhand/…"` renders, `module:[]` on the default profile does not disturb module bindings (HYPOTHESIS), 1103 exits the screensaver.
- **KnobKey → volume and DotKey → Mac actions.** The inbound path is understood (`PUSH_MESSAGE` 1000000 request → PC reply, see *CoreBar inputs*), but it only flows once a control is bound to a PC target in the profile — which needs the 1108 write path — and it needs a **persistent connection with a reply loop** (the vendor keeps one open with a 3 s heartbeat); Deckhand's one-connection-per-operation model does not yet have that.
- **Presence → wake** via an on-device scene (`BATCH_CREATE_SCENE` 30500): trigger understood, no clean screen-on action; must be verified on hardware.
- **OTA module flashing** (`MODULE_OAT_START` 30400 / `MODULE_OAT_DATA` 30401): fully specified above (file header, MD5 rule, pack framing); not implemented.
- **VivoCube panel resolution**: **240 × 240, CONFIRMED on hardware 2026-11-01** (a 240 px test pattern fills the panel; 280 px is not displayed). The large-looking border is the bezel.
- **VivoCube `dataConfig`** in the 30300 endpoint (so the CoreBar dispatches button presses for Deckhand's widget ids) and **module Wi-Fi config** (property 7 hex layout) — not implemented.
- Smart-home bridging (`DeviceEnum` LIGHT / SWITCH / …), app/plugin stores and the cloud backend `gatewayssl.dev.aiks360.com` (`/api/v1/base-service/pub/icon/tags/locales/allGrouped`, `…/pub/icon/v2/page`, `…/pub/apps/100/fetchListV2`, `…/pub/apps/100/<id>/fetchLastVerV3`, `…/pub/plugin/page`; the launcher's cleartext backup goes to `gateway.dev.aiks360.com`) — out of scope for now; see `docs/SECURITY.md`.

## Device-first contracts used by Deckhand (summary; details in docs/research/device-first-findings.md)

- Persistent connection: TLS :7431, heartbeat `{"act":20,"id":"<n>"}` every 3 s (reply `code:200,data:"success"`); the hub closes a connection after 60 s with neither read nor write. `PUSH_MESSAGE` (1000000) is broadcast to every connected client; the PC replies `{"act":1000000,"id":<same>,"code":200,"data":{"type":T,"payload":P}}` within 5 s; first `code:200` by id wins. (CONFIRMED)
- Metric cards: device sends `{"type":"CPU"|"MEMORY"|"STORAGE"|"NETWORK"}` at 3/8/10/5 s while the card is visible; reply payload = integer percent 0–100, NETWORK = `{"totalReceived":<bytes>,"totalSent":<bytes>}` cumulative (device derives KB/s). Widget `param` is `{"data":""}` (unread). (CONFIRMED)
- Volume: KnobKey bound to `PC_VOLUME` → `GET_VOLUME` every 5 s (reply int 0–100) and `SET_VOLUME <int>` per tick. No mute push types exist. Brightness analogous (`PC_BRIGHT`); the vendor's Mac client stubs it. (CONFIRMED)
- Module bindings live in the profile's `module[]`: KNOB_KEY `config = {button:{keyCode:0,…}, clockwise:{id,type}, counterclockwise:{id,type}}`; DOT_KEY `config = [{keyCode, singleClick|doubleClick|longPress:{show,name,icon,actions:[ActionConfig]}}]` with keyCodes button1=2, button2=1, button3=0; `ActionConfig = {type, id, name, values:[{id,value}]}`; `VIVO_CUBE_TOGGLE` id = VivoCube uid, values "1"=layer, "2"=widget (strings); `PC_CONTROL` value "1" = `{"output":10,"payload":…}` (push to PC) or `{"output":5,"keys":[HID usages]}`; `CHANGE_PROFILE` value "1" = profile id. (CONFIRMED)
- `WORLD_TIME` `param.offset` = `"GMT+1:00"` style (no IANA zones; DST changes need a redeploy). `PC_CONTROL` big-screen card: `{"type":"PC_CONTROL","icon":"deckhand/x.png","iconScale":80,"param":{"output":10,"payload":{…}}}`; TAP pushes the payload to all clients. (CONFIRMED)
- Automations: triggers are DEVICE_STATE / PROFILE / APP_STATE only — **no time or interval trigger exists**, so scheduled rotation must come from the PC. (CONFIRMED absent)
- Vendor plugin packs: zip with `config.json` `{identifier,name,icon,homepage,versionName,versionCode,author,description,button:[{id,name,icon:"file://…",type:"PC_CONTROL",spanSize:1|2,param:{output:5,keys:[…]}|{output:10,payload:{action,params}}}]}` → importable as a HOT_KEY_GROUP card. (CONFIRMED; docs/research/vendor-plugins-findings.md)
- Clock: the launcher's time setter writes date+time with `SystemClock.setCurrentTimeMillis` without checking the result and its year wheel never pre-selects the current year; on the tested unit the date cannot be changed from the UI and no protocol act sets time. (CONFIRMED on hardware 2026-11-01)
- **Built-in WEATHER card (CONFIRMED on hardware 2026-11-02):** the launcher's `WeatherManager` ships with the placeholder AccuWeather key `YOUR_REAL_API_KEY`, so the card shows "--" until a real key is stored with `INTEGRATED_CONFIG_SET` (1010) `{"packageName":"com.ultrabar.weather","config":{"apiKey":"<key>","metric":true}}` (virtual package; `valid()` only requires a non-empty key; language follows the device). Deckhand sends this on every page publish when a key is set in Overview → CoreBar pages.
- **Metric pushes only while visible (CONFIRMED on hardware 2026-11-02):** CPU/MEMORY/NETWORK/STORAGE queries are sent only while a page containing those cards is on screen (holders subscribe on bind); they resume when the page is shown again. A second authenticated connection, a `/upload/zip`, and replying vs. not replying do not disturb the cadence (`kitcheck linkwatch`).
- **VivoCube Wi-Fi (property 7, CONFIRMED on hardware 2026-11-02):** `MODULE_PROPERTY_READ {serialNo:<cube>, deviceId:256, propertyId:7}` returns `result` = hex of `[len][ssid][len][password]`; a factory cube is joined to the CoreBar's own hotspot (`AndroidAP_xxxx`). `MODULE_PROPERTY_WRITE` with the same hex joins the cube to another 2.4 GHz network; it reconnects by itself (~20 s). Why it matters: `/upload?serialNo=` hands the module a download URL on the CoreBar's hotspot interface (`wlan1`) when the cube is on that hotspot, and on the CoreBar's Wi-Fi/LAN address otherwise; Android switches an idle hotspot off and nothing in the launcher restarts it, hence `"hotspotIp ip address is empty"` until a CoreBar reboot. Property 6 = Wi-Fi state, see the next-but-one bullet (1 = connected).
- **Module `uid` in the gateway config matters (CONFIRMED from `ModuleConfigLoad.getSerialToUid`):** the launcher resolves every profile `module[]` binding, the SENSE_CUBE card topics and `VIVO_CUBE_TOGGLE` targets by the endpoint's `uid` from the CoreBar configuration (30300); an endpoint without `uid` maps to the literal `"empty"`. Discovery pushes (30102) carry no `uid`, so Deckhand's provisioning now writes `uid = serialNumber` (and a product-type `name`) for every endpoint — the same values the vendor client sends. **Existing devices need one "Refresh / set up" to get the uid written** before DotKey → VivoCube switching and SenseCube cards work.
- **SenseCube cards (CONFIRMED from source):** `SENSE_CUBE_TEMP/HUM/ALS/RADAR/AUDIO` widgets take `param.uid` = the module uid and subscribe to that DataBus topic; values are published by the profile's `SenseCubeModule` (property 1 = temperature °C float, 12 = humidity, 10 = lux, 15 = presence, 5 = shock), which only exists when the profile's `module[]` contains a `{productId:"SENSE_CUBE", serialNo, config:[]}` entry (details optional; the launcher assigns random ids on save). Deckhand adds that entry and keys the cards by uid. Hardware confirmation pending.
- **VivoCube Wi-Fi state (property 6) — CONFIRMED on hardware 2026-11-03:** `0` not configured, `1` **connected**, `2` not connected, `3` **connecting** (the vendor client's `readWifiState` strings). A cube that reports `3` answers every `/upload` with `reply error:4` ("not connected to the network"); a package was only ever applied ("updating config" on the cube, new cards visible) while it reported `1`. A cube can sit at `3` for hours with a correct password; writing its current property-7 config again (same ssid/password) made it report `1` within 7 s. Earlier notes that read `3` as "connected" were wrong.
