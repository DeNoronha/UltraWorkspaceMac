# CoreBar local protocol (as implemented here)

Recovered from the decompiled "VivoCube Weather Tool" (.NET), cross-checked against the official UltraWorkSpace macOS binary, and the LineOS APK. Everything below is the **local** PC↔CoreBar protocol; the CoreBar relays to its attached QuantumLink modules (VivoCube, SenseCube, KnobKey, DotKey, PC-Boot card).

## Transports (device bridges)

The campaign describes four "protocol bridges" on the CoreBar: **USB/HID**, **IP Network**, **Bluetooth Mesh**, and **QuantumLink** (the magnetic module bus). Everything documented below is the **IP Network** bridge — the one this app uses. The USB/HID bridge (USB-C, no drivers; USB identity `VID_1F3A&PID_2000` with a serial/PC-LINK channel) is unmapped here but is the likely route for driverless keystroke macros and PC-stat feeds; Bluetooth Mesh covers wireless management and one-tap PC wake. Note that ADB (port 5555) is closed on the CoreBar.

## Transport (IP Network)

- **Discovery**: UDP broadcast on port **5319**. Probe payload `{"act":"discover"}` sent to `255.255.255.255:5319` every ~2 s. A CoreBar replies with a JSON object containing at least `tcpPort`, plus `serialNo`, `ver`, `ip`, `name`.
- **Control**: TLS (1.2/1.3) over TCP, default port **7431**, SNI `ultrabar.local`. The CoreBar uses a self-signed cert → trust-on-first-use: pin the SHA-256 of the presented leaf certificate at pairing, and on later connections abort *before* sending the token if it no longer matches. Messages are UTF-8 JSON objects, one per line (`\n`-delimited).
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
| 30200  | read property      | `{serialNo, deviceId:256, propertyId, extra:null}`         | `data.result` (integer) |
| 30201  | write property     | `{serialNo, deviceId:256, propertyId, value}`              | `code` |
| 1300   | GET_DEVICE — logical/integration device list | `{}`                             | `data` = array of `{id, name, deviceType, online, …}` (empty on this firmware for physical modules) |

### Enumerating modules is a live scan, not a config read

On the firmware tested here the static config reads come back **empty**: `GET_DEVICE` (1300), `QUERY_MODULE_STATE` (30730), and `GET_COREBAR_CONFIG` (30740) return nothing useful for the physical QuantumLink modules. (An earlier version of this client listed modules with 30730 and always got an empty array back.)

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

- The older `SET_COREBAR_CONFIG` (30741) is **not** used: it wraps the configuration in a `ReadWriteRequest` and the device throws a `ClassCastException`.
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

`deviceId` for the main device inside a module is **256**.

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

## Not yet mapped

- The CoreBar's **own big screen** (wallpaper / screensaver). This appears profile-bound — likely `BATCH_SAVE_PROFILE` (1108), with `PREVIEW_SCREENSAVER` (30742) as a preview — rather than a direct image push.
- **Inbound button / rotation events** for KnobKey and DotKey (needed to bind KnobKey → volume and DotKey presses to Mac actions). The official app encodes these as integer `act` codes, best recovered from the LineOS APK.
- Additional `act` codes for widgets, automations, OTA (`MODULE_OAT_*`), and smart-home bridging.
- Cloud backend `aiks360.com` (`/api/v1/base-service/pub/...`) for the app marketplace and icon/plugin catalog.
