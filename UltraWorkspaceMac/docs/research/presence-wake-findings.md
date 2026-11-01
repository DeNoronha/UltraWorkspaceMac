# Presence → wake display — reverse-engineering findings

Source: decompiled LineOS launcher, package `com.ultrabar.launch` / `com.ultrabar.smart`, under `.../scratchpad/lineos-src/sources/`. All quotes are JADX output (data, not executed). Builds on `sensecube-findings.md`, `corebar-screen-findings.md`, `device-settings-findings.md`.

## TL;DR

- **Not a built-in behavior.** There is no "presence keeps the screen awake / wakes on motion" anywhere. `ScreensaverController` is a pure *idle timer* (resets only on touch / `SCREEN_ON` broadcast); it has zero coupling to SenseCube presence. No default/factory automation ships for this.
- **The TRIGGER side is fully configurable over `:7431`.** SenseCube presence (`state == OCCUPIED`) is a first-class automation trigger in the "auto" scene engine, and auto-scenes are created/saved over the socket with `BATCH_CREATE_SCENE (30500)`. Presence events really do drive the engine (confirmed end-to-end below).
- **The ACTION side has no true "screen on / dismiss screensaver".** `ActionType.START_SCREEN` / `CLOSE_SCREEN` exist in the enum but have **no registered handler** (dead values). The only display-ish actions the device offers are: CoreBar **brightness** (`BRIGHT`, target id `"corebar"` → `SettingsScreen.setBrightnessPercentage`), **profile switch** (`CHANGE_PROFILE`), **app launch** (`ACTIVITY`), and for a VivoCube a **layer toggle** (`VIVO_CUBE_TOGGLE`, = `TOGGLE_LAYER`, changes displayed content — not a power/screen-on).
- So: you *can* build "presence → run these actions" over the protocol, but "wake the big screen out of the screensaver" is not a clean exposed action. Best candidate for an actual wake is `ACTIVITY` (launching an app brings an activity to front, which should dismiss the screensaver); brightness-up only brightens and does not stop the screensaver app.

---

## 1. The scene / automation model

Two parallel scene systems exist. The relevant one for motion-driven automation is the **"auto" engine** (`scene/auto/**` + `com.ultrabar.smart.scene.**`).

### Scene object (`com/ultrabar/smart/scene/Scene.java`)
```java
public class Scene {
    private List<ActionConfig> actions;              // what to do
    private List<ConditionItemConfig> conditions;    // extra gating (time, AND/OR/NOT) — optional
    private List<SceneItemConfig> triggers;          // what fires it
    private boolean enabled;
    private SceneType type;                           // AUTO | MANUAL | MODULE
    private String id, name, icon; private boolean show;
}
```

- `SceneType` (`com/ultrabar/smart/enums/SceneType.java`) = `AUTO, MANUAL, MODULE`.
- A **trigger** is a `SceneItemConfig { String type; Map<String,Object> params; String duration; }` (`scene/mode/SceneItemConfig.java`).
- A **condition** is `ConditionItemConfig extends SceneItemConfig { List<ConditionItemConfig> conditions; }` (nestable AND/OR/NOT).
- An **action** is `ActionConfig { String id; String name; ActionType type; List<ActionValue> values; Object objectParams; }` (`com/ultrabar/smart/bean/ActionConfig.java`). `values` are `{id, value}` pairs addressed by id (`getValueBy(id)`), e.g. the brightness level.

### Engine (`scene/auto/core/SceneEngine.java`)
`SceneEngine.activate(scene)`: for each trigger it builds an `ITrigger` via `TriggerRegistry.createInstance(type, sceneId, duration)` and `register`s a callback. On fire → `onTriggerFired` → `checkAllConditions` (via `ConditionRegistry`) → `scene.execute(...)` → `SceneExecute.execute(actions,...)` runs each `ActionConfig` through `ActionRegistry.get(type).execute(...)` sequentially (`scene/utils/SceneExecute.java`).

### What is registered (`common/init/SceneEngineInitializationTask.java`, line 86)
```
addTriggerFactory(DeviceStateTrigger, ProfileTrigger, AppStateTrigger)
addAction(AppCapabilityAction, AudioPlayerToggleAction, ActivityAction, PcBootAction, BrightAction,
          ColorAction, SoundscapAction, TimerAction, ColorTempAction, PcControlAction, DeviceStateAction,
          ModeAction, ProfileChangeAction, SceneAction, SpeedAction, TemperatureAction, ViVoCubeToggleAction,
          VolumeAction, DelayAction)
addConditions(DeviceStateCondition, AndCondition, OrCondition, NotCondition)
addMatchers(SwitchStateMatcher, LightStateMatcher, ProfileMatcher, SensecubeMather, AppStateMatcher, AudioPlayerMatcher)
```
**Note there is NO StartScreenAction / CloseScreenAction registered** — `ActionType.START_SCREEN` and `CLOSE_SCREEN` are defined in the enum but never handled. `ActionRegistry.get("START_SCREEN")` returns the no-op DEFAULT_ACTION.

### Loading stored scenes (`SceneEngineInitializationTask.registerAll`, lines 90–122)
On startup and on every `ReloadSceneEvent`, it deactivates old triggers and iterates `AppData.getScenes()`:
```java
if (scene.getActions()==null||empty) skip;
else if (scene.getType()==null) skip;
else if (scene.isEnabled()) {
    switch(scene.getType()) {
        case AUTO:   registerAuto(scene);   // -> SceneEngine.activate(scene)  (trigger-driven)
        case MANUAL: registerManual(scene); // -> SceneManager (button/hotkey driven)
    }
}
```
So an automation needs: `type: "AUTO"`, `enabled: true`, non-empty `triggers`, non-empty `actions`.

## 2. Trigger = SenseCube presence == OCCUPIED

### Trigger type & schema — `scene/auto/trigger/DeviceStateTrigger.java`
`TYPE = "DEVICE_STATE"`. `createInstance(...)` subscribes to `DeviceManager.subscribe(deviceId, onStateChange)`; when that device's property changes, it calls `triggerOnChange(deviceType, property, oldDevice, newDevice)`. Its `getMeta()` gives the exact param schema and the data-source act codes the builder uses:

| param | meaning | populated by act |
|---|---|---|
| `id` | the trigger device id | `SCENE_DEPENDS_DEVICES` (30701) |
| `property` | which attribute (`state`/`alsAlarm`/`tempAlarm`) | `SCENE_DEPENDS_DEVICES_PROPERTY` (30702), dependsOn `[id]` |
| `from` | value before | `SCENE_DEPENDS_DEVICES_PROPERTY_VALUE` (30703), dependsOn `[id,property]` |
| `to` | value after | `SCENE_DEPENDS_DEVICES_PROPERTY_VALUE` (30703), dependsOn `[id,property]` |

Validation rule: `from != to` (`ValidationRule NOT_EQUAL` on `[from,to]`).

### Presence as the property — `scene/auto/schema/SenseCubePropertySchema.java`
Exposes exactly three enum properties for a SenseCube: `state` (`OCCUPIED`/`UNOCCUPIED`), `alsAlarm` (`DIM`/`SOFT`/`BRIGHT`), `tempAlarm` (`COOL`/`MILD`/`WARM`). For motion use `property = "state"`, `to = "OCCUPIED"`.

### Matcher — `scene/auto/matcher/devices/SensecubeMather.java`
Only matches `type == "DEVICE_STATE"`; reads `params.property` (must be `state`/`alsAlarm`/`tempAlarm`), `params.from`, `params.to`. It reflects the value off `SenseCubeAttr.get<Property>()` for the old (`from`) and new (`to`) `Device`, comparing case-insensitively. `MatcherRule` from params: `BOTH` (from&to both checked), `ONLY_TO`, `ONLY_FROM` (`BaseMatcher.getMatcherRule`). For presence → occupied, `from=UNOCCUPIED, to=OCCUPIED` gives an unambiguous rising-edge match.

### Presence really feeds the engine (end-to-end, confirmed)
`common/module/SenseCubeModule.java`:
```
onProximityStateChanged(qLink, boolean z)              // device radar event
  -> onPresenceUpdate(PresenceState.getPresent(z))
     -> updateProperty(new, old, "state", attr::state) // SenseCubeAttr.state updated
        -> copy(attr())            // snapshot old Device
        -> upateDeviceProperty("state")  // dispatches a device state-change (prop name "state")
```
`SenseCubeAttr` holds `Attr<PresenceState> state` (and `illuminance/temperature/humidity/alsAlarm/tempAlarm`). The `upateDeviceProperty` dispatch is what `DeviceStateTrigger`'s `DeviceManager` subscription receives → trigger fires → `SensecubeMather` evaluates `state` from/to. (The SenseCube presence is the same device-event noted in `sensecube-findings.md` as "event only / not forwarded as a raw sensor read" — but it DOES reach the on-device scene engine via the Device attr, which is exactly what makes it usable as an automation trigger.)

### Reading the dependency pickers over the protocol (to discover the device id + legal values)
All three return a list of `DependsResponse {parentId,label,value,last}`.

- `SCENE_DEPENDS_DEVICES (30701)` — `data` is a **string** parentId (send `"SENSE_CUBE"` to list SenseCube devices, or `""` for the top tree). `GetDependsDeviceMessage` always injects a `SENSE_CUBE` category node (label = "find sense cube"); real paired SenseCube `Device`s appear with `value = device.getId()` (this id is the trigger's `params.id`). `GetDependsDeviceMessage.java`.
- `SCENE_DEPENDS_DEVICES_PROPERTY (30702)` — `data = {"id":"<deviceId>"}` → returns triggerable props; for a SenseCube: `{label:Detection,value:"state"}`, `{alsAlarm}`, `{tempAlarm}`. `GetDependsPropertyMessage.java`.
- `SCENE_DEPENDS_DEVICES_PROPERTY_VALUE (30703)` — `data = {"id":"<deviceId>","property":"state"}` → returns `{value:"OCCUPIED",...}`, `{value:"UNOCCUPIED",...}`. `GetDependsPropertyValueMessage.java`.

These three are **read/metadata only** (they populate the builder UI); they do NOT create anything.

## 3. Action = wake the displays — what actually exists

### No dedicated screen-on/off action
`ActionType` (`scene/enums/ActionType.java`) lists `CLOSE_SCREEN, START_SCREEN` but **no IAction implements them** (not in the `addAction(...)` list). They are dead. There is no "wake" or "screen power" scene action.

### Available display-affecting actions (the full catalog returned by `SCENE_ACTION_V2 = 1205` / `GetSceneActionMessage`)
`GetSceneActionMessage.getCoreBarAction()` exposes, for the CoreBar host itself:
```java
public static class CorebarActionId {
    public static final String COREBAR_ID  = "corebar";
    public static final String BRIGHT_ID   = "corebar.bright";
    public static final String VOLUME_ID   = "corebar.volume";
}
```
- **CoreBar screen brightness** → `ActionType.BRIGHT`, action `id="corebar"`, value `{id:"corebar.bright", value:1..100}` (SEEKBAR). Executed by `scene/action/BrightAction.java`: if `actionConfig.getId().equals("corebar")` → `SettingsScreen.setBrightnessPercentage(ctx, value)` (the big screen's own system brightness). Otherwise it routes to a light device (`OperateEnum.BRIGHT`).
- **CoreBar volume** → `ActionType.VOLUME`, id `"corebar"`, value `{id:"corebar.volume",...}`.
- **Profile (page) switch** → `ActionType.CHANGE_PROFILE` (`getChangeProfileAction`), `ProfileChangeAction` → emits `ProfileChangeEvent`. (In `ScreensaverController`, `ProfileChangeEvent` only calls `updateScreensaverConfig()` — it does **not** stop the screensaver.)
- **Launch an app** → `ActionType.ACTIVITY` (`getOtherApply`), `ActivityAction` → `StartAppEvent(From.SCENE, packageName)`. Bringing a foreground activity up is the one path that should actually knock down the screensaver (the saver is a separate `VIEW`-intent activity; a new activity on top + `updateLastOperationTime` effectively dismisses it). **Most promising real "wake".**
- **VivoCube** → `ActionType.VIVO_CUBE_TOGGLE` (via `getDeviceAction` → `ViVoCubeOperation.getActionParameters` → `ViVoCubeActionCreate`). `ViVoCubeToggleAction` → `ViVoCubeOperation.toggle(serialNo, layer, component)` → `CubeConstant.Command.TOGGLE_LAYER`. This toggles which layer/component the VivoCube shows — it changes content, it is **not** a generic screen power-on. The VivoCube action target `id` is the module serialNo (must be a CAN-gateway endpoint; `getActionParameters` only returns it if the device id is in `configuration.canGateway.endpoints`).

### Targeting summary
`ActionConfig.id` is the target: `"corebar"` for the CoreBar host (brightness/volume), the VivoCube module **serialNo** for `VIVO_CUBE_TOGGLE`, a profile id for `CHANGE_PROFILE`, a package name for `ACTIVITY`. `ActionConfig.values[]` carries the parameters by sub-id.

## 4. Is there already a built-in "presence keeps screen awake / wakes on motion"?

**No.** `common/service/ScreensaverController.java`:
- Idle is tracked purely by `lastOperationTime`, updated only on `ACTION_SCREEN_ON`, `ENABLE_SCREENSAVER`, touch/activity, and when the saver starts/stops. A 1 s `idleCheckTask` starts the saver once idle ≥ `idleTimeMillis`.
- Receivers registered: `TIME_MODE_CHANGE`, `DISABLE/ENABLE/EXIT_SCREENSAVER`, `SCREEN_OFF`, `SCREEN_ON`. **No presence / proximity / SenseCube receiver.** Grep for `presence|proximity|occupied|detection|sensecube` in the controller = 0 hits.
- `idleTimeMillis` derives from `ScreensaverConfig.lockTime` (clamped 20–100 s). Config read/write is `GET/SET_COREBAR_CONFIG 30740/30741 {type:"BASE_SET"}` (see `device-settings-findings.md`).
- The proximity auto-reset timer noted earlier only flips presence back to `UNOCCUPIED`; it never touches the display.

So any "motion → wake" must be built as an AUTO scene. There is no factory automation to toggle.

## 5. Can it be set over the protocol? — YES for the trigger, with an action caveat

### Create/save scenes = `BATCH_CREATE_SCENE (30500)` → `BatchCreateSceneMessage`
`MessageFactory` maps **only** `BATCH_CREATE_SCENE (30500)` for scene creation (`SingleCreateSceneMessage` exists in source but is **not** wired to any act code). `BatchCreateSceneMessage.onMessage` does `create(messageContext.parseArray(Scene.class))`.

**Important — it replaces the whole scene list.** `BaseCreateSceneMessage.create(List<Scene>)` does `appData.setScenes(filteredList)` (full overwrite), then `reload()` → `ReloadSceneEvent` → `registerAll()` re-activates everything. There is **no "GET scenes" act code** in the protocol, so (exactly like profiles / `BATCH_SAVE_PROFILE`) the desktop app must own the authoritative scene list and resend the full array on every change, or it will wipe existing scenes. (The by-id merge overload `create(Scene)` is only reachable from the unmapped single-create handler.)

Reply envelope: `Response {act,code,msg,data,id,timestamp}`, `code 200` = ok (`success(iReply,"ok")`), `code -1` = fail.

### Concrete call sequence: "SenseCube presence → CoreBar wake + VivoCube"
Preconditions: TLS `:7431`, AUTH as usual, line-delimited JSON.

1. Discover the SenseCube device id:
   `{"act":30701,"id":"r1","data":"SENSE_CUBE"}` → pick the child whose `value` is the SenseCube device id (call it `<SC_ID>`).
2. (optional, confirm values) `{"act":30702,"id":"r2","data":{"id":"<SC_ID>"}}` → `value:"state"`; `{"act":30703,"id":"r3","data":{"id":"<SC_ID>","property":"state"}}` → `OCCUPIED/UNOCCUPIED`.
3. (optional) `{"act":1205,"id":"r4","data":""}` → confirm the CoreBar brightness action id `"corebar"`/`"corebar.bright"` and, if targeting a VivoCube, its action node + serialNo.
4. Save the automation (send the **full** scenes array, here one scene):
```json
{"act":30500,"id":"r5","data":[
  {
    "id":"auto_presence_wake",
    "name":"Motion wake",
    "type":"AUTO",
    "enabled":true,
    "show":false,
    "triggers":[
      {"type":"DEVICE_STATE",
       "params":{"id":"<SC_ID>","property":"state","from":"UNOCCUPIED","to":"OCCUPIED"}}
    ],
    "conditions":[],
    "actions":[
      {"type":"BRIGHT","id":"corebar","values":[{"id":"corebar.bright","value":100}]},
      {"type":"ACTIVITY","id":"activity","values":[{"id":"1","value":"<pkg to bring to front>"}]},
      {"type":"VIVO_CUBE_TOGGLE","id":"<VIVOCUBE_SERIALNO>","values":[{"id":"1","value":"<layer>"},{"id":"2","value":"<component>"}]}
    ]
  }
]}
```
   - Expect `{"code":200,...}`. The device persists it and `registerAll()` activates the trigger immediately.
   - Drop/keep actions as desired. `BRIGHT corebar=100` brightens the panel but does **not** itself exit the screensaver; `ACTIVITY` (launch an app) is the action most likely to actually dismiss the saver and show something; `VIVO_CUBE_TOGGLE` drives a VivoCube's displayed layer.

### Honest verdict on "wake the big screen"
- Trigger (SenseCube presence): **(b) configurable over the protocol**, concrete and verified.
- "Turn the CoreBar screen on / dismiss the screensaver" as an action: **no first-class action exists.** The protocol gives you brightness, volume, profile switch, app launch, and VivoCube layer toggle. None is a documented "screen power on." Whether `ACTIVITY` (or `BRIGHT`+touch-equivalent) reliably knocks the panel out of the Android screensaver is unproven from code alone and must be tested on hardware.

## Open questions / to confirm on live hardware
1. Does firing an AUTO scene `ACTIVITY` (or `CHANGE_PROFILE`/`BRIGHT`) action while the screensaver is showing actually dismiss it and light the panel? (Code: saver is dismissed on new activity / `updateLastOperationTime`, but not proven.)
2. The exact `values[]` sub-ids for `VIVO_CUBE_TOGGLE` (`ViVoCubeOperation.toggle` reads value ids `"1"`=layer and `"2"`=component via `getValueToStr`) and `ACTIVITY` (value id `"1"` = package) — confirm against a `1205` dump.
3. Confirm `BATCH_CREATE_SCENE` truly full-replaces on this firmware (so the app must resend all scenes) and that there is no undocumented scene-list read.
4. Confirm presence state-change dispatch (`upateDeviceProperty("state")`) reaches `DeviceManager` subscribers in practice (the trigger subscribes to `DeviceManager.subscribe(id,...)`).

## Single best next experiment
On the live device: (1) read the SenseCube device id via `30701 {data:"SENSE_CUBE"}`; (2) save a one-action AUTO scene via `30500` with trigger `DEVICE_STATE state UNOCCUPIED→OCCUPIED` and a single `ACTIVITY` action launching any visible app (e.g. the clock/home); (3) set the screensaver short (`30741 BASE_SET lockTime=TIME_30S`), let it start, then walk in front of the SenseCube and see whether the panel wakes/shows the app. This directly tests both that presence drives the engine and whether any available action can act as a "wake." If `ACTIVITY` wakes it, that is the shipping mechanism; if not, "motion→wake" is effectively device-UI-unsupported and would need a brightness/keep-alive workaround.
