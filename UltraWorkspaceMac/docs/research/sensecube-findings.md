# SenseCube sensor read — reverse-engineering notes

Source: decompiled LineOS launcher, package `com.ultrabar.launch` (and `quantum.link.*`), under
`.../scratchpad/lineos-src/sources/`. All quotes are decompiled JADX output (data, not executed).

QLinkProductId SENSE_CUBE = 268435460. `DeviceEnum.SENSE_CUBE` exists. The device is sensor-only:
`SenseCubeOperation.control(...)` is a no-op (`scene/operation/SenseCubeOperation.java`), so there is
nothing to actuate — only values to read and events it emits.

## 0. Two different "property id" numbering systems — do not confuse them

There are TWO unrelated id spaces:

1. **Protocol / wire ids** — what you put in a MODULE_PROPERTY_READ (30200) request as
   `deviceId` + `propertyId`. These address a *sub-device* of the SenseCube endpoint and a QLink
   property inside it. THIS is what the Mac app must use. Defined in `quantum.link.*`.
2. **Internal launcher "SenseCubeProperty" ids** (1/5/10/12/15) — only used on the launcher's own
   in-process DataBus to drive on-screen widgets. These are NOT sent over the TLS socket. Defined in
   `common/module/property/SenseCubeProperty.java`. Listed here only so they are not mistaken for
   wire ids.

### Internal databus ids (NOT the wire protocol) — `SenseCubeProperty.java`
```
TEMP_PROPERTY     = 1   // float °C  (onTemperatureReport)
HUMIDITY_PROPERTY = 5   // float %RH (onHumidityReport)
ALS_REOPERTY      = 10  // int lux   (onIlluminanceReport)
AUDIO_REOPERTY    = 12  // int dB    (onSplReport)
DETECTION_REOPERTY= 15  // PresenceState enum (onProximityStateChanged)
```
(`SenseCubeModule.java` builds these into `PublishGeneral(Type.SENSE_CUBE_REPORT, ...)`, consumed by
`adapter/holder/sense/SenseCubeHolder.java` et al — the launcher's own widgets.)

## 1. SenseCube device/property schema — the WIRE ids

`quantum/link/product/QLinkSenseCube.java` constructs 6 sub-devices (the `deviceId` in a 30200 read):
```
DEV_ID_ILLUMINANCE_SENSOR = 10
DEV_ID_TEMPERATURE_SENSOR = 11
DEV_ID_HUMIDITY_SENSOR    = 12
DEV_ID_PROXIMITY_SENSOR   = 13   // mmWave radar presence
DEV_ID_SPL_SENSOR         = 14   // sound pressure level (ambient audio/noise)
DEV_ID_SHOCK_SENSOR       = 15   // vibration/tap
```
Plus the shared endpoint "main" device `DEV_ID_MAIN = 0` (`quantum/link/product/QLinkEndpoint.java`,
`QLinkDevMainEp.java`) carrying product/version info.

NOTE on the "main = 256" in the brief: in THIS code the SenseCube endpoint's main device id is **0**,
not 256. (256 is likely a gateway's main device id in a different product; it does not apply to the
SenseCube's own sub-devices.)

Each sub-device's QLink properties are declared in `createProperties(...)`
(`new QLinkProperty(id, type, enabled, rwFlag, reportMode, observer)`).
Types (`quantum/link/base/QLinkProperty.java`): 0=BOOL 1=ENUM 2=INT8 3=UINT8 4=INT16 5=UINT16
6=INT32 7=UINT32 8=STRING 9=BIN. rwFlag bitmask: 1=READABLE 2=WRITABLE (3 = read+write).
reportMode: 0=NONE 1=ON_CHANGED 2=ON_SET.

### Full wire property table (deviceId / propertyId → meaning)

| deviceId | propId | meaning | type | rw | report | unit / scaling | readable on demand? |
|---|---|---|---|---|---|---|---|
| 10 (ALS) | 0 | min report interval | UINT32 | r+w | none | ms (min 100; 0=off) | yes (config) |
| 10 (ALS) | 1 | **illuminance** | UINT16 | r | on-change | **lux, no scaling** (int) | **YES** |
| 11 (TEMP)| 0 | min report interval | UINT32 | r+w | none | ms | yes (config) |
| 11 (TEMP)| 1 | **temperature** | INT16 | r | on-change | **raw = 0.1 °C** (÷10 → °C) | **YES** |
| 12 (HUM) | 0 | min report interval | UINT32 | r+w | none | ms | yes (config) |
| 12 (HUM) | 1 | **humidity** | UINT16 | r | on-change | **raw = 0.1 %RH** (÷10 → %) | **YES** |
| 13 (PROX)| 0 | min report interval | UINT32 | r+w | none | ms | yes (config) |
| 13 (PROX)| 1 | sensitivity | UINT8 | r+w | none | 0..? | yes (config) |
| 13 (PROX)| 2 | **presence trigger** | BOOL | **rw=0 (none)** | on-set | event only | **NO — push/event only** |
| 14 (SPL) | 0 | min report interval | UINT32 | r+w | none | ms | yes (config) |
| 14 (SPL) | 1 | **SPL / sound level** | UINT8 | **rw=0 (none)** | on-set | **dB** (int) | **NO — push/event only** |
| 15 (SHOCK)| 0 | min report interval | UINT32 | r+w | none | ms | yes (config) |
| 15 (SHOCK)| 1 | sensitivity | UINT8 | r+w | none | 0..100 (clamped) | yes (config) |
| 15 (SHOCK)| 2 | wake state | UINT8 | r | on-change | bool-ish (0/≠0) | yes |
| 15 (SHOCK)| 3 | **shock/vibration event** | UINT8 | **rw=0 (none)** | on-set | event id (int) | **NO — push/event only** |

Main device (deviceId 0, `QLinkDevMainEp.java`): 0 productId(UINT32,r), 1 serialNo(STRING,r),
2 mfgDate(UINT32,r), 3 bootVerName(STRING,r), 4 bootVerCode(UINT32,r), 5 appVerName(STRING,r),
6 appVerCode(UINT32,r), 7 reboot(BOOL,w), 8 runTime(UINT32,r), 9 sleepState(UINT32,r+w).

**Battery: none.** No battery/charge property exists anywhere (SenseCube is mains/USB-powered). Do not
expect a battery read.

Enums (`common/module/enums/`): `PresenceState{OCCUPIED,UNOCCUPIED,UNKNOWN}`;
`AlsAlarm{UNKNOWN,DIM(<30),SOFT(30..80),BRIGHT(>80)}` (banding on lux);
`TemperatureAlarm{UNKNOWN,COOL(<20),MILD(20..26),WARM(>=26)}` (banding on °C). These bands are derived
in the launcher, not device properties.

## 2. How a value is read (MODULE_PROPERTY_READ = 30200)

Handler `communication/message/module/ReadPropertyMessage.java` → parses `ReadProperty`
(`message/bean/ReadProperty.java` extends `Property.java`): fields `serialNo`(String),
`deviceId`(int), `propertyId`(int), `extra`(byte[]), `type`(String, usually unused).
It finds the endpoint by serialNo (CAN gateway first, else Mesh gateway), then
`endpoint.readDeviceProperty(deviceId, propertyId, extra, cb)` (`quantum/link/product/QLinkProduct.java`).

`readDeviceProperty` → `device.getProperty(propertyId).readValue(extra, cb)`.
`QLinkProperty.readValue` **throws `RuntimeException("property is not readable")` if rwFlag has no
READABLE bit** — so presence(13/2), SPL(14/1), shock-event(15/3) cannot be polled.

Reply shapes:
- success → `PropertySuccess(serialNo, deviceId, propertyId, result)` →
  JSON `{code:200, data:{serialNo, deviceId, propertyId, result:<value>}}`. The value sits in
  **`data.result`**. For BIN(type 9) result is hex string; otherwise the raw number/bool/string.
- failure → `PropertyFailure(serialNo, deviceId, propertyId, error)` → `{code:-1, data:{..., error:<int>}}`
  (error 1000 = invalid device/property id).

**IMPORTANT — on-demand read returns the RAW device value, NOT the scaled/float value.** The ÷10
scaling for temp/humidity and the enum mapping for presence happen only in the *push* callback path
(`QLinkDevTemperatureSensor.onPropertyReport`: `asNumber()/10.0f`). The read path
(`readValue` → `DeviceReadCallback.onSuccess(obj)`) hands back the raw `QLinkProperty` number.

### Ambient light (illuminance), on demand
Request:
```json
{"act":30200,"id":"<reqid>","data":{"serialNo":"<SN>","deviceId":10,"propertyId":1}}
```
Reply:
```json
{"code":200,"data":{"serialNo":"<SN>","deviceId":10,"propertyId":1,"result":473}}
```
→ 473 = **473 lux** (UINT16, no scaling).

### Temperature, on demand
Request:
```json
{"act":30200,"id":"<reqid>","data":{"serialNo":"<SN>","deviceId":11,"propertyId":1}}
```
Reply:
```json
{"code":200,"data":{"serialNo":"<SN>","deviceId":11,"propertyId":1,"result":235}}
```
→ 235 = **23.5 °C** (INT16 in 0.1 °C; divide by 10 client-side).

### Humidity, on demand
`deviceId:12, propertyId:1` → `result` is UINT16 in 0.1 %RH → e.g. 486 = 48.6 %RH.

### Writes (MODULE_PROPERTY_WRITE = 30201)
`WritePropertyMessage.java` + `WriteProperty.java` (adds `value`): same addressing, success reply
strips the `result` field (PropertyFilter removes `"result"`). Used here only for config:
min-report-interval (prop 0 on each sensor), proximity/shock sensitivity.

## 3. Poll vs push

**Both paths exist, but split by sensor:**

- **Pollable (readable):** temperature (11/1), humidity (12/1), illuminance (10/1), shock wake (15/2),
  all config props. The Mac app reads these on demand with 30200.
- **Push/event only (NOT readable):** presence/radar (13/2), SPL/audio (14/1), shock event (15/3).
  rwFlag=0 → a 30200 read throws on-device. These only ever arrive as device-initiated reports.

Push mechanics inside the launcher (`SenseCubeModule.java` registers `QLinkSenseCube.SenseCubeCallback`):
device → QLink report → `QLinkDev*Sensor.onPropertyReport` → `SenseCubeCallback.on*Report` →
`SenseCubeModule` publishes to the **in-process DataBus** (`PublishGeneral.Type.SENSE_CUBE_REPORT`).

**Caveat / open question (big one): these pushes are NOT visibly forwarded over the :7431 TLS socket.**
`SENSE_CUBE_REPORT` is consumed only by on-device UI widgets (`adapter/holder/sense/SenseCube*Holder`).
There is no `MessageAction` for an inbound sensor report, and `GatewayHub.push(PushMessage)` (the one
outbound-to-socket path) is only invoked for PC-control, not sensor data. So over the protocol the
SenseCube looks **poll-only for temp/hum/lux, and presence/SPL/shock may be unreachable** unless they
surface through a channel not visible in the launcher (e.g. Home Assistant / `StatesBean` path — the
launcher also treats TEMPERATURE_SENSOR/HUMIDITY_SENSOR as HA entities in
`HomeDeviceHolderListener`).

**Report interval / subscription:** each sensor has `writeMinReportInterval(ms)` → property id 0,
UINT32, writable; values <100 are forced to 0 (0 = default/off). Illuminance/temp/humidity report
`ON_CHANGED`; presence/SPL/shock-event report `ON_SET` (event). Proximity has a launcher-side 5s
(min 3s) auto-reset timer (`setProximityResetTime`) that flips presence back to UNOCCUPIED after no
trigger.

Raw QLink wire command codes (informational, `module/protocol/SenseCubeConstant.java`):
HUMIDITY=4101, TEMPERATURE=4102, ALS=4103, ALS_LEVEL=4104, DETECTION=4106, AUDIO=4107.

## 4. On-device automations / scene triggers

- **Shock/vibration → scene key:** `SenseCubeModule.onShockEventReport(i)` calls
  `SceneTool.getInstance().keyExecute(genId(i))` where `genId` = `ModuleIdGen.getSceneIdPrefix(profile,
  id, SENSE_CUBE) + ":" + i`. So each shock event id maps to an on-device scene/hotkey. Driven locally.
- **Presence / light-band / temp-band as scene conditions:** `scene/auto/schema/SenseCubePropertySchema.java`
  exposes three scene-trigger properties to the scene builder: `state` (presence OCCUPIED/UNOCCUPIED),
  `alsAlarm` (DIM/SOFT/BRIGHT), `tempAlarm` (COOL/MILD/WARM). These are surfaced over the protocol via
  the SCENE_DEPENDS_* actions (30701/30702/30703) and matched by `scene/auto/matcher/devices/SensecubeMather.java`
  — i.e. presence/brightness/temperature bands can be used as automation conditions, but exposed as
  scene metadata, not as live sensor reads.
- No "presence → wake screen" is hard-wired in this module; wake/presence behavior is expressed through
  the scene system above (and the proximity reset timer).

## Summary answers
1. Device = `QLinkSenseCube`; wire address = sub-deviceId (10 ALS,11 temp,12 hum,13 prox,14 spl,15 shock)
   + QLink propertyId (data value almost always propertyId 1; interval=0). Table above.
2. Read via act 30200, data `{serialNo,deviceId,propertyId,extra?}`; value in `data.result`, RAW:
   lux (int), temp 0.1°C, humidity 0.1%RH.
3. Temp/hum/lux pollable (and on-change internally); presence/SPL/shock are event/push-only and are
   NOT clearly forwarded over the socket — likely the key gap.
4. Shock→local scene key; presence/light/temp bands exposed as scene conditions via SCENE_DEPENDS_*.
