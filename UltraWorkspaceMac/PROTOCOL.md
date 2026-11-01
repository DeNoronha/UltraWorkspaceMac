# CoreBar local protocol (as implemented here)

Recovered from the decompiled "VivoCube Weather Tool" (.NET) and cross-checked
against the official UltraWorkSpace macOS binary. Everything below is the
**local** PC↔CoreBar protocol; the CoreBar relays to its attached modules.

## Transports (device bridges)

The campaign describes four "protocol bridges" on the CoreBar: **USB/HID**, **IP Network**, **Bluetooth Mesh**, and **QuantumLink** (the magnetic module bus). Everything documented below is the **IP Network** bridge — the one this app uses. The USB/HID bridge (USB-C, no drivers; USB identity `VID_1F3A&PID_2000` with a serial/PC-LINK channel) is unmapped here but is the likely route for driverless keystroke macros and PC-stat feeds; Bluetooth Mesh covers wireless management and one-tap PC wake.

## Transport (IP Network)

- **Discovery**: UDP broadcast on port **5319**. Probe payload `{"act":"discover"}`
  sent to `255.255.255.255:5319` every ~2 s. A CoreBar replies with a JSON object
  containing at least `tcpPort`, plus `serialNo`, `ver`, `ip`, `name`.
- **Control**: TLS (1.2/1.3) over TCP, default port **7431**, SNI `ultrabar.local`.
  The CoreBar uses a self-signed cert → trust-on-first-use, pin the SHA-256 at
  pairing. Messages are UTF-8 JSON objects, one per line (`\n`-delimited).
- **Upload**: HTTP on port **8080**, `POST /upload?serialNo=<serial>`,
  `multipart/form-data`, field `file`, filename `<serial>.tgz`,
  `Content-Type: application/gzip`. Success body contains `"state":200` and `"msg":"ok"`.

## Control messages

Every request is `{"act":<int>,"id":"<hex>","data":<value>}`; replies echo `id`
and usually carry `code` (200 = ok) and `data`.

| act    | meaning            | data (request)                                             | reply |
|--------|--------------------|------------------------------------------------------------|-------|
| 101    | pair (REQ_AUTH_TOKEN) | `{id, clientType:"pc", name}`                           | `data.token` once the user taps Approve on the device |
| 100    | authenticate (AUTH)   | `"<token>"`                                             | `code == 200` on success |
| 1300   | **GET_DEVICE** — list all devices/modules | `{}`                              | `data` = array of `{id, name, deviceType, online, supportedFeatures, attr}` |
| 30200  | read property      | `{serialNo, deviceId:256, propertyId, extra:null}`         | `data.result` (integer) |
| 30201  | write property     | `{serialNo, deviceId:256, propertyId, value}`              | `code` |
| 30730  | query module STATE (not a list) | `{serialNo, …}`                              | state (returns `data:[]` when used without a target) |

> **Note:** the enumeration query is **`GET_DEVICE` (1300)**, not 30730. 30730 is `QUERY_MODULE_STATE`. An earlier version of this client used 30730 to list modules and got an empty array back.

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
- Pixels row-major; each RGB565 value written **big-endian** (high byte first):
  `((R>>3)<<11) | ((G>>2)<<5) | (B>>3)`, then the alpha byte if `hasAlpha`.

## Layer package (`tgz`)

A gzip-compressed **ustar** tar containing, per layer:

- `com_res<widgetId>/default.bin` — the encoded default image.
- `com_res<widgetId>/pressed.bin` — the encoded pressed image (reference client
  renders this at 0.8× the default size).
- `config.json` = `{"defaultLayer":<D>,"layers":[{"id":<L>,"items":[{"id":<W>,"type":1}]}, …]}`.

The reference single-layer deploy uses `widgetId 101`, `layerId 1`, `defaultLayer 1`.
(The reference client also has an `EmulateVendorChecksumBug` flag that truncates the
tar header checksum to 5 octal digits — off by default; exposed here as a parameter.)

## Not yet mapped

- Additional `act` codes used by the official app for widgets, automations,
  KnobKey/DotKey binding, OTA, and smart-home bridging. The official app encodes
  these as integers (not string literals), so they're best recovered from the
  LineOS APK (the device-side server) when those features are built out.
- Cloud backend `aiks360.com` (`/api/v1/base-service/pub/...`) for the app
  marketplace and icon/plugin catalog.
