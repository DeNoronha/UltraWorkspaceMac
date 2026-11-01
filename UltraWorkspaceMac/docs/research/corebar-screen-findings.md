# CoreBar big-screen control — reverse-engineering findings

Research into the decompiled LineOS launcher (`lineos-src`) that runs on the CoreBar's own 1424×280 LineOS/Android screen. All paths below are relative to the scratchpad decompile root unless noted. Primary evidence is quoted inline. The bridge decompile (`bridge-src`) contains none of these handlers — it is a transparent relay; the real CoreBar-screen protocol lives in the LineOS launcher, package `com.ultrabar.launch`.

## 0. Wire format (confirmed from code)

The TLS 7431 control channel carries line-delimited JSON. Request and response envelopes:

- Request (`lineos-src/.../communication/bean/Request.java`): `{ "act": <int>, "code": <int>, "data": <T>, "id": <string> }`
- Response (`.../communication/bean/Response.java`): `{ "act", "code", "data", "id", "msg", "timestamp" }`, where `code` 200 = success, `code` -1 = fail. A success reply is built as `new Response(id, data)` → `code=200`; fail as `new Response(id, msg)` → `code=-1`.

`data` is parsed by handlers through `MessageContext` (`.../message/base/MessageContext.java`). The payload for a message always lives under the top-level key `"data"`:

- `parseObj(Class)` → `jsonObject.getJSONObject("data").toJavaObject(cls)` (object payload)
- `parseArray(Class)` → `jsonObject.getJSONArray("data").toJavaList(cls)` (array payload)
- `parseStr()` → `jsonObject.getString("data")` (string payload)
- `parseInt()` → `jsonObject.getInteger("data")` (int payload)

So the shape of `data` differs per act code; this is called out for each action below.

## 1. Full MessageAction enum (act code → name)

Source: `lineos-src/sources/com/ultrabar/launch/common/communication/bean/MessageAction.java`. Complete list:

| Code | Name | Screen-relevant? |
|------|------|------------------|
| 10 | ERROR | |
| 11 | EXCEPTION | |
| 20 | HEARTBEAT_PACKAGE | |
| 100 | AUTH | |
| 101 | REQ_AUTH_TOKEN | |
| 1000 | GET_APP_LIST | |
| 1002 | GET_PROFILE_WIDGET | YES — returns the widget/component tree to place |
| 1010 | INTEGRATED_CONFIG_SET | YES — sets a widget-app's config (weather, HA, etc.) |
| 1103 | TRIGGER_PROFILE_CHANGE | YES — switch the active profile ("page") |
| 1108 | BATCH_SAVE_PROFILE | YES — save the whole profile list (layout + wallpaper) |
| 1204 | SCENE_TRIGGER | |
| 1205 | SCENE_ACTION_V2 | |
| 1300 | GET_DEVICE | |
| 1500 | LIST_EMAIL_CONFIG | |
| 1501 | SAVE_EMAIL_CONFIG | |
| 1502 | DEL_EMAIL | |
| 1617 | GET_KNOB_FUNCTION_DEVICE | |
| 1633 | START_SCAN_WIFI | |
| 1634 | STOP_SCAN_WIFI | |
| 1635 | CUBE_SCAN_WIFI_LIST_RESULT | |
| 20100 | SYS_REBOOT | |
| 30100 | MODULE_START_DISCOVERY | |
| 30101 | MODULE_STOP_DISCOVERY | |
| 30102 | MODULE_START_DISCOVERY_REPLAY | |
| 30103 | GATEWAY_SUB_PAIRING | |
| 30104 | GATEWAY_PAIRING_RESULT | |
| 30200 | MODULE_PROPERTY_READ | |
| 30201 | MODULE_PROPERTY_WRITE | |
| 30300 | SET_GATEWAY_CONFIG | |
| 30400 | MODULE_OAT_START | |
| 30401 | MODULE_OAT_DATA | |
| 30500 | BATCH_CREATE_SCENE | |
| 30600 | APP_MANAGER | |
| 30601 | APP_MANAGER_PROGRESS_EVENT | |
| 30700 | SCENE_GET_TRIGGER_PARAM | |
| 30701 | SCENE_DEPENDS_DEVICES | |
| 30702 | SCENE_DEPENDS_DEVICES_PROPERTY | |
| 30703 | SCENE_DEPENDS_DEVICES_PROPERTY_VALUE | |
| 30710 | SCENE_DEPENDS_PROFILE | |
| 30720 | SCENE_DEPENDS_APPS | |
| 30721 | SCENE_DEPENDS_APPS_VALUE | |
| 30730 | QUERY_MODULE_STATE | |
| 30740 | GET_COREBAR_CONFIG | YES — read screensaver config |
| 30741 | SET_COREBAR_CONFIG | YES — write screensaver config |
| 30742 | PREVIEW_SCREENSAVER | YES — one-shot full-screen media preview |
| 30750 | THREE_CAPABILITY_ACTION | |
| 30751 | THREE_CAPABILITY_PARAM | |
| 30752 | THREE_CAPABILITY_OPTION | |
| 1000000 | PUSH_MESSAGE | |

Routing is confirmed in `.../communication/factory/MessageFactory.java` (`HANDLERS` map). Notably: `SET_COREBAR_CONFIG → ConfigWriteMessage`, `GET_COREBAR_CONFIG → ConfigReadMessage`, `PREVIEW_SCREENSAVER → PreviewScreensaverMessage`, `BATCH_SAVE_PROFILE → BatchProfileMessage`, `TRIGGER_PROFILE_CHANGE → ChangeProfileMessage`, `GET_PROFILE_WIDGET → GetComponentMessage`, `INTEGRATED_CONFIG_SET → IntegratedConfigSetMessage`.

There is no dedicated "wallpaper" act code. The screen background is part of the Profile object, saved via `BATCH_SAVE_PROFILE` (see §2).

## 2. Wallpaper / background

There is NO separate "set wallpaper" message. The background behind the on-screen clock is a field inside a profile/widget, persisted by `BATCH_SAVE_PROFILE (1108)`, and the image bytes are delivered out-of-band over HTTP (§5). Two background fields exist:

### a) Profile-level `albumId`
`.../common/bean/profile/Profile.java`:
```java
private String albumId = "time_image_10";
```
Defaults to a built-in resource id. This is a profile property, serialized with the profile. (Note: no live render call site for `getAlbumId()` was found in this decompile subset besides the getter itself — the per-widget `icon` path below is the one the device's own Settings UI actually writes.)

### b) Per-TIME-widget background `icon` (what the device UI actually edits)
The CoreBar's own "time image" picker (`.../ui/activity/set/display/TimeImageActivity.java`) sets the chosen image onto the TIME widget's `icon` field, then saves the profile:
```java
homeData2.setIcon(resItem.getValue());   // resItem.value = "resId://time_image_N" OR an absolute file path
...
profile.setHomeData(homeData);
```
The available background images come from `AlbumDataLoader` (`.../common/utils/AlbumDataLoader.java`). Built-ins are `time_image_2..11` with value `"resId://time_image_N"`; uploaded/user images appear as `ResType.FILE` whose `id`/`value` is the absolute file path on the device:
```java
list.add(ResItem.builder().id(file.getAbsolutePath()).value(file.getAbsolutePath())
    .resType(ResItem.ResType.FILE).timestamp(file.lastModified()).build());
```

### Image URI resolution (how any background/screensaver string is loaded)
`.../common/utils/GlideExtend.java` `loadSmartCore(...)` resolves an image reference string:
```java
if (URLUtil.isNetworkUrl(str))           -> load(str)                         // http://ip:8080/...
if (str.startsWith("resId://"))          -> load(drawable by name)            // built-ins
if (!startsWith("file://") && !"/")      -> new File(getExternalFilesDir(null), str)  // RELATIVE path under app files dir
if (startsWith "file://" or "/")         -> absolute File
```
This is the key: an image uploaded via `/upload/zip?subDir=<x>` (which lands in `getExternalFilesDir(null)/<x>/...`, see §5) can be referenced from a profile/widget either by its absolute path or by the relative path `"<x>/<filename>"`.

### Format / dimensions
No RGB565/tar packing for the big screen — these are ordinary image files. Allowed extensions (`UploadServiceIns.ALLOWED_IMG_EXTENSIONS` and `AlbumDataLoader.isImageFile`): `jpg, jpeg, png, webp, gif`. The target panel is 1424×280, so a custom wallpaper should be a 1424×280 (5:1) JPG/PNG/WEBP. No explicit dimension validation exists in the upload path; the image is scaled by Glide at render.

## 3. Screensaver

### Config read/write — act 30740 / 30741
`SET_COREBAR_CONFIG (30741)` → `ConfigWriteMessage`, `GET_COREBAR_CONFIG (30740)` → `ConfigReadMessage` (`.../message/generic/ConfigWriteMessage.java`, `ConfigReadMessage.java`). Both parse `data` as a `ReadWriteRequest`:

`.../message/generic/setting/ReadWriteRequest.java`:
```java
class ReadWriteRequest { ReadWriteType type; Object value; }
```
`.../message/generic/setting/ReadWriteType.java`:
```java
enum ReadWriteType { BASE_SET, GATEWAY_CONFIG, APP_LIST }
```

`ReadWriteManager` dispatches by `type`. For the screensaver, `type = BASE_SET`, handled by `BaseSetReadWrite` (`.../message/generic/setting/impl/BaseSetReadWrite.java`):
```java
public Object get(Object o)  { return SharedPreferencesUtils...getData().getScreensaver(); }
public ReadWriteResult set(Object o) {
    ScreensaverConfig cfg = parse(o, ScreensaverConfig.class);   // value -> ScreensaverConfig
    ...appData.setScreensaver(cfg)...
}
```

So:
- `GET_COREBAR_CONFIG (30740)`, `data = { "type": "BASE_SET" }` → reply `data` is the current `ScreensaverConfig`.
- `SET_COREBAR_CONFIG (30741)`, `data = { "type": "BASE_SET", "value": <ScreensaverConfig> }` → saves it.

### ScreensaverConfig schema
`.../common/bean/ScreensaverConfig.java`:
```java
boolean  featureEnabled;
LockTime lockTime;     // enum
String   packageName;  // screensaver app package
String   uri;          // media/host string
int      ver = 1;
```
`LockTime` (`chief/enums/LockTime.java`): `TIME_30S(30), TIME_1MIN(60), TIME_2MIN(120), TIME_3MIN(180), TIME_4MIN(240), TIME_5MIN(300), NEVER(MAX)` — serialized by enum name.

### How it is consumed / rotation
`.../common/service/ScreensaverController.java`:
```java
updateScreensaverUri(cfg.getVer() < 2 ? cfg.getUri() : cfg.getPackageName());
...
private String buildCommandUri(boolean start, String host) {
    return String.format("screensaver://%s/%s", host, start ? "start" : "stop");
}
```
The controller does NOT render images itself. On idle it fires an Android `VIEW` intent `screensaver://<host>/start?24h=<bool>` to launch a separate screensaver app (the `packageName` in v2, or the `uri` host in v1). That app is responsible for scanning its own image folder and rotating/slideshowing. Therefore **multiple screensaver images and their rotation are NOT represented in the control protocol** — the config carries a single host/uri plus enable + idle timeout. Idle timeout is derived from `lockTime` in `updateIdleTime()` (clamped 20–100s).

Practical implication: to use custom screensaver images you push them (zip of images) to the screensaver app's folder via HTTP (§5), then enable the screensaver via `SET_COREBAR_CONFIG/BASE_SET` with the right `packageName`/`uri`.

### Preview — act 30742
`.../message/screensaver/PreviewScreensaverMessage.java`. `data` parses to:
```java
class PreviewMessage { FullScreenMediaDialog.MediaType mediaType; String url; }
```
`FullScreenMediaDialog.MediaType` = `{ IMAGE, VIDEO }` (`.../common/dialog/FullScreenMediaDialog.java`; it also auto-detects type by extension — `.mp4/.mov/.mkv/.webm/.3gp/.avi` = VIDEO, else IMAGE). It immediately shows a full-screen dialog of that `url`. So:
- `PREVIEW_SCREENSAVER (30742)`, `data = { "url": "<http or file path>", "mediaType": "IMAGE" }` → device shows it full-screen at once. This is the quickest way to throw a 1424×280 image onto the panel to eyeball it (no persistence).

## 4. On-screen widget / profile layout ("pages")

### Multiple profiles = multiple pages: YES
`.../common/bean/AppData.java` holds the entire device config, including `List<Profile> profiles` (plural), `ScreensaverConfig screensaver`, `List<Scene> scenes`, `CoreBarConfiguration configuration`, etc. A profile is exactly the Stream Deck "page" analogue: you define several and switch the active one.

Switch the active profile: `TRIGGER_PROFILE_CHANGE (1103)` → `ChangeProfileMessage` (`.../message/profile/ChangeProfileMessage.java`). `data` is a **string** = the profile `id`. It looks the profile up in `AppData.profiles` and emits a profile-change event (`EventManager.triggerProfileChangeEvent(id, name)`). Error if id unknown.

### Save all profiles: BATCH_SAVE_PROFILE (1108)
`.../message/profile/BatchProfileMessage.java`:
```java
ProfileManager.batchSave(messageContext.parseArray(ProfileManager.ProfileDTO.class))
```
`data` is an **array of ProfileDTO**. `ProfileManager.batchSave` maps each DTO to a `Profile` and **replaces the entire profile list** (`appData.setProfiles(list)`), then reloads modules and exits the screensaver. So 1108 is a full "save all pages" operation (read-modify-write the whole list; the device does not merge).

### Profile / ProfileDTO schema
`ProfileManager.ProfileDTO` (in `.../common/manager/ProfileManager.java`) and `Profile`/`ProfileProperty`/`HomeData`:

ProfileDTO fields (what the PC sends):
```
id        : String   (required, non-empty)
name      : String
icon      : String
bgColor   : String
iconScale : int      (<=0 coerced to 100)
isDefault : boolean
showName  : Boolean
module    : [ModuleConfig]      // physical modules bound to this profile
widget    : [WidgetProperty]    // the on-screen widget layout -> becomes Profile.homeData
```
On save, `toProfile()` copies these and maps `widget[]` → `homeData[]` via `WidgetCoverRegistry.cover(...)` (per-type param conversion). Profile also carries `albumId` (default `"time_image_10"`) and `player`.

WidgetProperty / HomeData (`.../communication/bean/WidgetProperty.java` extends `.../common/bean/HomeData.java` extends `ProfileProperty`):
```
id        : String
name      : String
icon      : String        // widget icon URL, or (for TIME) the background image ref
bgColor   : String
iconScale : int
type      : WidgetType    // enum, serialized by name
param     : Object        // type-specific config (converted by *ParamConverter)
```
`WidgetType` enum (`.../common/enums/WidgetType.java`): `EMAIL_CARD, TIMER, SOUNDSCAPE, SET, APPS, TIME, WORLD_TIME, WEATHER, SWITCH, SCENE, CURTAIN_SWITCH, CURTAIN, LIGHT, LIGHT_TEMP, LIGHT_HS, LIGHT_HS_TEMP, AC, FAN, TEMPERATURE_SENSOR, HUMIDITY_SENSOR, AUDIO_PLAYER, PC_CONTROL, CPU, MEMORY, STORAGE, NETWORK, HOT_KEY_GROUP, SENSE_CUBE, PC_BOOT, SENSE_CUBE_ALS, SENSE_CUBE_RADAR, SENSE_CUBE_TEMP, SENSE_CUBE_HUM, SENSE_CUBE_AUDIO, UNSUPPORTED`.

Per-type `param` converters are registered in `.../message/profile/convert/WidgetCoverRegistry.java` (TimeParamConverter, WeatherParamConverter, SceneParamConverter, PcControlParamConverter, SenseCube*…). To author a given widget's `param`, read the matching converter under `.../message/profile/convert/impl/`.

### Positions / pages-within-a-profile
There is NO explicit x/y position field on a widget. The on-screen order is the list order of `homeData`/`widget[]`. So a profile is a single ordered strip of widgets (fits the 1424×280 bar). Multiple "pages" = multiple Profiles switched via 1103, not multiple pages inside one profile.

### Discover placeable widgets: GET_PROFILE_WIDGET (1002)
`.../message/profile/GetComponentMessage.java` → `ProfileManager.getComponentV3(parentId)`. `data` is a **string** parent id; reply is the tree of available `WidgetProperty` nodes (devices under `iot`, apps under `apps`, etc.) you can drop into a profile.

### INTEGRATED_CONFIG_SET (1010)
`.../message/generic/IntegratedConfigSetMessage.java`. `data` = `AppConfig { String packageName; Object config }`. Routes to a per-package `IConfigSaver` (e.g. `WeatherConfigSaver`, `HAConfigSaver`). This configures a widget-backing app (e.g. weather location), not the wallpaper.

## 5. Upload endpoints for CoreBar-screen assets

HTTP server: AndServer on port 8080 (`.../common/http/WebServerManager.java`, `PORT = 8080`, base URL `http://<wifi-ip>:8080`). Two POST routes (`.../common/http/controller/UploadControllerAdapter.java`):

### a) `POST /upload` (and `/upload/`), produces `application/json`
Handler `UploadControllerUploadHandler`: requires query param `serialNo` and a multipart field `file`. Routes to `UploadServiceIns.uploadConfig(serialNo, file)`, which looks up a **module** by serial and pushes a `.tgz` to it (VivoCube firmware/image path). **This is the module route (e.g. VivoCube 240×240), NOT the big screen.**

### b) `POST /upload/zip` (and `/upload/zip/`)
Handler `UploadControllerUploadZipHandler`: multipart field `file` (a `.zip`, max 50MB), query params `subDir` (optional, default "") and `isFull` (optional, default "true"). Routes to `UploadServiceIns.uploadZip(subDir, file, isFull)`:
```java
File dir = context.getExternalFilesDir(null);
if (subDir not empty) dir = new File(dir, "/" + subDir);
if (isFull && dir.exists()) deleteDirFiles(dir);   // isFull=true wipes the subdir first
... unzipWithStructure(file.stream(), dir);          // extracts preserving folder structure
onUpdateProfile();                                    // fires ReloadProfileEvent
```
`unzipWithStructure` only writes image files (`jpg/jpeg/png/webp/gif`), skips `__MACOSX`/`.DS_Store`, and blocks path traversal. **This is the route that puts big-screen images (wallpaper album, screensaver images) onto the device filesystem**, under `getExternalFilesDir(null)/<subDir>/...`. Those files are then referable from a profile/widget by absolute path or by the relative path `"<subDir>/<file>"` (resolved by `GlideExtend`, §2).

### Target id of the big screen itself
The big screen is the host device, NOT a module — it has no `serialNo` in these flows. Wallpaper/screensaver images go to `/upload/zip` (no serialNo); only physical modules use `/upload?serialNo=<serial>`. The screen is addressed implicitly as "this device": profile/screensaver state is the device's own `AppData`, mutated over the 7431 control channel.

### Also available: `GET /widget/icon?id=&type=&scheme=`
`.../common/http/controller/WidgetController*.java` + `ProfileManager.getAppICON`/`getICON` build `http://<ip>:8080/widget/icon?id=...&type=...&scheme=...`. This is how widget icons are fetched; not a wallpaper upload, but confirms the 8080 base and shows widget `icon` URLs are 8080 HTTP URLs.

## 6. Concrete implementable call sequences

Preconditions for all: open TLS to `<ip>:7431`, send `AUTH (100)` / `REQ_AUTH_TOKEN (101)` as already established, then line-delimited JSON. Image files are plain JPG/PNG/WEBP sized 1424×280.

### (a) Custom wallpaper (background behind the clock)
1. Zip the image(s), e.g. `wallpaper/custom1.jpg`.
2. `POST http://<ip>:8080/upload/zip?subDir=wallpaper&isFull=false` with multipart `file=<the .zip>`. Expect `{ "state":200, ... }` style success (`HttpResult.onSuccess`). Files now live at `.../files/wallpaper/custom1.jpg`; reference string = `"wallpaper/custom1.jpg"` (relative, resolved against `getExternalFilesDir`).
3. Read current profiles: there is no single "GET profiles" act in the enum — the PC keeps the profile list it authored (or reads device state via its normal provisioning read). Modify the target profile's TIME widget so its `icon` = `"wallpaper/custom1.jpg"` (absolute path also works). Optionally also set `Profile.albumId` to the same reference.
4. Send `BATCH_SAVE_PROFILE (1108)` with `data` = the **full array** of ProfileDTOs (the device replaces the whole list), e.g.:
```json
{ "act": 1108, "id": "<uuid>", "data": [
  { "id":"p1", "name":"Home", "isDefault":true, "showName":true, "iconScale":100,
    "module": [...],
    "widget": [ { "id":"<time-widget-id>", "type":"TIME", "name":"Clock",
                  "icon":"wallpaper/custom1.jpg" }, ... ] }
] }
```
5. Device persists, reloads the profile, and renders the new background. (`BatchProfileMessage` → `reloadModuleProfile()`.) Expect `{ "code":200 }`.

Uncertain: whether `Profile.albumId` alone (without touching a TIME widget's `icon`) repaints the whole screen — the only writer observed in the device UI is the per-TIME-widget `icon`. Safest is to set the TIME widget `icon`. (Flagged for live test.)

### (b) Custom screensaver
Quick preview (non-persistent, best first test):
1. Upload image via `/upload/zip?subDir=screensaver&isFull=false` (or reference any http URL).
2. `PREVIEW_SCREENSAVER (30742)` with `data = { "url": "http://<ip>:8080/...", "mediaType": "IMAGE" }` (or a `file://`/absolute path). Device shows it full-screen immediately.

Persistent screensaver:
1. Push the screensaver image set as a zip to the screensaver app's folder via `/upload/zip?subDir=<screensaver-app-dir>&isFull=true`.
2. `SET_COREBAR_CONFIG (30741)` with:
```json
{ "act": 30741, "id": "<uuid>", "data": {
    "type": "BASE_SET",
    "value": { "featureEnabled": true, "lockTime": "TIME_1MIN",
               "packageName": "<screensaver app package>", "uri": "<host or media>", "ver": 2 }
} }
```
   - For `ver >= 2` the controller uses `packageName` as the `screensaver://<packageName>/start` host; for `ver < 2` it uses `uri`. Match whatever the existing screensaver app expects (read it back first with `GET_COREBAR_CONFIG`/`BASE_SET`).
3. Verify with `GET_COREBAR_CONFIG (30740)`, `data = { "type":"BASE_SET" }` → returns the stored `ScreensaverConfig`.

Uncertain: the exact `packageName`/`uri` value and the folder the built-in screensaver app scans. Rotation across multiple images is entirely the screensaver app's job — not in the protocol. (Flagged for live test.)

## Open questions / to confirm on live hardware
1. Does setting `Profile.albumId` repaint the full-screen background, or must the TIME widget's `icon` be set? (Set the TIME widget `icon` to be safe.)
2. Exact success body of `POST /upload/zip` (code returns `HttpResult.onSuccess(<count>)` — confirm JSON shape vs. the `{ "state":200, "msg":"ok" }` seen on `/upload`).
3. The screensaver app's `packageName` and the directory it reads, and whether `ver` should be 1 or 2 on this firmware.
4. Whether there is a "read full AppData / profile list" op over 7431 the PC uses before a 1108 (not present in `MessageAction`; the PC likely owns the authoritative copy from provisioning).
5. The `param` JSON for a TIME widget (inspect `TimeParamConverter` under `.../message/profile/convert/impl/`).

### Single best next experiment
Fire `PREVIEW_SCREENSAVER (30742)` with `data = {"url": "http://<pc-or-device-ip>:8080/<uploaded>.jpg", "mediaType":"IMAGE"}` (after `/upload/zip`), to confirm a 1424×280 custom image displays full-screen on the panel. It is non-destructive, exercises both the upload path and the control channel, and immediately validates image sizing/format before attempting the persistent profile/screensaver writes.
