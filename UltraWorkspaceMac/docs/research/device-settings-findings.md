# CoreBar / LineOS launcher — device settings over the :7431 protocol

Reverse-engineered from the decompiled `com.ultrabar.launch` launcher. Read-only analysis; nothing executed.

TLS :7431, line-JSON request `{act:int, data:T, id:String}`. Reply envelope is `com.ultrabar.launch.common.communication.bean.Response`: `{act, code(200=SUCCESS, -1=FAIL), msg, data, id, timestamp}` (richer than the `{code}` noted in the brief — `data` carries the read-back).

## Ground truth: the full protocol surface

Every act code that the device actually handles is registered in `MessageFactory` (`sources/com/ultrabar/launch/common/communication/factory/MessageFactory.java`). If an act code is not in that `HANDLERS` map, the device has no handler for it. The `MessageAction` enum (`.../communication/bean/MessageAction.java`) defines all codes; there are **no** VOLUME / BLUETOOTH / WIFI-CONNECT / BRIGHTNESS / DISPLAY / LOCALE / TIMEZONE act codes anywhere in the 20000–30999 range. The only system-ish codes are: `SYS_REBOOT=20100`, `GET/SET_COREBAR_CONFIG=30740/30741`, `SET_GATEWAY_CONFIG=30300`, `PREVIEW_SCREENSAVER=30742`, `START/STOP_SCAN_WIFI=1633/1634` (+ push `CUBE_SCAN_WIFI_LIST_RESULT=1635`), `MODULE_PROPERTY_READ/WRITE=30200/30201`, `INTEGRATED_CONFIG_SET=1010`.

## SET_COREBAR_CONFIG (30741) — the `type` dispatch is only 3 values

`ConfigWriteMessage` → `ReadWriteManager.apply(ReadWriteRequest)`. `ReadWriteRequest = {type: ReadWriteType, value: Object}`. The enum `ReadWriteType` (`.../generic/setting/ReadWriteType.java`) has **exactly three** members, and `ReadWriteManager.init()` registers exactly three handlers:

| `type` (wire = enum name) | handler | `value` schema | set? | get (GET_COREBAR_CONFIG 30740)? |
|---|---|---|---|---|
| `BASE_SET` | `BaseSetReadWrite` | `ScreensaverConfig` | yes → saves `AppData.screensaver` | yes → returns stored `ScreensaverConfig` |
| `GATEWAY_CONFIG` | `GatewayConfigWrite` | `CoreBarConfiguration` (canGateway/meshGateway → endpoints) | yes → saves + re-inits endpoints | `get()` returns `null` (write-only) |
| `APP_LIST` | `AppListRead` | String AppType ("ALL"/…) | `set()` returns null (read-only) | yes → returns installed-app list (`AppDetail[]`) |

Note the stray constant `BaseSetReadWrite.TYPE = "SCREENSAVER"` is **unused**; the actual wire key is the enum name `BASE_SET`. Enum (de)serialization is fastjson-by-name.

So SET_COREBAR_CONFIG can configure only: the screensaver, the gateway endpoints, and (read) the app list. It is NOT a general system-settings bucket.

## Per-setting findings

| Setting | Controllable over protocol? | act code | request body | read-back | confidence |
|---|---|---|---|---|---|
| **Screensaver** | YES | SET 30741 / GET 30740 | `data={type:"BASE_SET", value:ScreensaverConfig}` | GET 30740 `data={type:"BASE_SET"}` → returns ScreensaverConfig | HIGH |
| **Screensaver preview** | YES | 30742 | `data={url:String, mediaType:"IMAGE"|"VIDEO"}` | success msg only | HIGH |
| **Gateway endpoints** | YES | 30741 | `data={type:"GATEWAY_CONFIG", value:CoreBarConfiguration}` | none (get→null) | HIGH |
| **Reboot** | YES | 20100 | (RebootMessage) | success | HIGH |
| **Screen on/off** | YES (per brief) | 30201 MODULE_PROPERTY_WRITE | `WriteProperty{serialNo,deviceId:int,propertyId:4,value}` | PropertySuccess/PropertyFailure | MED (given by caller; it is an *endpoint* write, see note) |
| **Wi-Fi scan / list** | PARTIAL | 1633 start / 1634 stop | start: no body (uses msg id); result pushed as 1635 | push `CUBE_SCAN_WIFI_LIST_RESULT` list of `{name,signal,frequency}` (open networks filtered OUT) | HIGH |
| **Wi-Fi connect** | NO | — | no handler exists | — | HIGH (absence) |
| **System volume / mute** | NO | — | no act code; local-only (knob) | — | HIGH (absence) |
| **Screen brightness** | NO | — | no act code; local-only (knob) | — | HIGH (absence) |
| **Screen-off / sleep timeout** | NO | — | no act code (local `SettingsScreen`) | — | HIGH (absence) |
| **Bluetooth (on/off/scan/connect)** | NO | — | no act code; local-only UI | — | HIGH (absence) |
| **Time / timezone / 24h / auto-time** | NO | — | no act code (local `SettingsNetworkTime`) | — | HIGH (absence) |
| **Locale / language** | NO | — | not present anywhere | — | HIGH (absence) |
| **Wallpaper / background** | NO (only screensaver uri) | — | no wallpaper handler in comms layer | — | HIGH (absence) |
| **Per-app config (HA / Weather)** | YES (not a system setting) | 1010 INTEGRATED_CONFIG_SET | `AppConfig{packageName,...}` — only HA + Weather-virtual supported | success/fail | HIGH |

### ScreensaverConfig schema (confirmed)
`com.ultrabar.launch.common.bean.ScreensaverConfig`:
```
{ featureEnabled: boolean,
  lockTime: LockTime (enum, see below),
  uri: String,            // media URL/path shown as screensaver
  packageName: String,    // screensaver app pkg (empty for plain media)
  ver: int (default 1) }
```
`LockTime` (`chief/enums/LockTime.java`), serialized by NAME: `TIME_30S`(30s), `TIME_1MIN`(60), `TIME_2MIN`(120), `TIME_3MIN`(180), `TIME_4MIN`(240), `TIME_5MIN`(300), `NEVER`(Integer.MAX_VALUE). Default `NEVER`. Note: `SettingsScreen.getScreenOffTimeoutEnum` maps these onto the Android `screen_off_timeout` setting locally, but there is no protocol path to write it — lockTime here only governs the screensaver feature stored in `AppData`, not the OS sleep timeout.

### WriteProperty schema (MODULE_PROPERTY_WRITE 30201)
`Property{serialNo:String, deviceId:int, propertyId:int, type:String}` + `WriteProperty{value:Object}`. Important: `WritePropertyMessage` **rejects `serialNo == "0000000000000000"`** and routes only to CAN/Mesh gateway *endpoints*. So this path targets paired sub-modules; screen on/off via propertyId 4 implies the screen is itself exposed as a gateway endpoint (serialNo != all-zero). The CoreBar's own local volume/brightness are NOT reachable this way.

## Why volume/brightness/BT/wifi/time are local-only (evidence)

The device HAS helpers for all of them, but they are invoked only by on-device UI / the physical knob, never by a protocol handler. Grep of `.../communication/**` for `chief.utils.Settings*` returns nothing.

- Volume: `LocalVolumeController` (knob `IDeviceController`, deviceId `local:volume`) → `chief.utils.SettingsVolume.setMediaVolumePercentage` → `AudioManager.setStreamVolume(STREAM_MUSIC,…)`. `SettingsVolume` also has `get/setSoundEffectsEnabled` but no mute/stream-mute API and no protocol exposure.
- Brightness: `LocalBrightController` (deviceId `corebar:bright`) → `chief.utils.SettingsScreen.setBrightnessPercentage` → `Settings.System screen_brightness`. Same file has `get/setScreenOffTimeout(LockTime)` → `screen_off_timeout`. Local only.
- Bluetooth: `chief.utils.SettingsBluetooth` (BLE scan/GATT) + `ui/activity/set/BluetoothActivity`. Local UI only; no act code.
- Time: `chief.utils.SettingsNetworkTime` — `set24HourFormat` (`time_12_24`), `setAutoTimeEnabled` (`auto_time`), `setTimezone` (NTP + `setprop persist.sys.timezone`), `setOSTime`. All local; no act code. (It also fetches timezone from ipwho.is / ipapi.co / ipinfo.io.)
- Wallpaper: none in comms layer; only the screensaver `uri`.

## INTEGRATED_CONFIG_SET (1010) detail
`AppConfigFactory` supports only `Constants.HA_PACKAGE` (Home Assistant) and `Constants.WEATHER_PACKAGE_VIRTUAL`. Not a system/wallpaper channel.
