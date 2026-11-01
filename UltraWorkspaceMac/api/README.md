# CoreBar local protocol — API specifications

Machine-readable specs for the UltraBar X **CoreBar** local (LAN) protocol, as reverse-engineered by this project (Deckhand). They exist so the protocol can be shared with a collaborator and consumed by widget/SDK authors without re-reading the prose notes.

**Unofficial and reverse-engineered.** These specs were recovered from decompiled binaries (the "VivoCube Weather Tool" .NET client, the official UltraWorkSpace macOS binary, and the LineOS APK), not from vendor documentation. There is no warranty, and the vendor may change the protocol at any time. Field types and payloads carry `description:` caveats wherever they are uncertain — read those before relying on a field.

**Authoritative source:** [`../PROTOCOL.md`](../PROTOCOL.md). These two specs mirror `PROTOCOL.md`; on any conflict, `PROTOCOL.md` wins. The background for the screen, SenseCube, input-event, device-settings and presence/wake entries is in the corresponding sections of `PROTOCOL.md`.

## The two surfaces, and why two standards

The CoreBar exposes two LAN control surfaces plus UDP discovery:

- **HTTP on `:8080`** — a REST-ish file/asset server (binary uploads, widget icons). This is request/response HTTP, so it is described with **OpenAPI 3.1** in [`openapi.yaml`](openapi.yaml).
- **TLS message socket on `:7431`** — a persistent, line-delimited JSON socket where frames are keyed by an integer `act` code, and either side may send at any time (requests, replies, and device-initiated pushes). This is a message/event protocol, not HTTP, so it is described with **AsyncAPI 2.6** in [`asyncapi.yaml`](asyncapi.yaml). OpenAPI cannot model the pushed frames (discovery replay, Wi-Fi results, `PUSH_MESSAGE`); AsyncAPI can.
- **UDP discovery on `:5319`** — broadcast `{"act":"discover"}`; the CoreBar replies with `tcpPort`, `serialNo`, `ver`, `ip`, `name`. Not modeled in either spec; see `PROTOCOL.md`.

Splitting the specs keeps each one idiomatic for its tooling. The `:7431` integer act code for every message is recorded in an `x-act` extension field on the AsyncAPI message, so you can map a frame on the wire back to its model.

## How to view them

- **OpenAPI** (`openapi.yaml`): paste into [editor.swagger.io](https://editor.swagger.io), or render with Redocly / `redoc-cli`, Stoplight, or any OpenAPI 3.1 tool.
- **AsyncAPI** (`asyncapi.yaml`): paste into [studio.asyncapi.com](https://studio.asyncapi.com), or use the AsyncAPI CLI (`asyncapi validate asyncapi.yaml`, `asyncapi start studio`).

Neither spec is a live endpoint description you can "try out" from a browser: `:7431` is a raw TLS socket (self-signed cert, trust-on-first-use, SNI `ultrabar.local`) and needs a socket client, and `:8080` is plain HTTP on the device's LAN address.

## Confidence and safety notes

- These specs **mirror `PROTOCOL.md`**. Where `PROTOCOL.md` flags something as unconfirmed (exact `/upload/zip` success JSON, per-widget `param` shapes, `PushType` wire encoding, whether `albumId` alone repaints), the spec repeats that caveat rather than inventing a type. Nothing here should be read as a guarantee.
- **No auth on `:8080`.** The HTTP asset surface has no authentication of any kind. Treat the port as LAN-trusted and unauthenticated. `:7431`, by contrast, has an `AUTH` / `REQ_AUTH_TOKEN` token handshake (user taps Approve on the device to pair).
- **Destructive, full-replace operations.** Several `:7431` writes replace an entire list on the device, with no "read it back" op to recover the prior state. The client must own the authoritative list and resend it in full on every change, or it will wipe existing entries:
  - `BATCH_SAVE_PROFILE` (1108) — replaces the whole profile/page list.
  - `BATCH_CREATE_SCENE` (30500) — replaces the whole scene/automation list.
  - `SET_GATEWAY_CONFIG` (30300) and `SET_COREBAR_CONFIG` (30741) with `type: GATEWAY_CONFIG` — replace the gateway endpoint lists.
- **Reads come back raw.** SenseCube sensor reads (`MODULE_PROPERTY_READ` 30200) return the raw device value in `data.result`; the client applies scaling (temperature and humidity are in tenths; illuminance is lux as-is). See `SenseCubeSensorMap` in `asyncapi.yaml`.

## What is covered

- `openapi.yaml`: `POST /upload` (module `.tgz`), `POST /upload/zip` (big-screen image `.zip`), `GET /widget/icon`.
- `asyncapi.yaml`: the `:7431` message protocol — pairing/auth, device + app enumeration, live module discovery and provisioning, property read/write, CoreBar config (screensaver, gateway, app list), screensaver preview, reboot, Wi-Fi scan, profiles/pages, scenes/automations with their dependency pickers, the scene-action catalog, and the device→client `PUSH_MESSAGE` channel. Known enums (`LockTime`, `WidgetType`, `DeviceEnum`, `QLinkProductId`, `PushType`, `ReadWriteType`, `SceneType`), the SenseCube sensor map, and the destructive full-replace caveats are modeled as components.
