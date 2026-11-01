# Mock CoreBar

A Node.js + TypeScript **emulator of the UltraBar X "CoreBar" device**, so you can test a client (the macOS app **Deckhand**) without the real hardware. It speaks the device's local protocol (UDP discovery, TLS control, HTTP upload) and ships a browser viewer that renders the widget images the client uploads.

The protocol is based strictly on this repo's `PROTOCOL.md`, `api/asyncapi.yaml`, `api/openapi.yaml`, and the Swift sources in `Sources/UltraBarKit/` (`DeviceImage.swift`, `DeployPackager.swift`, `Discovery.swift`, `CoreBarClient.swift`). It is a test double, not a reimplementation of LineOS.

## Ports

| Port | Proto | Purpose |
|------|-------|---------|
| 5319 | UDP | Discovery. Replies to Deckhand's `{"act":"discover"}` and to the vendor client's plain `discovery.ultrabar` probe with a CoreBar descriptor. |
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

Then open <http://127.0.0.1:8081>. Run on the same host/LAN as the client and its broadcast discovery (Deckhand: `{"act":"discover"}` to `255.255.255.255:5319`; the official app: `discovery.ultrabar` to the interface broadcast address every 2 s) will find the mock directly, because the mock replies to the datagram's sender.

## Running the official UltraWorkSpace app against the mock

The vendor's macOS client (UltraWorkSpace 1.0.1.0) works against the mock unchanged, which is the easiest way to capture exactly what it sends:

1. Start the mock natively (`npm run dev`) on the same machine or LAN — not in Docker, because the vendor app only discovers by broadcast (it has a manual IP entry too, which works with Docker's published ports).
2. In the vendor app open *Search Core Bar*; the mock answers its `discovery.ultrabar` probe and shows up by serial + IP. Add it. Pairing (act 101 with the vendor's fixed UUID) is auto-approved by the mock after ~1 s; the vendor app does not verify the TLS certificate, so the mock's self-signed cert is accepted.
3. Configure modules/profiles in the vendor app and press **Deploy project**. The mock logs the whole sequence (30300 → 1108 → 1010 → 30500 → `POST /upload/zip` → 1103) in the viewer's frame log, stores the profiles/scenes, and writes every uploaded body unmodified to `captures/` (see below). A VivoCube layer deploy arrives as `POST /upload?serialNo=` and is decoded into the viewer.

Note that the vendor app posts `/upload/zip` without `subDir`/`isFull`; the mock emulates the device default (`isFull=true` on the root) and wipes everything previously uploaded, exactly like the real CoreBar would wipe Deckhand's assets.

## Raw captures

Every body received on `:8080` is also written unmodified to `mock-corebar/captures/` (override with `MOCK_CAPTURE_DIR`; the folder is git-ignored): module packages from `/upload?serialNo=` as `.tgz` and asset zips from `/upload/zip` as `.zip`, with the serial / subDir and original filename in the name. Use them to diff what the vendor app produces against what Deckhand produces (`tar tzf`, `unzip -l`, or the mock's own decoder).

## Run via Docker

```sh
cd mock-corebar
docker compose up --build
```

> **IMPORTANT — UDP broadcast discovery does not cross Docker Desktop's NAT on macOS.** A container cannot receive the client's `255.255.255.255` broadcast, so auto-discovery will **not** find the mock when it runs in Docker on macOS. Workaround: the ports are published to the host, so in Deckhand use **CoreBars → Add by IP…** and enter `127.0.0.1`. The compose file sets `MOCK_IP=127.0.0.1` so the discovery descriptor advertises a host the client can connect back to. (Unicast discovery to `127.0.0.1:5319` also works through the published UDP port; only the `255.255.255.255` broadcast is dropped.)

Running natively (`npm run dev`) has no such limitation and supports broadcast discovery.

The Dockerfile uses the committed `package-lock.json` with `npm ci` (build stage) and `npm ci --omit=dev` (runtime stage); `.dockerignore` keeps `node_modules/` and `dist/` out of the build context.

## Automated client: `kitcheck e2e`

The repo's `kitcheck` tool drives the complete UltraBarKit protocol path against this mock and checks what the viewer recorded:

```sh
# from the repo root, with the mock running
swift build --product kitcheck
.build/debug/kitcheck e2e            # defaults to 127.0.0.1; pass an IP to target another host
```

It covers: unicast probe (Add-by-IP path), pairing (`REQ_AUTH_TOKEN`), token check with the pinned cert and rejection of a wrong pin before auth, module listing (4 modules, all product types), provision merge with remembered endpoints (`SET_GATEWAY_CONFIG` recorded by the mock), SenseCube readings (23.5 °C / 54 %RH / 473 lux), a 240 × 240 widget upload decoded and orientation-checked via the viewer, the big-screen zip upload + `PREVIEW_SCREENSAVER`, and a raw unknown act that must get a correlated reply. Takes about 25 s and exits non-zero on any failure.

## Endpoints and acts implemented

**UDP :5319** — replies to `{"act":"discover"}` (broadcast or unicast) and to the vendor's plain `discovery.ultrabar` string with `{serialNo, ver, ip, name, tcpPort}` (the exact shape `Discovery.swift` and the vendor client parse; note the field is `ver`, and `tcpPort` must be present).

**TLS :7431** control acts:

- `AUTH` (100) — accepts any token (and the one issued at pairing).
- `REQ_AUTH_TOKEN` (101) — auto-"approves" after ~1 s, logs an `Approve tapped` line, returns `data.state` + `data.token`. (A real CoreBar waits for the user to tap **Approve** on its screen; the vendor client gives it 15 s, Deckhand 30 s.)
- `HEARTBEAT_PACKAGE` (20) — the vendor app sends it every 3 s on its persistent connection; the mock just logs it (no reply, like the device).
- `GET_DEVICE` (1300) — a small logical device list.
- `GET_APP_LIST` (1000) — a small app list.
- `MODULE_START_DISCOVERY` (30100) with data `"can"`/`"mesh"` — pushes `MODULE_START_DISCOVERY_REPLAY` (30102) frames, one per seeded module on that bus (VivoCube, SenseCube, KnobKey on `can`; DotKey on `mesh`, offline). Uses the `QLinkProductId` ints from `PROTOCOL.md`.
- `MODULE_STOP_DISCOVERY` (30101) — ok.
- `SET_GATEWAY_CONFIG` (30300) — stores the `CoreBarConfiguration`, ok.
- `MODULE_PROPERTY_READ` (30200) — SenseCube `deviceId 10/11/12 propId 1` return raw lux `473`, temp `235` (=23.5 °C), hum `540` (=54.0 %RH). Per module the mock **caches property 4 (screen on/off) and property 9 (`(layer<<16)|widget`)** like the real CoreBar's `VCWidgetMain`: reads return the cached value (screen defaults to on; property 9 defaults to the uploaded package's `defaultLayer` + first widget), everything else returns `0`.
- `MODULE_PROPERTY_WRITE` (30201) — ok (result stripped). Writing property 9 selects which decoded widget image the viewer shows for that module; a widget id that is not in the last package makes the viewer show **nothing** and logs a `BLACK screen` line — the same mechanism that blanks a real VivoCube when a stale cached id is re-applied. Property 4 = 0 is remembered until written back to 1, so Deckhand's **Recover display** (4 = 1, 9 = layer 1 / widget 101) can be exercised against the mock.
- `QUERY_MODULE_STATE` (30730) — empty (mirrors tested firmware).
- `GET_COREBAR_CONFIG` (30740) / `SET_COREBAR_CONFIG` (30741) — `BASE_SET` echoes/stores the `ScreensaverConfig`; `GATEWAY_CONFIG` stored (the read returns null, like the tested firmware, so the client falls through to the live scan); `APP_LIST` read-only.
- `PREVIEW_SCREENSAVER` (30742) — emulates the firmware: no ack; pulls an http(s) url and shows it in the viewer. (On the real device the dialog never appears — BadTokenException — so Deckhand no longer uses it.)
- `SCENE_DEPENDS_PROFILE` (30710) — lists page ids/names; `BATCH_SAVE_PROFILE` (1108) requires ids and logs a HOME SCREEN WIPED warning on an empty list; `TRIGGER_PROFILE_CHANGE` (1103) rejects unknown ids with `profile id error`.
- `SYS_REBOOT` (20100) — ok.
- `START_SCAN_WIFI` (1633) / `STOP_SCAN_WIFI` (1634) — pushes `CUBE_SCAN_WIFI_LIST_RESULT` (1635) with a couple of fake networks.
- `BATCH_SAVE_PROFILE` (1108) / `BATCH_CREATE_SCENE` (30500) / `TRIGGER_PROFILE_CHANGE` (1103) — store + ok.
- **Unknown acts** — reply `code:200` with empty data and log an `UNKNOWN act=…` line, so new client calls don't break testing. The `SCENE_*` dependency queries (30700–30721), `GET_PROFILE_WIDGET` (1002), `SCENE_ACTION_V2` (1205) and everything else not listed above hit this handler.
- If a handler throws, the mock replies with `code: 11, msg: "exception"` (the `EXCEPTION` envelope code) so the client's request still correlates and does not hang.

Every inbound/outbound frame is logged to stdout and to the viewer's live frame log.

**HTTP :8080**:

- `POST /upload?serialNo=` (multipart field `file`; filename and content type are not checked, so both Deckhand's `<serial>.tgz`/`application/gzip` and the vendor's `config.tgz`/`application/octet-stream` work) — the module `.tgz`. The mock **decodes** it: gunzip → untar → parse `config.json` and **every** `com_res<widgetId>/default.bin` (8-byte LVGL header + RGB565(+alpha) → RGBA → PNG via `pngjs`). It keeps all widget images of the last package per `serialNo` and shows the one selected by the cached property 9 (initially the `defaultLayer`'s first item). Returns `{"state":200,"msg":"ok"}` immediately — on the real device that only means the module acknowledged the update command and will fetch `/tgz/<serial>.tgz` itself a few seconds later; the mock applies it at once and does not emulate the busy / no-network states (1, 2, 4, -1).
- `POST /upload/zip?subDir=&isFull=` (multipart field `file`) — a `.zip` of plain images. Unzips, keeps image files (jpg/jpeg/png/webp/gif), skips `__MACOSX`/`.DS_Store`, blocks traversal, stores under `subDir`. Defaults match the device (`subDir=""`, `isFull=true`), so a request without `subDir` wipes everything uploaded before (what the vendor app does). Returns `{"state":200,"msg":"ok","count":N}` — the real device returns the count as `"data":N` instead (confirmed since the mock was written; the mock's `count` field is a known deviation, harmless because Deckhand only checks `state`).
- `GET /widget/icon` — stub returning a 1×1 PNG (the client only builds these URLs).

The mock rejects nothing (it is for testing) and logs sizes. It does not enforce the real device's per-route upload limits (100 MB `.tgz`, 50 MB `.zip`); the only cap is a generic 64 MB multer limit.

**Web viewer :8081** — auto-refreshing page (polls `/state`) showing each module's currently selected widget image (per the cached property 9), the last `PREVIEW_SCREENSAVER` URL/image, the current fake sensor values, saved profiles/scenes, and the live frame log. `kitcheck e2e` reads the same `/state` JSON to verify what arrived.

## Project layout

```
mock-corebar/
  package.json  package-lock.json  tsconfig.json
  Dockerfile  docker-compose.yml  .dockerignore  .gitignore  README.md
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

`package-lock.json` is committed (the Dockerfile relies on it for `npm ci`). `.gitignore` excludes `node_modules/` and `dist/`; `.dockerignore` additionally excludes `npm-debug.log` and `.DS_Store`.

## Notes / assumptions

- The image decoder reverses `DeviceImage.encode` (and the vendor's identical LVGL v8 encoder) exactly: `word = cf | (width << 10) | (height << 21)` with `cf` 4 (opaque, 2 bpp) or 5 (alpha, 3 bpp); RGB565 stored big-endian; the alpha byte follows each pixel when present. 5/6/5 channels are expanded back to 8-bit by bit-replication (the encode step truncated, so this is a close inverse, not bit-exact to the original source image). Deckhand uploads opaque `cf` 4 images by default.
- `DeployPackager.gzip()` wraps a raw DEFLATE stream in a standard gzip header, so Node's `zlib.gunzipSync` decodes it (and any other client's gzip, including the vendor's zlib `deflateInit2(…, 31, …)` output).
- The `/upload/zip` success body on the real device is `{state:200,msg:"ok",data:<count>}`; the mock still returns the count as `count` (see above).
- The mock does not emulate the VivoCube's asynchronous apply (it shows the new image immediately), the `/upload` busy / no-network states, the 5 s module timeout, or the 15 s pairing window.
- The mock is more permissive than the device (any token authenticates, pairing auto-approves, no upload limits) and writes every upload to `captures/`. Keep it on localhost.
