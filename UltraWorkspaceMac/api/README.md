# CoreBar local protocol — API specifications

Machine-readable specs for the UltraBar X **CoreBar** local (LAN) protocol, as reverse-engineered by this project (Deckhand). They exist so the protocol can be shared with a collaborator and consumed by widget/SDK authors without re-reading the prose notes.

**Unofficial and reverse-engineered.** These specs were recovered from decompiled binaries (the "VivoCube Weather Tool" .NET client, the official UltraWorkSpace macOS binary, and the LineOS APK), not from vendor documentation. There is no warranty, and the vendor may change the protocol at any time. Field types and payloads carry `description:` caveats wherever they are uncertain — read those before relying on a field.

**Authoritative source:** [`../PROTOCOL.md`](../PROTOCOL.md). These two specs mirror `PROTOCOL.md`; on any conflict, `PROTOCOL.md` wins. The background for the screen, SenseCube, input-event, device-settings and presence/wake entries is in the corresponding sections of `PROTOCOL.md`.

## The two surfaces, and why two standards

The CoreBar exposes two LAN control surfaces plus UDP discovery:

- **HTTP on `:8080`** — a REST-ish file/asset server (binary uploads, widget icons). This is request/response HTTP, so it is described with **OpenAPI 3.1** in [`openapi.yaml`](openapi.yaml).
- **TLS message socket on `:7431`** — a persistent, line-delimited JSON socket where frames are keyed by an integer `act` code, and either side may send at any time (requests, replies, and device-initiated pushes). This is a message/event protocol, not HTTP, so it is described with **AsyncAPI 2.6** in [`asyncapi.yaml`](asyncapi.yaml). OpenAPI cannot model the pushed frames (discovery replay, Wi-Fi results, `PUSH_MESSAGE`); AsyncAPI can.
- **UDP discovery on `:5319`** — the vendor client broadcasts the plain string `discovery.ultrabar` to the interface broadcast address every 2 s; the JSON probe `{"act":"discover"}` (Deckhand) also works on the tested firmware. The CoreBar replies with `tcpPort`, `serialNo`, `ver`, `ip`, `name`. Not modeled in either spec; see `PROTOCOL.md`.

Splitting the specs keeps each one idiomatic for its tooling. The `:7431` integer act code for every message is recorded in an `x-act` extension field on the AsyncAPI message, so you can map a frame on the wire back to its model.

## How to view them

- **OpenAPI** (`openapi.yaml`): paste into [editor.swagger.io](https://editor.swagger.io), or render with Redocly / `redoc-cli`, Stoplight, or any OpenAPI 3.1 tool.
- **AsyncAPI** (`asyncapi.yaml`): paste into [studio.asyncapi.com](https://studio.asyncapi.com), or use the AsyncAPI CLI (`asyncapi validate asyncapi.yaml`, `asyncapi start studio`).

Neither spec is a live endpoint description you can "try out" from a browser: `:7431` is a raw TLS socket (self-signed cert, trust-on-first-use, SNI `ultrabar.local`) and needs a socket client, and `:8080` is plain HTTP on the device's LAN address.

## Confidence and safety notes

- These specs **mirror `PROTOCOL.md`**. Since the vendor's own macOS client (UltraWorkSpace 1.0.1.0, not stripped) was disassembled, most formerly open points are **CONFIRMED**: the `/upload` and `/upload/zip` reply bodies, the full `BATCH_SAVE_PROFILE` DTO and per-widget `param` schemas, the `PUSH_MESSAGE` request/reply shape and its `type` encoding (enum name), the pairing payload, and that `albumId` is dead. Remaining `HYPOTHESIS` items are marked as such in the descriptions. Nothing here should be read as a guarantee.
- **No auth on `:8080`.** The HTTP asset surface has no authentication of any kind. Treat the port as LAN-trusted and unauthenticated. `:7431`, by contrast, has an `AUTH` / `REQ_AUTH_TOKEN` token handshake (user taps Approve on the device to pair). The vendor client does not verify the device's TLS certificate; Deckhand pins it (TOFU).
- **Destructive, full-replace operations.** Several `:7431` writes replace an entire list on the device, with no "read it back" op to recover the prior state (only `SCENE_DEPENDS_PROFILE` 30710 lists profile ids/names). The client must own the authoritative list and resend it in full on every change, or it will wipe existing entries:
  - `BATCH_SAVE_PROFILE` (1108) — replaces the whole profile/page list; a missing or empty array wipes the home screen.
  - `BATCH_CREATE_SCENE` (30500) — replaces the whole scene/automation list.
  - `SET_GATEWAY_CONFIG` (30300) and `SET_COREBAR_CONFIG` (30741) with `type: GATEWAY_CONFIG` — replace the gateway endpoint lists.
  - `POST /upload/zip` without `subDir` (what the vendor client does) wipes the device's whole external-files directory, including any other client's assets.
- **`PUSH_MESSAGE` must be answered.** Act 1000000 is a device→PC request; the PC replies with the same `id`, `code 200` and `{type, payload}`. It only arrives on an open connection (the vendor keeps a persistent one with a 3 s heartbeat, act 20).
- **Upload replies are acknowledgements, not completion.** `/upload?serialNo=` `state:200` means the module acknowledged the update command; it then fetches `http://<corebar>:8080/tgz/<serial>.tgz` itself over Wi-Fi and applies it seconds later. Switch VivoCube layers with property 9 (`(layer<<16)|widget`) instead of re-uploading.
- **Reads come back raw.** SenseCube sensor reads (`MODULE_PROPERTY_READ` 30200) return the raw device value in `data.result`; the client applies scaling (temperature and humidity are in tenths; illuminance is lux as-is). See `SenseCubeSensorMap` in `asyncapi.yaml`.

## What is covered

- `openapi.yaml`: `POST /upload` (module `.tgz`, with the confirmed `state` code table), `POST /upload/zip` (big-screen image `.zip`, with the wipe hazard), the static mounts `GET /tgz/**` and `GET /module/**`, `GET /widget/icon`.
- `asyncapi.yaml`: the `:7431` message protocol — pairing/auth, heartbeat, device + app enumeration, live module discovery and provisioning, property read/write (incl. VivoCube property 9 layer switching), CoreBar config (screensaver, gateway, app list), screensaver preview (http-only, no ack), reboot, Wi-Fi scan, profiles/pages (full DTO + widget `param` schemas), the profile id list (30710), scenes/automations with their dependency pickers, the scene-action, trigger, knob-device and app-capability catalogues, app install (30600/30601), module OTA (30400/30401 with the `UBX-OTA-FILE` header and MD5 rule), and the device→client `PUSH_MESSAGE` request plus the PC's reply. Known enums (`LockTime`, `WidgetType`, `DeviceEnum`, `QLinkProductId`, `PushType`, `ReadWriteType`, `SceneType`), the SenseCube sensor map, and the destructive full-replace caveats are modeled as components.
