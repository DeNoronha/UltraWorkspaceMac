# CoreBar local protocol (as implemented here)

Recovered from the decompiled "VivoCube Weather Tool" (.NET), cross-checked against the official UltraWorkSpace macOS binary, and the LineOS APK. Everything below is the **local** PC↔CoreBar protocol; the CoreBar relays to its attached QuantumLink modules (VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card).

## Transports (device bridges)

The campaign describes four "protocol bridges" on the CoreBar: **USB/HID**, **IP Network**, **Bluetooth Mesh**, and **QuantumLink** (the magnetic module bus). Everything documented below is the **IP Network** bridge — the one this app uses. The USB/HID bridge (USB-C, no drivers; USB identity `VID_1F3A&PID_2000` with a serial/PC-LINK channel) is unmapped here but is the likely route for driverless keystroke macros and PC-stat feeds; Bluetooth Mesh covers wireless management and one-tap PC wake. Note that ADB (port 5555) is closed on the CoreBar.

## Transport (IP Network)

- **Discovery**: UDP broadcast on port **5319**. Probe payload `{"act":"discover"}` sent to `255.255.255.255:5319` every ~2 s. A CoreBar replies with a JSON object containing at least `tcpPort`, plus `serialNo`, `ver`, `ip`, `name`.
- **Control**: TLS over TCP, default port **7431**, SNI `ultrabar.local`. The device negotiates TLS 1.3; the client allows ≥ 1.2 (`sec_protocol_options_set_min_tls_protocol_version(.TLSv12)`). The CoreBar uses a self-signed cert → trust-on-first-use: pin the SHA-256 of the presented leaf certificate at pairing, and on later connections abort *before* sending the token if it no longer matches. Messages are UTF-8 JSON objects, one per line (`\n`-delimited).
- **Upload**: HTTP on port **8080**, `POST /upload?serialNo=<serial>`, `multipart/form-data`, field `file`, filename `<serial>.tgz`, `Content-Type: application/gzip`. Success body contains `"state":200` and `"msg":"ok"`.

## Control messages

Every request is `{"act":<int>,"id":"<hex>","data":<value>}`; replies echo `id` and usually carry `code` (200 = ok) and `data`.

| act    | meaning            | data (request)                                             | reply |
|--------|--------------------|------------------------------------------------------------|-------|
| 101    | pair (REQ_AUTH_TOKEN) | `{id, clientType:"pc", name}`                           | `data.token`, once the user taps **Approve** on the CoreBar |
| 100    | authenticate (AUTH)   | `"<token>"`                                             | `code == 200` on success |
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

The complete QuantumLink module protocol (how the CoreBar talks to each module over the magnetic bus / CAN / Mesh) lives in the `quantum.link` package of the LineOS/CoreBridge APKs: `QLinkVivoCube`, `QLinkSenseCube`, `QLinkKnobKey`, `QLinkDotKey`, `QLinkPCBootCard`, VivoCube widgets (`VCWidget*`), sensors, and `HidKeyboardOut` (USB-HID keystroke output for button macros). This is the reference for building out widget, sensor, KnobKey/DotKey, and OTA support.

`deviceId` for the main device inside a VivoCube is **256** (`Proto.deviceMain`). The SenseCube is different: its main device id is **0** (not 256), and its sensors are addressed as sub-devices **10 / 11 / 12 / …** (see *SenseCube sensors* below).

### Known property IDs (VivoCube main device)

| id | name        | notes                          |
|----|-------------|--------------------------------|
| 3  | runTime     | uptime seconds (read)          |
| 4  | screen      | 0 = off, 1 = on (write)        |
| 5  | reboot      | write `true`                   |
| 6  | wifi        |                                |
| 9  | layerWidget |                                |

## Module image format

8-byte header + pixels.

- Scan for any pixel with alpha ≠ 255 → `hasAlpha`.
- Bytes/pixel: 2 (RGB565) if opaque, 3 (RGB565 + 1 alpha byte) if `hasAlpha`.
- `word` (uint32 LE at offset 0) = `(((width & 0x7FF) | (height << 11)) << 10) | (hasAlpha ? 5 : 4)`.
- uint32 LE at offset 4 = payload byte count = `width*height*bpp`.
- Pixels row-major; each RGB565 value written **big-endian** (high byte first): `((R>>3)<<11) | ((G>>2)<<5) | (B>>3)`, then the alpha byte if `hasAlpha`.

VivoCube cards are rendered at 240 × 240 on the Mac before encoding.

## Layer package (`tgz`)

A gzip-compressed **ustar** tar containing, per layer:

- `com_res<widgetId>/default.bin` — the encoded default image.
- `com_res<widgetId>/pressed.bin` — the encoded pressed image (reference client renders this at 0.8× the default size).
- `config.json` = `{"defaultLayer":<D>,"layers":[{"id":<L>,"items":[{"id":<W>,"type":1}]}, …]}`.

The reference single-layer deploy uses `widgetId 101`, `layerId 1`, `defaultLayer 1`. (The reference client also has an `EmulateVendorChecksumBug` flag that truncates the tar header checksum to 5 octal digits — off by default; exposed here as a parameter.)

The package is POSTed to `http://<corebar>:8080/upload?serialNo=<serial>` (multipart, field `file`, `application/gzip`); a successful push returns `{"state":200,"msg":"ok"}`.

## CoreBar big screen (1424×280)

The CoreBar runs LineOS (`com.ultrabar.launch`); the screen protocol lives there (the bridge APK is just a relay). Unlike modules, the big screen takes **ordinary image files** (jpg/jpeg/png/webp/gif) at 1424×280 — no RGB565/tar.

**Pages / scenes (Stream-Deck-like).** `AppData` holds a `List<Profile>`. A `Profile` is a page: `{id, name, icon, bgColor, isDefault, showName, albumId, module[], homeData[], player}`, where `homeData[]` is the ordered widget strip (order = on-screen order; no x/y).
- `TRIGGER_PROFILE_CHANGE` (1103): `data` = profile id string — switch the active page.
- `BATCH_SAVE_PROFILE` (1108): `data` = array of `ProfileDTO` — **replaces the whole page list** (read-modify-write; there's no "list profiles" op over 7431, so the PC client owns the authoritative copy). Destructive if sent partial.
- `GET_PROFILE_WIDGET` (1002): returns the tree of placeable widgets.

**Asset upload (big screen).** `POST http://<corebar>:8080/upload/zip?subDir=<x>&isFull=<bool>` (multipart, field `file`, a `.zip` ≤50 MB). The device unzips into its external files dir under `<subDir>`; images are then referenced by the relative path `"<subDir>/<file>"`. `isFull=true` wipes the subdir first. (The module route `POST :8080/upload?serialNo=` is separate; the big screen has no serialNo — it's the host device, mutated over 7431.)

**Wallpaper.** No standalone message: the background behind the clock is the TIME widget's `icon` field (and/or `Profile.albumId`). Value resolution (`GlideExtend.loadSmartCore`): `http…` → direct; `resId://…` → built-in drawable; a relative string → `getExternalFilesDir/<string>`; `file://` or `/…` → absolute. So: upload a zip, set the target profile's TIME-widget `icon` to `"<subDir>/<file>.png"`, then `BATCH_SAVE_PROFILE` (1108) with the full profile array.

**Screensaver.** `SET_COREBAR_CONFIG` (30741) `data` = `{type:"BASE_SET", value: ScreensaverConfig}` where `ScreensaverConfig = {featureEnabled, lockTime(TIME_30S…NEVER), packageName, uri, ver}`; a separate screensaver app renders/rotates. `GET_COREBAR_CONFIG` (30740) `{type:"BASE_SET"}` reads it back.

**Non-destructive preview.** `PREVIEW_SCREENSAVER` (30742) `data` = `{url, mediaType:"IMAGE"|"VIDEO"}` shows a full-screen image/video immediately — one-shot, changes no saved state. **Verified on hardware (2026-11-01): `url` MUST be an http(s) URL** — `FullScreenMediaDialog` fetches it with `HttpURLConnection(new URL(url))` (10 s timeouts) and silently dismisses on anything else (relative paths, `file://`). The handler never calls `reply`, so the device sends **no acknowledgement** for 30742. Files uploaded via `/upload/zip` are *not* served back by the device (only `/tgz` → cacheDir and `/module` → filesDir/backup/module are static mounts), so Deckhand serves the PNG itself from the Mac (`PreviewServer`, ephemeral port) and passes `http://<mac-lan-ip>:<port>/<name>.png`. This is the safe way to validate upload + sizing/format. **Deckhand implements exactly this** (`uploadScreenZip` + `previewScreen`) and deliberately does NOT yet write profiles.

## Device settings — confirmed scope

The :7431 channel is **not** a general system-settings API. Only the act codes registered in the launcher's `MessageFactory` are handled, and there is **no** act code for volume, brightness, Bluetooth, Wi-Fi connect, timezone/24h, locale, or wallpaper — those live only as on-device helpers driven by the launcher UI and the physical knob. Moving them into a desktop app would need new device-side firmware.

Controllable today:
- **Screensaver** — `GET {act:30740, data:{type:"BASE_SET"}}` → `ScreensaverConfig`; `SET {act:30741, data:{type:"BASE_SET", value:{featureEnabled, lockTime, uri, packageName, ver}}}`. `lockTime` is a `LockTime` enum serialized by name: `TIME_30S, TIME_1MIN, TIME_2MIN, TIME_3MIN, TIME_4MIN, TIME_5MIN, NEVER`.
- **Screensaver preview** — `{act:30742, data:{url, mediaType:"IMAGE"|"VIDEO"}}` (one-shot; http(s) `url` only; no ack).
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

- Outbound push: `PUSH_MESSAGE` (1000000), `data = {type: <PushType>, payload}`. PushType includes `SET_VOLUME`, `SET_BRIGHTNESS`, `GET_VOLUME`, `GET_BRIGHTNESS`, `PC_CONTROL`, and `CPU/MEMORY/STORAGE/NETWORK` (the device asking the PC for stats to display).
- **KnobKey → Mac**: bind a rotation direction to `PC_VOLUME` (or `PC_BRIGHT`) in the profile; the device then pushes `{act:1000000, data:{type:"SET_VOLUME", payload:<0..100>}}` on each tick (and polls `GET_VOLUME` every 5 s). No subscribe needed — pushing starts once the binding exists.
- **DotKey → Mac**: a key press only reaches the PC if its bound scene uses a `PC_CONTROL` action (pushes `{type:"PC_CONTROL", payload}`) or an HID-keycode action (sent over a separate keyboard channel). The 3 keys report per-key 16-bit keyCodes + up/down/hold; single/double/long is computed on-device.
- Bindings are **settable over the protocol** by writing the Profile: `BATCH_SAVE_PROFILE` (1108), `GET_PROFILE_WIDGET` (1002), `TRIGGER_PROFILE_CHANGE` (1103). So the Mac app can bind a knob direction to PC_VOLUME, or a key to PC_CONTROL, by writing the profile — then listen for `act:1000000`.

## Scenes / automations (presence → action)

The device has an automation engine: a `Scene` = `triggers[]` + `conditions[]` + `actions[]`, `type` AUTO (trigger-driven) or MANUAL (button). Saved with `BATCH_CREATE_SCENE` (30500), `data` = an array of `Scene` — this **full-replaces** the scene list (no "get scenes" op, so the client must own the authoritative array, same pattern as profiles).

- **Presence trigger** (works): `{"type":"DEVICE_STATE","params":{"id":"<senseCubeId>","property":"state","from":"UNOCCUPIED","to":"OCCUPIED"}}`. Read helpers: `SCENE_DEPENDS_DEVICES` (30701, data `"SENSE_CUBE"` → id), 30702 (props), 30703 (values).
- **Actions** — the gap for "wake": `START_SCREEN`/`CLOSE_SCREEN` exist in the enum but have **no handler** (dead). Available display actions: `BRIGHT` (target `"corebar"`, sets screen brightness — doesn't dismiss the screensaver), `ACTIVITY` (launch an app — the best candidate to actually wake the panel), `VIVO_CUBE_TOGGLE` (change a VivoCube's shown layer), `CHANGE_PROFILE`. So **motion → wake** is approximate (ACTIVITY or BRIGHT) and must be verified on hardware; it is not a built-in behavior and there's no clean screen-power action.

## Not yet implemented in the app

The protocol for these is mapped above; what is missing is the client-side implementation (and, where noted, hardware confirmation).

- **Persistent CoreBar wallpaper / pages** via `BATCH_SAVE_PROFILE` (1108). Deckhand only does the one-shot `PREVIEW_SCREENSAVER` (30742) today. Writing profiles needs the full authoritative profile array (destructive if sent partial) and still has open questions: does `albumId` alone repaint, or must the TIME-widget `icon` be set; the exact `/upload/zip` success JSON; the screensaver app's `packageName` / `ver`.
- **KnobKey → volume and DotKey → Mac actions.** The inbound path is understood (`PUSH_MESSAGE` 1000000 with `SET_VOLUME` / `PC_CONTROL`, see *CoreBar inputs*), but it only flows once a control is bound to a PC target in the profile — which again needs the `BATCH_SAVE_PROFILE` write path. The app does not yet listen for act 1000000.
- **Presence → wake** via an on-device scene (`BATCH_CREATE_SCENE` 30500): trigger understood, no clean screen-on action; must be verified on hardware.
- **OTA module flashing** (`MODULE_OAT_START` 30400 / `MODULE_OAT_DATA` 30401): act codes known, payload framing not worked out.
- Smart-home bridging (`DeviceEnum` LIGHT / SWITCH / …) and the cloud backend `aiks360.com` (`/api/v1/base-service/pub/...`) for the app marketplace and icon/plugin catalog — out of scope for now.
