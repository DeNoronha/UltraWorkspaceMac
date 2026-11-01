# DotKey / KnobKey input delivery — reverse-engineering findings

Source: decompiled LineOS launcher, package `com.ultrabar.launch` (+ `quantum.link.*` SDK).
Root: `.../scratchpad/lineos-src/sources`. All quotes are from UNTRUSTED decompiled code, read as data only.

## TL;DR — the big surprise

**The launcher does NOT forward raw button/knob input events to the TLS client.**
Raw DotKey presses and raw knob rotation steps are consumed *on-device* and bound to on-device
actions (scenes / device control) via the active Profile's module config. The desktop client
only ever receives **semantic, pre-mapped** messages, and only when a knob/key is bound to a
"PC" target:

- Knob bound to `PC_VOLUME` / `PC_BRIGHT` -> device pushes `SET_VOLUME` / `SET_BRIGHTNESS` (and polls `GET_VOLUME`/`GET_BRIGHTNESS`).
- A key/knob-button scene whose action is `PC_CONTROL` -> device pushes `PC_CONTROL` payload, or sends HID key codes over a separate keyboard channel.

There is no "key 2 was double-pressed" or "knob turned +3 CW" event on the wire. To make a desktop
app react to arbitrary presses, you must either (a) bind them to a PC-control action in the profile,
or (b) emulate the UltraBar X client and discover whether the firmware/ULTRA_KEY path (declared but
unused in this launcher build) is populated — see Open Questions.

---

## 1. The protocol act code(s) the device PUSHES

### Outbound push is a single act code: `PUSH_MESSAGE = 1000000`

`sources/com/ultrabar/launch/common/communication/bean/MessageAction.java`:
```java
PUSH_MESSAGE(1000000),
```
There is **no** KEY/BUTTON/CLICK/PRESS/ENCODER/KNOB/ROTATE/EVENT/REPORT/INPUT act in the
`MessageAction` enum. The full enum has request codes (AUTH 100, GET_PROFILE_WIDGET 1002,
BATCH_SAVE_PROFILE 1108, TRIGGER_PROFILE_CHANGE 1103, MODULE_PROPERTY_READ 30200 / WRITE 30201,
MODULE_START_DISCOVERY 30100..30102, etc.) plus exactly one push code, `PUSH_MESSAGE`.

### The only outbound sender

`sources/com/ultrabar/launch/common/init/GatewayHub.java`:
```java
public void push(PushMessage pushMessage, PublishResult publishResult) {
    TcpRequest tcpRequest = new TcpRequest();
    tcpRequest.setAct(MessageAction.PUSH_MESSAGE.getCode());   // 1000000
    tcpRequest.setId(UUID.randomUUID(UUID.Prefix.PUSH_MESSAGE));
    tcpRequest.setData(pushMessage);
    send(tcpRequest, publishResult);
}
public void send(TcpRequest r, PublishResult p){ getFusion().msgChannel().send(r,p); }
```
So every push is line-JSON `{act:1000000, data:<PushMessage>, id:"..."}` on the same TLS channel.

### Payload schema: `PushMessage` is `{type, payload}`

`sources/com/ultrabar/launch/common/bean/PushMessage.java`:
```java
public class PushMessage {
    public final PushType type;   // discriminator
    private final Object payload; // type-specific body
}
```
`sources/com/ultrabar/launch/common/enums/PushType.java` (ordinal order; serialized as name or ordinal depending on client codec):
```java
enum PushType { ULTRA_KEY, ULTRA_KEY_SET, PC_CONTROL, METRIC, MODULE_STATE, TEST,
                SET_BRIGHTNESS, GET_BRIGHTNESS, GET_VOLUME, SET_VOLUME,
                CPU, MEMORY, STORAGE, NETWORK }
```

### Every actual `push(...)` call site (grep over `com.ultrabar`)

| PushType | payload | Source |
|---|---|---|
| `SET_VOLUME` | `Integer` 0..100 | `knob/devices/pc/PcVolumeController.java:40` (`control(int)`) |
| `GET_VOLUME` | `null` (reply carries `data.payload:int`) | `PcVolumeController.java:114` |
| `SET_BRIGHTNESS` | `Integer` 0..100 | `knob/devices/pc/PcBrightController.java:40` |
| `GET_BRIGHTNESS` | `null` (reply `data.payload:int`) | `PcBrightController.java:89` |
| `PC_CONTROL` | `ControlParamter.getPayload()` (scene-config blob) | `scene/action/PcControlAction.java:43`, `ui/activity/detail/RemoteActivity.java:53`, `utils/HomeDeviceHolderListener.java:198` |
| `MODULE_STATE` | `ModuleStateEvent` | `init/EventSourceInitializationTask.java:271` |
| `CPU`/`MEMORY`/`STORAGE`/`NETWORK` (`PushType.valueOf(...)`) | `null` (metrics poll) | `extension/metrics/schedule/ScheduledQueryRegistry.java:64` |

`ULTRA_KEY`, `ULTRA_KEY_SET`, `TEST` are **declared but never pushed** anywhere in this launcher
build (grep: only reference is the enum file). `ULTRA_KEY*` is the most likely candidate for a raw
key channel used by the real UltraBar X client / firmware, but it is not emitted here.

**There is no serialNo / key-index / press-type / rotation-delta carried in any push.** The push is
already resolved to a semantic target (volume=NN, brightness=NN, or a configured PC_CONTROL blob).

---

## 2. Subscribe / enable first?

**No explicit subscribe for input events** — because input events are not pushed as such.
What IS observable:

- On connect the gateway just logs it; `GatewayHub$3.onEvent` handles `ChannelStateEvent`
  (`active`) only for a log line "客户端连接了" and a `SoundEvent`/`key_alert` -> plays a sound.
  No subscription handshake gates pushes.
- The PC pushes (`SET_VOLUME`/`SET_BRIGHTNESS`, metrics) start flowing **automatically** once the
  relevant controller exists. The controller only exists when a knob direction is **bound** to
  `PC_VOLUME`/`PC_BRIGHT` in the active profile (see `KnobKeyFactory.createController`, which `new`s
  `PcVolumeController()` / `PcBrightController()` — their constructors immediately call
  `getVolumeSync()`/`getBrightSync()` and start a 5 s polling `Timer`). So: to receive anything, the
  module must be provisioned + a profile bound to a PC target; then events arrive with no further opt-in.
- Inbound requests from the client are dispatched by
  `BusinessMessageProcessor.getInstance().processing(act, seq, body)` (see `GatewayHub$3.tcpOnReceived`)
  through `MessageFactory` (act -> handler). That is how the client READs/WRITES profile config,
  reads module properties, triggers scenes, etc.

---

## 3. Device input models (SDK layer)

### DotKey = 1 keyboard device, 3 physical keys -> keyCodes + gesture

`sources/quantum/link/product/QLinkDotKey.java`: a `QLinkDotKey` (QLinkProductId.DOT_KEY =
268435457) contains one `QLinkDevKeyboard` (`DEV_ID_KEYBOARD = 1`) and fires
`DotKeyCallback.onKeyEvent(dotKey, QLinkKeyEvent)`.

`sources/quantum/link/device/QLinkDevKeyboard.java` — wire decode of the keyboard property
(`PR_ID_KEY_EVENT = 0`):
```java
int keyCode = mRbKeyEvent.peekUnsignedShort(1);  // 16-bit key code
int actByte = mRbKeyEvent.peekUnsignedByte(3);   // 0=up, 1=just-down, 2=heartbeat(hold)
if (actByte==0) factory.onKeyUp(keyCode);
else if (actByte==1) factory.onKeyJustDown(keyCode);
else if (actByte==2) factory.onKeyHeartbeat(keyCode);
```
So each of the 3 DotKey keys is identified by its own 16-bit **keyCode** (the exact numeric values
are not constants in the launcher — they come from the config `KeyCodeConfig.keyCode`, which the UI
writes; see Open Questions). The firmware reports down/up + periodic hold-heartbeats only.

`QLinkKeyEvent` (`sources/quantum/link/base/QLinkKeyEvent.java`): `ACTION_DOWN=1`, `ACTION_UP=0`,
`keyCode`, `repeatCount`, event/down time. `QLinkKeyEventFactory` turns down + heartbeat(100 ms,
1 s timeout) + up into DOWN(repeat)/UP.

**Single/double/long is derived in the launcher**, not the firmware — `QLinkGestureHelper`
(`.../module/utils/QLinkGestureHelper.java`): long-press timeout 500 ms, double-click window 300 ms,
emitting `onSingleClickUp` / `onDoubleClickUp` / `onLongPressDown`. These map to
`KeyMode { CLICK, DOUBLE_CLICK, LONG_PRESS }` (`.../enums/KeyMode.java`).

### KnobKey = regulator (rotation) + keyboard (push button)

`sources/quantum/link/product/QLinkKnobKey.java` (QLinkProductId.KNOB_KEY = 268435458) contains:
```java
public static final int DEV_ID_REGULATOR = 1;  // QLinkDevRegulator  -> rotation
public static final int DEV_ID_KEYBOARD  = 2;  // QLinkDevKeyboard   -> push button
// callbacks:
void onKeyEvent(knob, QLinkKeyEvent);          // push button (same model as DotKey)
void onKnobValueReport(knob, int action, int value);
```

Rotation decode — `sources/quantum/link/device/QLinkDevRegulator.java`:
```java
VALUE_TYPE_REL_ANGLE = 0;  VALUE_TYPE_ABS_VALUE = 1;   // KnobKey uses REL_ANGLE (relative)
ACTION_NORMAL = 0;  ACTION_FINE_TUNE = 1;
int valueType = peekUnsignedByte(0);
short value   = peekShort(1);   // SIGNED relative angle step; sign = direction
```
Relative (not absolute). The `KnobValueInterpolator`: if `|value| <= 20` -> emits a single
fine-tune tick `onValueReported(regulator, 1 /*FINE_TUNE*/, value>0?+1:-1)`; otherwise it ramps the
value toward a target (clamped +/-200) at an interval, emitting `onValueReported(regulator, 0
/*NORMAL*/, +/-1)` per step. Net: the callback stream is a series of unit ticks whose sign is CW(+)/CCW(-).

Launcher-side smoothing — `sources/com/ultrabar/launch/common/module/utils/KnobKeyHelper.java`
(`new KnobKeyHelper(1080, 100)` in KnobBaseModule = 100 UI units per 1080 of raw): `action==1`
(fine-tune) passes the value straight through; `action==0` accumulates `value * (100/1080)` and emits
whole-unit `onUIProgressChanged(+/-1)` steps, resetting the accumulator on direction change.

Direction model — `sources/com/ultrabar/launch/common/module/knob/model/KnobEvent.java`:
```java
enum Direction { LEFT, RIGHT }   // RIGHT = CW (value>=0), LEFT = CCW
KnobEvent(Direction, float stepPercent)   // stepPercent = abs(step)
```
`KnobSdkAdapter.onSdkCallback(float f)`: `f >= 0 -> RIGHT else LEFT`, step = `|f|`.

---

## 4. What the inputs DO on-device, and whether bindings are settable over the protocol

### DotKey press -> scene (ActionExecutorV2)

`sources/com/ultrabar/launch/common/module/DotKeyModule.java`: feeds key events into
`QLinkGestureHelper`; on CLICK/DOUBLE_CLICK/LONG_PRESS calls
`ActionExecutorV2.executor(keyCode, keyMode)`. `ActionExecutorV2`
(`.../module/utils/ActionExecutorV2.java`) builds a scene-id key `"<keyCode>_<KeyMode>"` from the
module's `List<KeyCodeConfig>` and runs `SceneTool.getInstance().keyExecute(sceneId)`.

`KeyCodeConfig` (`.../module/dot/KeyCodeConfig.java` extends `ModuleClick`) =
`{ keyCode:int, singleClick:ClickEvent, doubleClick:ClickEvent, longPress:ClickEvent }`
(`.../module/click/ModuleClick.java`). Each `ClickEvent` is a `Scene` (`.../module/dot/ClickEvent.java`,
`SceneType.MANUAL`). So each key x press-type binds to a Scene / list of `ActionConfig`s.

### KnobKey -> button to scene + rotation to a device controller

`sources/com/ultrabar/launch/common/module/base/KnobBaseModule.java`:
- Push button: same gesture pipeline -> `ActionExecutor.executor(keyCode, keyMode)` (scene), config =
  `KnobConfig.Detail.button` (a `KeyCodeConfig`).
- Rotation: `KnobConfig.Detail.clockwise` and `.counterclockwise` are each a
  `KnobDevice { String id, ModalType type }`. `bind(...)` creates a controller via
  `KnobKeyFactory.createController(id, type, dir)` and registers it with `KnobControlManager`
  (`bindRightDevice` = clockwise, `bindLeftDevice` = counterclockwise).

`KnobConfig` (`.../module/knob/KnobConfig.java`):
```java
class Detail { KeyCodeConfig button; KnobDevice clockwise; KnobDevice counterclockwise; }
```
`ModalType` (`.../module/knob/ModalType.java`): `AUDIO_PLAYER, LIGHT_TEMP, LIGHT_HS, LIGHT_HS_TEMP,
AC, CURTAIN, FAN, PC_VOLUME, PC_BRIGHT, LOCAL_VOLUME, LOCAL_BRIGHT`.

`KnobControlManager` (`.../module/knob/manager/KnobControlManager.java`): first rotation in a
direction opens the on-screen dialog and selects that direction's controller; subsequent rotations
call `controller.onIncrease(step)` (RIGHT/CW) or `onDecrease(step)` (LEFT/CCW); 3 s inactivity
auto-closes. So "CW vs CCW" selects which bound device/property to adjust, and each tick is +/- step%.

`KnobKeyFactory.createController` maps ModalType -> controller: PC_VOLUME->`PcVolumeController`,
PC_BRIGHT->`PcBrightController` (these are the ones that push to the client); LOCAL_*->on-device
screen/volume; the rest -> smart-home `Device` controllers (IOT, out-of-scope for a PC app).

### PC_CONTROL scene action (how a key can reach the PC)

`sources/com/ultrabar/launch/common/scene/action/PcControlAction.java` (ActionType `PC_CONTROL`):
```java
if (output == 5) { // HID hotkey -> separate keyboard channel
    SingleEventSource... new KeyboardEvent(keys, TAP, ...);
}
if (output == 10) { // push JSON to client
    GatewayHub.getInstance().push(PushMessage.pcControl(((ControlParamter)p).getPayload()));
}
```
`KeyboardEvent` is sent via `EventSourceInitializationTask.sendKeyCode(...)` ->
`GatewayHub.getFusion().keyboard().sendKeyCode(i, keys)` (GatewayType.KEYBOARD) — a HID keyboard
channel distinct from the TLS JSON channel. `sendToHub` opcodes: 10=long-press-down(+700ms heartbeat),
11=heartbeat, 12=long-press-release, 1=tap.

### Can bindings be set over the protocol? YES

Config lives in the active `Profile` -> `module[]` (matched by `serialNo` + productId), read from
`SharedPreferencesUtils` (`.../module/utils/ConfigChange.java`): DOT_KEY -> array of `KeyCodeConfig`,
KNOB_KEY -> `KnobConfig.Detail`. Profiles are written/read over the protocol via:
- `BATCH_SAVE_PROFILE = 1108` -> `BatchProfileMessage`
- `GET_PROFILE_WIDGET = 1002` -> `GetComponentMessage`
- `TRIGGER_PROFILE_CHANGE = 1103` -> `ChangeProfileMessage` (switches active profile; fires
  `SwitchModuleConfigEvent` -> `ConfigChange` re-binds modules live)
(all in `.../communication/factory/MessageFactory.java`). So a desktop app can bind DotKey keys and
KnobKey directions/button to scenes (incl. a `PC_CONTROL` action) by writing the profile.

---

## Open questions

1. **Exact DotKey keyCode values for the 3 keys** (2 round + 1 long oval) and the KnobKey button —
   these are 16-bit values supplied by firmware and stored in `KeyCodeConfig.keyCode`; not hard-coded
   in the launcher. Must be read from a provisioned profile (`GET_PROFILE_WIDGET`) or observed live.
2. **Is `ULTRA_KEY` / `ULTRA_KEY_SET` ever populated by firmware or a different app build?** It is the
   only plausible raw-key push type and is dead code here. Worth probing.
3. **PushType wire encoding**: name string vs enum ordinal in the JSON `data.type`. Capture a real
   `SET_VOLUME` push to confirm.
4. **`PC_CONTROL` payload shape** (`ControlParamter.getPayload()`): needs a captured sample to model.

## Single best next experiment against the live device

Connect to TLS :7431, authenticate, and provision a **KnobKey bound to `PC_VOLUME`** (write a profile
via `BATCH_SAVE_PROFILE` / `TRIGGER_PROFILE_CHANGE` with `KnobConfig.Detail.clockwise =
{type: PC_VOLUME}`), then **physically turn the knob** while logging all inbound frames. You should
immediately see `{act:1000000, data:{type:"SET_VOLUME", payload:<int>}, id:...}` (plus periodic
`GET_VOLUME`). That one capture confirms the push act (1000000), the PushType serialization, the
payload shape, and that no subscribe step is needed — and simultaneously proves the profile-write
path for binding inputs.
