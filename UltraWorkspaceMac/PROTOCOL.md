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
| 101    | pair               | `{id, clientType:"pc", name}`                              | `data.token` once the user taps Approve on the device |
| 100    | authenticate       | `"<token>"`                                                | `code == 200` on success |
| 30730  | list modules       | `{}`                                                       | `data` = array of `{serialNo, …}` |
| 30200  | read property      | `{serialNo, deviceId:256, propertyId, extra:null}`         | `data.result` (integer) |
| 30201  | write property     | `{serialNo, deviceId:256, propertyId, value}`              | `code` |

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
