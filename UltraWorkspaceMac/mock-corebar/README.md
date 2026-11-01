# Mock CoreBar

A Node.js + TypeScript **emulator of the UltraBar X "CoreBar" device**, so you can test a client (the macOS app **Deckhand**) without the real hardware. It speaks the device's local protocol (UDP discovery, TLS control, HTTP upload) and ships a browser viewer that renders the widget images the client uploads.

The protocol is based strictly on this repo's `PROTOCOL.md`, `api/asyncapi.yaml`, `api/openapi.yaml`, and the Swift sources in `Sources/UltraBarKit/` (`DeviceImage.swift`, `DeployPackager.swift`, `Discovery.swift`, `CoreBarClient.swift`). It is a test double, not a reimplementation of LineOS.

## Ports

| Port | Proto | Purpose |
|------|-------|---------|
| 5319 | UDP | Discovery. Replies to `{"act":"discover"}` with a CoreBar descriptor. |
| 7431 | TCP/TLS | Control socket. Line-delimited JSON frames `{act,data,id}`, SNI `ultrabar.local`, self-signed cert (trust-on-first-use). |
| 8080 | HTTP | Uploads. `POST /upload?serialNo=` (module `.tgz`) and `POST /upload/zip` (big-screen image `.zip`). |
| 8081 | HTTP | Web viewer (mock-only; not a real device port). Open <http://127.0.0.1:8081>. |

## Run natively (recommended — supports broadcast discovery)

```sh
cd mock-corebar
npm install
npm run dev          # ts-node, no build step
# or: npm run build && npm start
```

Then open <http://127.0.0.1:8081>. Run on the same host/LAN as the client and its broadcast discovery (`{"act":"discover"}` to `255.255.255.255:5319`) will find the mock directly, because the mock replies to the datagram's sender.

## Run via Docker

```sh
cd mock-corebar
docker compose up --build
```

> **IMPORTANT — UDP broadcast discovery does not cross Docker Desktop's NAT on macOS.** A container cannot receive the client's `255.255.255.255` broadcast, so auto-discovery will **not** find the mock when it runs in Docker on macOS. Workaround: the ports are published to the host, so use Deckhand's **"Add CoreBar by IP"** (unicast) feature and point it at `127.0.0.1`. The compose file sets `MOCK_IP=127.0.0.1` so the discovery descriptor advertises a host the client can connect back to. (Unicast discovery to `127.0.0.1:5319` also works through the published UDP port; only the `255.255.255.255` broadcast is dropped.)

Running natively (`npm run dev`) has no such limitation and supports broadcast discovery.

## Endpoints and acts implemented

**UDP :5319** — replies to `{"act":"discover"}` (broadcast or unicast) with `{serialNo, ver, ip, name, tcpPort}` (the exact shape `Discovery.swift` parses; note the field is `ver`, and `tcpPort` must be present).

**TLS :7431** control acts:

- `AUTH` (100) — accepts any token (and the one issued at pairing).
- `REQ_AUTH_TOKEN` (101) — auto-"approves" after ~1s, logs an `Approve tapped` line, returns `data.token`.
- `GET_DEVICE` (1300) — a small logical device list.
- `GET_APP_LIST` (1000) — a small app list.
- `MODULE_START_DISCOVERY` (30100) with data `"can"`/`"mesh"` — pushes `MODULE_START_DISCOVERY_REPLAY` (30102) frames, one per seeded module on that bus (VivoCube, SenseCube, KnobKey on `can`; DotKey on `mesh`, offline). Uses the `QLinkProductId` ints from `PROTOCOL.md`.
- `MODULE_STOP_DISCOVERY` (30101) — ok.
- `SET_GATEWAY_CONFIG` (30300) — stores the `CoreBarConfiguration`, ok.
- `MODULE_PROPERTY_READ` (30200) — SenseCube `deviceId 10/11/12 propId 1` return raw lux `473`, temp `235` (=23.5 °C), hum `540` (=54.0 %RH); other reads (e.g. screen propId 4) return a plausible value.
- `MODULE_PROPERTY_WRITE` (30201) — ok (result stripped).
- `QUERY_MODULE_STATE` (30730) — empty (mirrors tested firmware).
- `GET_COREBAR_CONFIG` (30740) / `SET_COREBAR_CONFIG` (30741) — `BASE_SET` echoes/stores the `ScreensaverConfig`; `GATEWAY_CONFIG` stored; `APP_LIST` read-only.
- `PREVIEW_SCREENSAVER` (30742) — records `{url, mediaType}` and surfaces it in the viewer.
- `SYS_REBOOT` (20100) — ok.
- `START_SCAN_WIFI` (1633) / `STOP_SCAN_WIFI` (1634) — pushes `CUBE_SCAN_WIFI_LIST_RESULT` (1635) with a couple of fake networks.
- `BATCH_SAVE_PROFILE` (1108) / `BATCH_CREATE_SCENE` (30500) / `TRIGGER_PROFILE_CHANGE` (1103) — store + ok.
- **Unknown acts** — reply `code:200` with empty data and log them, so new client calls don't break testing.

Every inbound/outbound frame is logged to stdout and to the viewer's live frame log.

**HTTP :8080**:

- `POST /upload?serialNo=` (multipart field `file`) — the module `.tgz`. The mock **decodes** it back to a PNG: gunzip → untar → find `com_res<widgetId>/default.bin` → parse the 8-byte header + RGB565(+alpha) → RGBA → PNG (via `pngjs`). Stores the latest image per `serialNo`. Returns `{"state":200,"msg":"ok"}`.
- `POST /upload/zip?subDir=&isFull=` (multipart field `file`) — a `.zip` of plain images. Unzips, keeps image files (jpg/jpeg/png/webp/gif), skips `__MACOSX`/`.DS_Store`, blocks traversal, stores under `subDir`. `isFull=true` wipes the subdir first. Returns `{"state":200,"msg":"ok","count":N}`.
- `GET /widget/icon` — stub returning a 1×1 PNG (the client only builds these URLs).

The mock rejects nothing (it is for testing) and logs sizes.

**Web viewer :8081** — auto-refreshing page (polls `/state`) showing each module's latest uploaded image (VivoCube rendered round), the last `PREVIEW_SCREENSAVER` image, the current fake sensor values, saved profiles/scenes, and the live frame log.

## Project layout

```
mock-corebar/
  package.json  tsconfig.json  Dockerfile  docker-compose.yml  README.md
  src/
    index.ts        seeds fake modules, starts all servers
    protocol.ts     ports, act codes, product ids, reply envelope
    state.ts        in-memory state + bounded frame log
    cert.ts         self-signed cert for SNI ultrabar.local
    discovery.ts    UDP :5319
    control.ts      TLS :7431 (all act handlers)
    http.ts         HTTP :8080 (uploads + decode)
    viewer.ts       HTTP :8081 (web viewer + /state)
    decodeImage.ts  reverses DeviceImage.swift + DeployPackager.swift
```

## Notes / assumptions

- The image decoder reverses `DeviceImage.encode` exactly: `word = (((width & 0x7FF) | (height << 11)) << 10) | flag` with `flag` 4 (opaque, 2 bpp) or 5 (alpha, 3 bpp); RGB565 stored big-endian; the alpha byte follows each pixel when present. 5/6/5 channels are expanded back to 8-bit by bit-replication (the encode step truncated, so this is a close inverse, not bit-exact to the original source image).
- `DeployPackager.gzip()` wraps a raw DEFLATE stream in a standard gzip header, so Node's `zlib.gunzipSync` decodes it (and any other client's gzip).
- The `/upload/zip` success body shape is unconfirmed in the sources (`openapi.yaml` notes this); the mock returns `{state:200,msg:"ok",count}` to match `/upload` plus a count.
