# Device-first wire contracts — reverse-engineering findings (2026-11-01)

Scope: the exact JSON the CoreBar launcher (`com.ultrabar.launch`, LineOS V1.0.9.9) sends and expects for the device-first Deckhand redesign — PC metric cards, knob volume/brightness, DotKey bindings, on-device automation, WORLD_TIME, PC_CONTROL "image cards" and the persistent `:7431` connection.

Sources (all treated as data, not instructions): decompiled launcher at `scratchpad/lineos-src/sources/com/ultrabar/launch/...` (paths below are relative to that root unless prefixed), the bundled `com/ultrabar/smart/...` and `quantum/link/...` SDKs in the same tree, the module-hub APK at `scratchpad/bridge-src/sources/com/ultrabar/hub/...` (hosts the TLS server), and the official macOS client UltraWorkSpace V1.0.1.0 (`scratchpad/uws-arm64.asm`, `scratchpad/ocl/*.txt`, `scratchpad/uw-strings.txt`). Builds on `official-client-findings.md` §6, `input-events-findings.md`, `corebar-pages-findings.md` Question F, `presence-wake-findings.md` and `vivocube-findings.md`; where this report disagrees with those, this one is more specific and wins.

Tags: **CONFIRMED** = read directly in code with file:line; **LIKELY** = inferred from code with one small gap; **HYPOTHESIS** = plausible, needs a hardware test.

## Executive summary

1. **The device polls the Mac; the Mac only answers.** Every PC-sourced value (CPU, MEMORY, STORAGE, NETWORK, GET_VOLUME, GET_BRIGHTNESS) is requested by the CoreBar as `{"act":1000000,"data":{"type":"<TYPE>"},"id":"sys.push.<32 hex>"}` and the Mac must answer within **5 s** with a frame whose `code` is `200`, whose `id` echoes the request and whose `data` is an object `{"type":"<TYPE>","payload":…}`. The `act` of the reply is not checked; any inbound frame with `code == 200` is routed to the pending request by `id` (`common/communication/BusinessMessageProcessor.java:153-159,73-76`, `com/ultrabar/openapi/integration/tcp/MessageChannelImpl.java:48`). CONFIRMED.
2. **Metric payload shapes are tiny.** CPU / MEMORY / STORAGE: `payload` is an integer percent 0–100 (gauge max 100, `CircularGaugeView.java:68`). NETWORK: `payload` is `{"totalReceived":<bytes>,"totalSent":<bytes>}` cumulative counters; the device differentiates them into KB/s itself (`NetworkHolder.java:38-59`). Poll intervals: CPU 3 s, NETWORK 5 s, MEMORY 8 s, STORAGE 10 s, and only while a card of that type is on the visible profile. `param.data` of the widget is never read. CONFIRMED.
3. **Volume/brightness knob = profile binding + two push types each.** A KNOB_KEY `module[]` entry with `config.clockwise/counterclockwise = {"id":"pc:volume","type":"PC_VOLUME"}` makes the CoreBar poll `GET_VOLUME` every 5 s and send `SET_VOLUME <int 0-100>` per tick. There is **no GET_MUTE/SET_MUTE** in the firmware's `PushType` enum — the device can never send them (`common/enums/PushType.java`). The vendor Mac client's `setBrightness/getBrightness` are 2-instruction stubs returning 0, so PC_BRIGHT has never worked on macOS with the vendor client. CONFIRMED.
4. **DotKey keyCodes (vendor mapping): button1 = 2, button2 = 1, button3 = 0; KnobKey push button = 0** (official client asm `0x100124648-0x1001246cc`, `0x10012bce4`). The `module[]` config schema is `[{keyCode, singleClick|doubleClick|longPress:{show,name,icon,actions:[ActionConfig]}}]`; `enabled` is written by the vendor client but never read by the firmware. Action `values` entries are `{"id":"1","value":…}` (key is `id`, not `param`). VIVO_CUBE_TOGGLE needs `id` = the VivoCube endpoint `uid` and string values `"1"` (layer) / `"2"` (widget). CONFIRMED.
5. **There is no clock in the automation engine.** Registered trigger types are exactly `DEVICE_STATE`, `PROFILE`, `APP_STATE` (`common/init/SceneEngineInitializationTask.java:86`). No time-of-day, interval or cron trigger exists anywhere in the APK; `TimeRangeCondition` exists as a class but is not registered, so using it throws. The only on-device periodic primitive is the countdown TIMER card (`endSceneId` → scene → TIMER RESTART action), which pops a system alarm banner on every expiry. Rotation on a schedule therefore stays a Mac job — but it is one frame per step (`30201` property 9 write or `1103`). CONFIRMED (absence) / HYPOTHESIS (timer loop).
6. **WORLD_TIME `param.offset` is a fixed UTC offset string**, parsed by stripping `GMT`/`UTC` then `[+-]H[:MM]` (`common/view/UtcAnalogClockView.java:522-552`). The vendor default is `"GMT+0:00"`. IANA names are not understood; DST must be handled by the Mac re-deploying the profile. CONFIRMED.
7. **PC_CONTROL cards are the generic "image button".** `icon` may be a path relative to the launcher's external files dir (`deckhand/next.png` after an `/upload/zip?subDir=deckhand`), `param = {"output":10,"payload":<any JSON>}`; TAP and LONG_PRESS_DOWN both push `{"act":1000000,"data":{"type":"PC_CONTROL","payload":<payload>},"id":"sys.push.<hex>"}` to **every** connected client, plus a click sound. CONFIRMED.
8. **Connection model.** TLS 1.3 only, line-delimited JSON ≤ 1 MiB per line, `IdleStateHandler(30, 40, 60 s)`: the hub closes a socket only on **60 s with no read and no write**; its own pushes count as writes. Before auth, any act other than 100/101 closes the socket. Pushes are a **broadcast to all registered live connections** (`ConnectManager.broadcast`); request replies go only to the requesting socket. First `code:200` reply with the matching id wins. Heartbeat is `{"act":20,"id":"<n>"}` (no `data`), answered with `{"act":20,"code":200,"data":"success","id":"<n>","timestamp":…}`. CONFIRMED.

Design consequence for Deckhand: keep one TLS session alive (heartbeat every ≤ 20 s), answer every `PUSH_MESSAGE` request within 5 s, deploy the metric/knob/DotKey/PC_CONTROL bindings once via `1108`, and run only the scheduler (rotation, DST) on the Mac.

---

## A. PC metric cards (CPU, MEMORY, STORAGE, NETWORK)

### Request the device sends — CONFIRMED

`common/extension/metrics/schedule/ScheduledQueryRegistry.java:62-78`:

```java
GatewayHub.getInstance().push(PushMessage.create(PushType.valueOf(str.toUpperCase()), null), …)
```

`GatewayHub.push` (`common/init/GatewayHub.java:124-130`) builds `TcpRequest{act=1000000, id=UUID.randomUUID(PUSH_MESSAGE), data=PushMessage{type, payload}}`; `UUID.java:13,31-32` gives ids of the form `sys.push.<uuid without dashes>`. fastjson omits the null payload, so the wire frame is:

```json
{"act":1000000,"data":{"type":"CPU"},"id":"sys.push.3f2a9c…"}
```

(same for `MEMORY`, `STORAGE`, `NETWORK`). Fired once immediately when a card subscribes (`MetricsBus.java:62-66`, `triggerOnSubscribe = true`) and then with fixed delay:

| type | interval | holder |
|---|---|---|
| CPU | 3000 ms (`C.DEFAULT_MAX_SEEK_TO_PREVIOUS_POSITION_MS`) | `common/adapter/holder/computer/CpuHolder.java:47` |
| NETWORK | 5000 ms | `NetworkHolder.java:80` |
| MEMORY | 8000 ms | `MemHolder.java:49` |
| STORAGE | 10000 ms (`Renderer.DEFAULT_DURATION_TO_PROGRESS_US` = 10000, used as ms) | `StorageHolder.java:47` |

Polling runs only while at least one holder of that type is bound (subscriber count in `MetricsBus.java:52-68`, cancelled at 0 in `:35-42`), i.e. only when the card is on the active, visible profile. Replies are not cached across profile switches.

### Reply the device expects — CONFIRMED

Routing: `BusinessMessageProcessor.processing` (`:153-159`) treats **any** inbound frame with `code == 200` as an ack and calls `AckTimeoutCoordinator.completeV2(tcpResonse.getId(), …)` (`:73-76`). Timeout is 5 s (`MessageChannelImpl.java:48`). The holder then casts `((JSONObject) metric.getData())` — so `data` **must be a JSON object** — and reads:

- CPU / MEMORY / STORAGE: `getIntValue("payload")` → `gauge.setProgressAnimated(int)` (`CpuHolder.java:28`, `MemHolder.java:27`, `StorageHolder.java:28`); gauge range 0–100 (`common/view/CircularGaugeView.java:68,100`). `getIntValue` accepts a JSON number or a numeric string; `writeProviderContent` (`ScheduledQueryRegistry.java:93-121`) additionally uses `getInteger` to publish to a content provider, so send a plain integer, not a float.
- NETWORK: `getJSONObject("payload")` then `getLongValue("totalReceived")`, `getLongValue("totalSent")` (`NetworkHolder.java:64-65`, `ScheduledQueryRegistry.java:105-107`). Cumulative byte counters; the holder computes `(Δbytes/1024)/Δs` per sample and plots both (`:38-59`). The first reply only seeds the baseline.

`type` inside `data` is not read by the holders but the vendor client echoes it; keep it. `act` in the reply is ignored (the vendor echoes `1000000`).

### Example replies (one per type, render correctly)

```json
{"act":1000000,"id":"sys.push.3f2a9c…","code":200,"data":{"type":"CPU","payload":37}}
{"act":1000000,"id":"sys.push.5b1e07…","code":200,"data":{"type":"MEMORY","payload":62}}
{"act":1000000,"id":"sys.push.9d44c1…","code":200,"data":{"type":"STORAGE","payload":71}}
{"act":1000000,"id":"sys.push.c0ffee…","code":200,"data":{"type":"NETWORK","payload":{"totalReceived":48211234567,"totalSent":9123456789}}}
```

Vendor semantics (official client `OSControllerMac` symbols, `ocl/nm.txt:4650-4670`): CPU = `CpuMonitorMac::getCpuUsage` (whole-machine percent), MEMORY = `getMemoryUsage` (percent used), STORAGE = `getTotalDiskUsagePercent`, NETWORK = `getNetworkTotalReceived/Sent` (all interfaces). Match those semantics in Deckhand.

### Widget definition and `param.data` — CONFIRMED

`common/bean/parameter/ComputerParameter.java` is `{data: String}` and **no code reads it** (no usage outside the bean). The widget can be deployed as:

```json
{"id":"deckhand.cpu","type":"CPU","name":"CPU","icon":"","iconScale":0,"param":{"data":""}}
```

LIKELY: `param` may also be `{}`; keep `{"data":""}` to mirror the vendor. Cards are selected purely by `type`; no custom icon is rendered for these four types.

---

## B. Volume / brightness / mute

### Which push types exist — CONFIRMED

`common/enums/PushType.java`: `ULTRA_KEY, ULTRA_KEY_SET, PC_CONTROL, METRIC, MODULE_STATE, TEST, SET_BRIGHTNESS, GET_BRIGHTNESS, GET_VOLUME, SET_VOLUME, CPU, MEMORY, STORAGE, NETWORK`. **`GET_MUTE` / `SET_MUTE` do not exist on the device.** The official Mac client handles them (`ocl/sec_push.txt:118-119`) but nothing on the CoreBar can emit them; Deckhand may implement them defensively but must not depend on them.

### Request / reply contract — CONFIRMED

`common/module/knob/devices/pc/PcVolumeController.java` (brightness is identical in `PcBrightController.java` with `SET_BRIGHTNESS` / `GET_BRIGHTNESS`):

- Constructor (`:32-36`): `setVolume(0)`, then `getVolumeSync(1000)` and a `Timer` that re-issues `GET_VOLUME` **every 5000 ms** (`:61-71`, first after 500 ms) for as long as the binding is active (destroyed on `unbind` when the profile changes). The latch waits 1 s for the reply but the request itself stays valid 5 s; a late reply still updates the cached value.
- `GET_VOLUME` frame: `{"act":1000000,"data":{"type":"GET_VOLUME"},"id":"sys.push.…"}`. Reply: `data.payload` is read with `getInteger("payload")` (`:125`) → **integer 0–100**. Example: `{"act":1000000,"id":"sys.push.…","code":200,"data":{"type":"GET_VOLUME","payload":45}}`.
- Each knob tick: `onIncrease/onDecrease(stepPercent)` (`:144-159`) mutates the cached value (range 0–100 from `DeviceProperty(…, 0f, 100f)`, `:58`) and sends `SET_VOLUME` with payload `(int) value`: `{"act":1000000,"data":{"type":"SET_VOLUME","payload":47},"id":"sys.push.…"}`. The reply is only checked for arrival/`code 200`; `payload` is ignored (`:46-49`). Echoing `{"type":"SET_VOLUME","payload":47}` like the vendor is harmless. If no reply arrives within 5 s the controller only logs; the device-side value is still updated, so the on-screen dial drifts if the Mac is slow — answer promptly.
- Step size comes from `KnobKeyHelper(1080, 100)` → `KnobEvent.stepPercent` (`common/module/base/KnobBaseModule.java:43`, `knob/interfaces/KnobSdkAdapter.java:20`); the dial UI opens on first tick and auto-closes after 3 s (`knob/manager/KnobControlManager.java`).
- Brightness: the vendor macOS binary's `OSControllerMac::getBrightness()` and `setBrightness(int)` share one address `0x1001e0f08` = `mov w0,#0; ret` (`uws-arm64.asm`, `ocl/nm.txt:4652-4654`). PC_BRIGHT therefore never worked with the vendor client on macOS; Deckhand can implement it (DisplayServices / CoreDisplay) and will be the first to do so.

### Knob binding inside the profile `module[]` entry — CONFIRMED

`ConfigChange.java:80-82` reads a KNOB_KEY module's `config` as `KnobConfig.Detail` directly (not wrapped in `detail`): `{button: KeyCodeConfig, clockwise: KnobDevice, counterclockwise: KnobDevice}` (`common/module/knob/KnobConfig.java:11-15`), `KnobDevice = {id: String, type: ModalType}` (`common/bean/KnobDevice.java`), `ModalType ∈ {AUDIO_PLAYER, LIGHT_TEMP, LIGHT_HS, LIGHT_HS_TEMP, AC, CURTAIN, FAN, PC_VOLUME, PC_BRIGHT, LOCAL_VOLUME, LOCAL_BRIGHT}`. `ModuleConfig` is `{productId, serialNo, config}` (`common/bean/profile/ModuleConfig.java`), `productId` accepted as the enum name string or the integer value (`QLinkProductIdDeserializer.java:12-34`; `KNOB_KEY = 268435458`, `DOT_KEY = 268435457`, `VIVO_CUBE = 268435459`, `SENSE_CUBE = 268435460`), `serialNo` matched case-insensitively (`ConfigChange.java:108-110`).

The vendor client's UI keys `turnLeft/turnRight → {enabled, deviceName, deviceId, deviceType}` are converted on deploy by `ModuleCommonKnobConfigPanel::getProfileKnobConfig` into `{"id": deviceId, "type": deviceType}` (`uws-arm64.asm 0x10012c150-0x10012c458`: reads `enabled`, `deviceId`, `deviceType`, emits `id`, `type`). `enabled` is not a firmware field. LIKELY: `turnRight → clockwise`, `turnLeft → counterclockwise` (the firmware names are the only ones that matter).

For PC types the `id` is not used to look up a device (`KnobKeyFactory.java:98-101`), but `DeviceManager.getDevice(id)` is still called first inside a try/catch that returns `null` on exception (`:84,109-112`) — so always send a non-null string id. KnobKey push-button keyCode is `0` (official client `uws-arm64.asm 0x10012bce4: mov w0,#0` before `getProfileButtonConfig(int,…)`).

Complete example `module` entry (volume on both directions, button = push `{"deckhand":"mute"}`):

```json
{
  "productId": "KNOB_KEY",
  "serialNo": "<KNOB_SERIAL>",
  "config": {
    "button": {
      "keyCode": 0,
      "singleClick": {
        "show": false, "name": "Mute", "icon": "",
        "actions": [
          {"type": "PC_CONTROL", "id": "1", "name": "Mute",
           "values": [{"id": "1", "value": {"output": 10, "payload": {"deckhand": "mute"}}}]}
        ]
      }
    },
    "clockwise":        {"id": "pc:volume", "type": "PC_VOLUME"},
    "counterclockwise": {"id": "pc:volume", "type": "PC_VOLUME"}
  }
}
```

Use `"type":"PC_BRIGHT"` with `"id":"pc:bright"` for brightness. Mixed (CW volume, CCW brightness) is allowed; the first tick in a direction selects that direction's controller (`KnobControlManager`). Deploy via `BATCH_SAVE_PROFILE 1108` and activate with `TRIGGER_PROFILE_CHANGE 1103`; `ConfigChange` re-binds live on the `SwitchModuleConfigEvent`.

---

## C. DotKey

### Schema — CONFIRMED

`ConfigChange.java:74-76`: a DOT_KEY module's `config` is a JSON array of `KeyCodeConfig` (`common/module/dot/KeyCodeConfig.java` = `{keyCode:int}` + `ModuleClick` `{singleClick, doubleClick, longPress}` of `ClickEvent`). `ClickEvent extends Scene` (`dot/ClickEvent.java`), so each press slot carries the `Scene` fields `{id, name, icon, show, enabled, actions[], conditions[], triggers[]}`; only `name`, `icon`, `show`, `actions` are used by `SceneConfigLoader.loadScene` (`common/scene/utils/SceneConfigLoader.java:6-29`): empty `actions` → the slot is removed; `show`/`name`/`icon` drive the on-screen prompt; `enabled` is **not consulted**. The scene is registered as `SceneType.MODULE` with id `<profileId>:<moduleUid>:dot_key_<keyCode>_<CLICK|DOUBLE_CLICK|LONG_PRESS>` (`ModuleIdGen.java`, `ActionExecutorV2.java:70-78`) and executed via `SceneManager.startScene` on the matching gesture (`ActionExecutorV2.java:79-88`; it also fires `ExitScreensaver`).

keyCodes are 16-bit values from the module firmware (`quantum/link/device/QLinkDevKeyboard.java:32-44`); the vendor client assigns **button1 → 2, button2 → 1, button3 → 0** (`uws-arm64.asm 0x100124648-0x1001246cc`: compare `"button1"` → `w22=2`, `"button2"` → `cset`=1, else 0; `w22` is then the `int` argument of `ModuleCommonKeyConfigPanel::getProfileButtonConfig(int, json)` at `0x100124730-0x100124738`). Which physical key is "button1" is a vendor-UI convention — LIKELY left round key; verify on hardware with one test profile.

`ActionConfig` (`com/ultrabar/smart/bean/ActionConfig.java`) = `{id, name, type: ActionType, values: [{id, value}], objectParams}`; `ActionValue` is `{id, value}` (`smart/bean/ActionValue.java`) — the vendor's internal `param` naming does not reach the wire (its deploy builders emit `values`/`value`, `ocl/annot3.txt:5172-5185`). `getValueToStr` casts to `String`, `getValueToInt` casts to `Integer`, so value JSON types must match the consumer.

### The three ActionConfig shapes — CONFIRMED

1. **VIVO_CUBE_TOGGLE** (`common/scene/action/ViVoCubeToggleAction.java` → `BaseAction.control` → `common/scene/operation/ViVoCubeOperation.java:21-24`): `actionConfig.id` must be the VivoCube **endpoint uid** (device registered with `Module.getId()` = endpoint `uid` from `canGateway.endpoints[]`, `VivoCubeModule.java:84-91`, `quantum/link/product/QLinkProductFactory.java:49-51`; the vendor sets `uid = serialNumber` on 30300, so normally the module serial). Values: `"1"` = layer id, `"2"` = widget id, both **JSON strings** (`Integer.parseInt(getValueToStr(...))`). Result: `TOGGLE_LAYER` command = property 9 `(layer<<16)|widget`.
2. **PC_CONTROL** (`common/scene/action/PcControlAction.java:7-26`): value `"1"` is a `ParentControlParameter` object: `{"output":10,"payload":<any JSON>}` → `GatewayHub.push(PushMessage.pcControl(payload))`, or `{"output":5,"keys":[<HID usage ids>]}` → USB-HID keystroke. (Quirk: the HID branch reports "Invalid hotkey action" even on success; harmless.) `id`/`name` are free; the vendor uses `id:"1"`.
3. **CHANGE_PROFILE** (`common/scene/action/ProfileChangeAction.java:5-17`): value `"1"` = profile id string (must exist in the saved profiles, else `profile id … not exist`); the vendor catalogue uses `id:"profile"`.

Other useful ActionTypes (all registered, `SceneEngineInitializationTask.java:86`): `DELAY` (value `"1"` = integer seconds), `BRIGHT` (CoreBar brightness, `id:"corebar"`), `ACTIVITY` (`id:"activity"`, value `"1"` = package), `TIMER` (value `"1"` = timer widget id, `"2"` = `START|PAUSE|RESUM|CANCEL|RESTART`), `SCENE` (`id` = scene id, value `"sid"`), `VOLUME` (local). `START_SCREEN`/`CLOSE_SCREEN`/`HOT_KEY` are enum values with no handler.

### Complete DotKey example — button1 → VivoCube layer 1, button2 → layer 2, button3 → push `{"deckhand":"next"}`

```json
{
  "productId": "DOT_KEY",
  "serialNo": "<DOTKEY_SERIAL>",
  "config": [
    {
      "keyCode": 2,
      "singleClick": {
        "show": false, "name": "Layer 1", "icon": "",
        "actions": [
          {"type": "VIVO_CUBE_TOGGLE", "id": "<VIVOCUBE_UID>", "name": "Layer 1",
           "values": [{"id": "1", "value": "1"}, {"id": "2", "value": "101"}]}
        ]
      }
    },
    {
      "keyCode": 1,
      "singleClick": {
        "show": false, "name": "Layer 2", "icon": "",
        "actions": [
          {"type": "VIVO_CUBE_TOGGLE", "id": "<VIVOCUBE_UID>", "name": "Layer 2",
           "values": [{"id": "1", "value": "2"}, {"id": "2", "value": "102"}]}
        ]
      }
    },
    {
      "keyCode": 0,
      "singleClick": {
        "show": true, "name": "Next", "icon": "deckhand/next.png",
        "actions": [
          {"type": "PC_CONTROL", "id": "1", "name": "Next",
           "values": [{"id": "1", "value": {"output": 10, "payload": {"deckhand": "next"}}}]}
        ]
      },
      "longPress": {
        "show": false, "name": "Page", "icon": "",
        "actions": [
          {"type": "CHANGE_PROFILE", "id": "profile", "name": "Deckhand page",
           "values": [{"id": "1", "value": "deckhand"}]}
        ]
      }
    }
  ]
}
```

The Mac receives, for button3: `{"act":1000000,"data":{"type":"PC_CONTROL","payload":{"deckhand":"next"}},"id":"sys.push.…"}`; reply `{"act":1000000,"id":"<same>","code":200,"data":{"type":"PC_CONTROL"}}` or simply ignore (the scene action does not wait for an ack: `GatewayHub.push(PushMessage)` uses a no-op `PublishResult`, `GatewayHub.java:116-122`).

---

## D. On-device automation for rotation

### Trigger catalogue — CONFIRMED

`SceneRegistry.addTriggerFactory(new DeviceStateTrigger(), new ProfileTrigger(), new AppStateTrigger())` (`common/init/SceneEngineInitializationTask.java:86`); `SCENE_GET_TRIGGER_PARAM 30700` just returns `SceneRegistry.getMeta()` (`TriggerParamMessage.java`). The whole APK contains exactly four `AbstractTriggerFactory` subclasses (`common/scene/auto/trigger/*`), and `NumericTrigger.createInstance` returns `null` and is not registered:

| `triggers[].type` | `params` | semantics |
|---|---|---|
| `DEVICE_STATE` | `{"id":"<device id>","property":"state","from":"UNOCCUPIED","to":"OCCUPIED"}` | state change of an IoT/SenseCube device (`DeviceStateTrigger.java:23-36`) |
| `PROFILE` | `{"from":"<profile id or null>","to":"<profile id or null>"}` | profile switch; a null side is a wildcard (`ProfileMatcher.java:39-44,58-90`) |
| `APP_STATE` | `{"package":"<pkg>","in":<bool>}` | app enters/leaves foreground (`AppStateTrigger.java:12-22`) |

Optional `duration` on a trigger is `"HH:MM:SS"` hold time (`com/ultrabar/smart/scene/tracker/DurationContext.java:29-36`). Conditions registered: `DEVICE_STATE` (`{id, property, value}`), `AND`, `OR`, `NOT` only. `TimeRangeCondition` (`TIME_RANGE`, `{startTime, endTime}`) exists in `common/scene/auto/condition/` but is **not registered**; `ConditionRegistry.get` throws on unknown types (`smart/scene/register/ConditionRegistry.java:18-23`), which aborts the scene — do not use it.

**There is no time-of-day, interval, periodic or cron trigger. No `AlarmManager`, scheduler or clock reference exists in the scene packages.** "Every N minutes → VIVO_CUBE_TOGGLE next layer" and "at 08:00 → CHANGE_PROFILE" cannot be expressed in `BATCH_CREATE_SCENE 30500`. Also: act `1204 SCENE_TRIGGER` is declared but not mapped to a handler (`MessageFactory.java` has no entry), so there is no "run scene X" request either.

### What the Mac must do instead (one frame per event)

- Layer rotation: `MODULE_PROPERTY_WRITE 30201` writing property 9 `(layer<<16)|widget` on the VivoCube (see `vivocube-findings.md` §D), or `1103` to switch CoreBar pages at 08:00. Both are fire-and-forget single lines over the already-open socket.
- If a VivoCube layer change should also happen on a DotKey press or on presence, bind it on-device via C/D above; the Mac only owns the clock.

### The one on-device periodic primitive (HYPOTHESIS — needs hardware test)

The countdown TIMER card is handled inside the launcher (`common/extension/timer/CountDownTimerManager.java`), not in a separate app: `TimerHolder.updateUI` registers the timer with `param.time`, `startSceneId`, `endSceneId` (`TimerHolder.java:221`); on `FINISHED` the global listener shows a system alarm banner **and** runs `SceneManager.startScene(endSceneId)` (`common/init/TimerInitializationTask.java:36-55`); the `TIMER` action with values `"1"` = timer widget id, `"2"` = `"RESTART"` restarts it (`TimerAction.java`, `EventSourceInitializationTask.java:100-118`). A MANUAL scene in the 30500 list (`{"id":"rot","type":"MANUAL","enabled":true,"actions":[VIVO_CUBE_TOGGLE…, {"type":"TIMER","id":"sc.timer","values":[{"id":"1","value":"deckhand.timer"},{"id":"2","value":"RESTART"}]}]}`) referenced as `endSceneId` would loop without the Mac, but (a) the alarm banner/sound fires every cycle, (b) the TIMER card must stay on the visible profile, (c) VIVO_CUBE_TOGGLE is a fixed layer per scene so "next" needs N chained timers. Not recommended; listed for completeness.

---

## E. WORLD_TIME `param.offset`

`WorldTimeParameter` = `{offset: String}` (`common/bean/parameter/WorldTimeParameter.java`); `WorldTimeHolder.updateUI` passes it to `UtcAnalogClockView.setGmtOffset` and shows `name` as the label (`WorldTimeHolder.java:16-30`). Parser (`common/view/UtcAnalogClockView.java:522-552`) — CONFIRMED:

1. trim, upper-case, remove `GMT` and `UTC`, trim; empty → offset 0;
2. optional leading `+`/`-`; `-` makes it negative;
3. `H:MM` (split on `:`) or `H`; minutes default 0; `Integer.parseInt` on each part (so `"+1.5"` or `"Europe/Amsterdam"` throws → card renders UTC/last value).

Accepted: `"GMT+1:00"`, `"GMT+1"`, `"+1"`, `"1"`, `"UTC-5:00"`, `"-05:30"`, `"+5:30"`. The vendor default is `"GMT+0:00"` (`ocl/annot3.txt:11849 CoreBarCardBasicWorldClockEditor::onSaveEdit`); use that style. Fixed offsets only — no DST; Deckhand should compute the current offset from the IANA zone and redeploy when it changes (twice a year).

```json
{"id":"deckhand.ams","type":"WORLD_TIME","name":"Amsterdam","icon":"","iconScale":0,"param":{"offset":"GMT+1:00"}}
{"id":"deckhand.nyc","type":"WORLD_TIME","name":"New York","icon":"","iconScale":0,"param":{"offset":"GMT-5:00"}}
```

(Amsterdam `GMT+2:00` and New York `GMT-4:00` during DST.) 12/24 h follows the device setting (`SettingsNetworkTime.is24HourFormat`).

---

## F. PC_CONTROL card as an "image card" (and HOT_KEY_GROUP)

### Widget JSON — CONFIRMED

Widget fields (`common/bean/ProfileProperty.java` + `HomeData.java`): `{id, type, name, icon, iconScale, bgColor, param}`. `PcControlHolder.updateUI` (`PcControlHolder.java:64-87`) parses `param` with `ParentControlParameter.from` (`{output:5, keys[]}` → `KeyboardParamter`, else `ControlParamter {output, payload}`; `bean/parameter/control/*.java`), shows `name`, loads `icon` through `GlideExtend.loadSmartAsBitmap` and scales it to a 265 px canvas by `iconScale/100` (`:37`). Icon resolution (`common/utils/GlideExtend.java:112-134`): http(s) URL → network; `resId://name` → drawable; anything else not starting with `file://` or `/` → `new File(getExternalFilesDir(null), icon)` if it exists, i.e. **a path relative to the launcher's external files dir**, which is where `/upload/zip?subDir=deckhand` extracts (see `corebar-pages-findings.md`). Default icon when empty: `Constants.PC_CONTROL_WIDGET_DEF_ICON` (a CDN PNG).

Press handling (`common/utils/HomeDeviceHolderListener.java:186-200`): `output == 10` → on `TAP` and on `LONG_PRESS_DOWN` push `PushMessage.pcControl(payload)` and play the click sound; `output == 5` → HID key events (TAP, LONG_PRESS_DOWN with 700 ms heartbeat, LONG_PRESS_RELEASE).

```json
{
  "id": "deckhand.next",
  "type": "PC_CONTROL",
  "name": "Next",
  "icon": "deckhand/next.png",
  "iconScale": 80,
  "param": {"output": 10, "payload": {"deckhand": "next", "arg": 1}}
}
```

What the Mac receives: `{"act":1000000,"data":{"type":"PC_CONTROL","payload":{"deckhand":"next","arg":1}},"id":"sys.push.<32 hex>"}`, delivered to **all** connected clients (see G). No reply is required (no-op `PublishResult`), but answering `code:200` is harmless. A long press delivers the same push once (on press-down), not repeatedly.

HID variant: `"param":{"output":5,"keys":[227,44]}` (USB usage ids, e.g. GUI+Space); executed by the hub over USB without involving the Mac client.

### HOT_KEY_GROUP child schema — CONFIRMED

`param = {"button":[RemoteChildren…]}` (`bean/parameter/HotKeyGroupParamter.java`); each child is a `HomeData` plus `spanSize` (`ui/.../RemoteChildren.java`): `{"id","type":"PC_CONTROL","name","icon","iconScale","spanSize":1|2,"param":{output,payload|keys}}`. The group card shows `name`/`icon` (`HotKeyGroupHolder.java:69-91`) and opens `RemoteActivity`, where each child press runs the same output 5/10 logic (`RemoteActivity.java:45-58`). Useful for a 2×N grid of image buttons behind one card.

---

## G. Persistent connection

Server: module hub `NettyServer` (`bridge-src/.../hub/server/tcp/NettyServer.java:71-84,97,116-117`), TLS 1.3 only (`SslProtocols.TLS_v1_3`, self-signed `ssl/server.crt`), pipeline `SslHandler → IdleStateHandler(30, 40, 60, SECONDS) → LineBasedFrameDecoder(1048576) → StringDecoder/LineEncoder(UTF-8) → TokenAuthHandler → ChannelHandler → HeartbeatHandler`; `TCP_NODELAY`, `SO_KEEPALIVE` on. Replies always end with `\n` (`TCPConnection.java:42-54,86-89`). CONFIRMED.

### Heartbeat — CONFIRMED

Vendor frame: `{"act":20,"id":"<decimal counter>"}` with no `data`, every 3 s when ≥ 1.5 s since last RX (`official-client-findings.md` §1, `CoreBarDevice::onTimer`; `uws-arm64.asm 0x1001a8334 mov w8,#0x14`). The hub relays it to the launcher like any business frame (10 s relay timeout, `BusinessProcessor.java:213-227`); `HeartbeatMessage` replies `success(iReply)` (`common/communication/message/generic/HeartbeatMessage.java`), i.e. `{"act":20,"code":200,"data":"success","id":"<same>","timestamp":1761900000000}` (`Response.java:19-25`, `AbstractBaseMessage.java:39-40`).

### Idle timeout — CONFIRMED

`HeartbeatHandler.userEventTriggered` (`hub/server/tcp/handler/HeartbeatHandler.java:39-55`): `READER_IDLE` (30 s without a read) and `WRITER_IDLE` (40 s without a write) only log; **`ALL_IDLE` (60 s with neither read nor write) closes the connection** (`connection.close()` or `ctx.close()`). Because server pushes count as writes, a client that only receives metric polls would stay alive, but a client with no cards and no knob bindings is dropped after 60 s of silence. Send the heartbeat every ≤ 20 s (vendor: 3 s). Before authentication `TokenAuthHandler.channelRead0V1` closes the socket on any act other than 100 (`AUTH`) / 101 (`REQ_AUTH_TOKEN`) and on malformed JSON (`TokenAuthHandler.java:287-305`); after `auth_ok` the handler removes itself (`:50-53`).

### Who receives PUSH_MESSAGE — CONFIRMED

Launcher → hub: `GatewayHub.push` → `MessageChannelImpl.send` publishes the frame with `Target.CLIENT_REPLY` (`openapi/integration/tcp/MessageChannelImpl.java:39-40`). Hub: `BusinessProcessor.onDataFlow` → `ConnectManager.getInstance().broadcast(str2)` (`hub/server/tcp/processor/BusinessProcessor.java:132-140`), which writes to **every** entry in `activeConnections` (`hub/connect/manager/ConnectManager.java:144-152,69-75`); `TCPConnection.isAlive()` is hard-coded `true`. Connections are registered on `auth_ok`/token creation (`TokenAuthHandler.java:53,141 → onNewConnect → getOrCreateConnection`) and on first business frame (`NettyServer.java:58`). There is no "most recent client" or "authenticated-owner" selection: with two Macs connected, both get every `GET_VOLUME`, `CPU`, `PC_CONTROL`; the launcher accepts the **first** `code:200` frame whose `id` matches (`AckTimeoutCoordinator.completeV2`), later duplicates are dropped. Request replies (1108, 1103, 30201, 20, …) are unicast to the requesting socket (`BusinessProcessor.java:109-115`, `connection.send`). Broadcast `forward` events (e.g. module online pushes, act-coded `Response` via `msgChannel().broadcast`) likewise reach every client. Max 10 authorized devices (`TokenAuthHandler.java:39,61-62`).

Deckhand implications: run exactly one session per Mac; if several Deckhand/vendor instances connect, pick a deterministic responder (e.g. only the instance whose profile is active) or accept that the fastest answer wins; treat `code:200` replies by `id` only.

---

## Ready-to-paste Swift dictionary fragments

```swift
// Metric reply (data must be an object; payload int 0...100, NETWORK = cumulative bytes)
["act": 1000000, "id": reqId, "code": 200, "data": ["type": "CPU", "payload": 37]]
["act": 1000000, "id": reqId, "code": 200, "data": ["type": "NETWORK", "payload": ["totalReceived": rx, "totalSent": tx]]]
// Volume
["act": 1000000, "id": reqId, "code": 200, "data": ["type": "GET_VOLUME", "payload": 45]]
["act": 1000000, "id": reqId, "code": 200, "data": ["type": "SET_VOLUME", "payload": 47]]
// Heartbeat (≤ 20 s)
["act": 20, "id": nextId()]
// Knob module
["productId": "KNOB_KEY", "serialNo": knobSerial, "config": [
    "clockwise": ["id": "pc:volume", "type": "PC_VOLUME"],
    "counterclockwise": ["id": "pc:volume", "type": "PC_VOLUME"]]]
// VivoCube toggle action (values are strings)
["type": "VIVO_CUBE_TOGGLE", "id": vivoUid, "name": "Layer 1",
 "values": [["id": "1", "value": "1"], ["id": "2", "value": "101"]]]
// PC_CONTROL action / card param
["output": 10, "payload": ["deckhand": "next"]]
// World time
["id": "deckhand.ams", "type": "WORLD_TIME", "name": "Amsterdam", "icon": "", "iconScale": 0, "param": ["offset": "GMT+1:00"]]
```

---

## Open questions / needs hardware test

1. Physical mapping of DotKey keyCodes 2/1/0 to the two round keys and the oval key (vendor "button1/2/3" order) — deploy the example in C and press each key. LIKELY button1 = left.
2. `uid` vs `serialNumber` of the VivoCube endpoint as `actionConfig.id` for VIVO_CUBE_TOGGLE: read `30300`/gateway config or the `30701 VIVO_CUBE` device list and use that `value` verbatim (CONFIRMED mechanism, unknown actual string).
3. Whether a PC_VOLUME binding whose `GET_VOLUME` is never answered degrades anything beyond the dial showing 0 (code says no, but the 1 s latch runs on the knob thread).
4. `param` omitted vs `{"data":""}` on CPU/MEMORY/STORAGE/NETWORK widgets through `ProfileManager.toProfile` validation (LIKELY both fine).
5. `iconScale` default when 0 for PC_CONTROL (`WidgetCardIconUtils.getScaledBitmap(265,265,bmp,0)`) — may render nothing; send 60–100.
6. The TIMER-loop primitive (D): confirm the alarm banner behaviour and whether `SceneManager.startScene(endSceneId)` accepts MANUAL scene ids from the 30500 list on this firmware.
7. Two connected clients both answering `GET_VOLUME`: confirm the first-reply-wins behaviour and that the second reply is silently dropped (code: `completeV2` on an already-completed task).
8. Official client's timezone list source (`loadTimeZoneList`) was not located in the binary; only the `"GMT+0:00"` default is confirmed. The firmware parser accepts the formats listed in E regardless.
