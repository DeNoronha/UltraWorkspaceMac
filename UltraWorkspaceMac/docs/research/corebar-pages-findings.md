# CoreBar "pages" (profiles), backgrounds and screensaver — rigorous findings

Scope: how to put our own content on the CoreBar's 1424×280 LineOS screen persistently (profiles = Stream-Deck-like pages) and what the official UltraWorkSpace client actually sends. Every claim is tagged **CONFIRMED** (quoted from the decompiled launcher `com.ultrabar.launch` or from strings/symbols in the official macOS binary) or **HYPOTHESIS** (inferred; must be verified on hardware). Paths below are relative to `scratchpad/lineos-src/sources/com/ultrabar/launch/` unless stated; `UW:<n>` means line *n* of `strings -n 4` output of `/Volumes/UltraWorkSpace-V1.0.1.0-Installer/UltraWorkSpace.app/Contents/MacOS/UltraWorkSpace` (saved at `scratchpad/uw-strings.txt`).

## Executive summary

1. **CONFIRMED — the wire schema for `BATCH_SAVE_PROFILE` (1108) is small and fully known**: `data` = array of `ProfileDTO {id, name, icon, bgColor, iconScale, isDefault, showName, module[], widget[]}`; each `widget[]` item is `{id, name, icon, bgColor, iconScale, type, param, last}`. Only `id` (non-empty) and `widget` (non-null array, may be empty) are validated. The device **replaces the entire profile list** (`appData.setProfiles(list)`).
2. **CONFIRMED — `albumId` is dead on the wire.** `Profile.albumId` exists with default `"time_image_10"` but has **no reader anywhere** in the launcher and is **not** copied from the DTO (`Profile(ProfileDTO)` constructor never calls `setAlbumId`). The official client never emits an `albumId` string either (zero hits in the binary). The background of the clock card is the TIME widget's `icon` field, full stop.
3. **CONFIRMED — there is NO full-screen "wallpaper page" via profiles.** The home screen is a horizontal `RecyclerView` strip of fixed-size cards (`HomeActivity.java:310`, `LinearLayoutManager(this, 0, false)`). The TIME card shows its `icon` as a rounded cover image at the left plus a blurred/dimmed copy as the card background (`TimeHolder.setImage` → `ClockCardBlurBackground.apply`). A built-in sample render of that card is 542×241 px (`scratchpad/lineos-imgs/res/Qi.png`), i.e. roughly a third of the 1424-px screen. A profile with only one widget shows one card on a dark background, not an edge-to-edge image.
4. **CONFIRMED — true full-screen image: only two mechanisms exist.** (a) one-shot `PREVIEW_SCREENSAVER` (30742) with an http(s) URL served by the Mac (already implemented in Deckhand); (b) a **separate screensaver APK** launched by `ScreensaverController` via an Android `VIEW` intent `screensaver://<host>/start?24h=…`. The launcher itself renders nothing for the screensaver; the image folder/format is private to that APK, which we do not have. Everything about "which folder the screensaver reads" is therefore **HYPOTHESIS** until we obtain that APK.
5. **CONFIRMED — there is no "get profiles" act, but there IS a cheap id/name listing**: `SCENE_DEPENDS_PROFILE` (30710) returns `[{label:<name>, value:<id>, last:true}]` for every stored profile. Widget contents cannot be read back. The official client never reads them: it owns the authoritative copy in its project database (`.umpf`, SQLite `UltraWorkSpaceProject`) and always deploys the full list.
6. **CONFIRMED and dangerous — the official client's asset upload wipes the whole external-files dir.** It POSTs `core_bar_assets.zip` to `http://<ip>:8080/upload/zip` with **no `subDir` and no `isFull` query** (neither string exists in the binary). Server defaults are `subDir=""`, `isFull="true"`, so `deleteDirFiles(getExternalFilesDir(null))` runs first. Any `wallpaper/…` folder Deckhand uploads is deleted the next time the official client deploys. Conversely Deckhand must never call `/upload/zip` without a `subDir`.
7. **CONFIRMED — the device never serves uploaded images back.** Static mounts are `/tgz → getCacheDir()` and `/module → filesDir/backup/module`; `/upload/zip` writes to `getExternalFilesDir(null)`, a different tree. `/upload?serialNo=` does write into `cacheDir/tgz/<serial>.tgz` (reachable as `http://<ip>:8080/tgz/tgz/<serial>.tgz`) but it requires a known module serial and triggers a VivoCube upgrade attempt, so it is not a usable file-hosting trick.
8. **CONFIRMED — `TRIGGER_PROFILE_CHANGE` (1103)** takes `data` = profile id string, replies `"ok"`/`"profile id error"`, switches the screen, and **pushes nothing** to the PC. The only unsolicited traffic is `act 1000000 PUSH_MESSAGE` for `METRIC`, `MODULE_STATE`, `PC_CONTROL`, `SET/GET_VOLUME`, `SET/GET_BRIGHTNESS`.

## Question A — `BATCH_SAVE_PROFILE` (1108) schema

### Handler chain (CONFIRMED)

- `common/communication/factory/MessageFactory.java` maps `BATCH_SAVE_PROFILE → new BatchProfileMessage()`.
- `common/communication/message/profile/BatchProfileMessage.java:15` — `ProfileManager.batchSave(messageContext.parseArray(ProfileManager.ProfileDTO.class))`; on success `success(iReply)` (reply `data:"success"`) then `reloadModuleProfile()` (re-binds module key maps and emits `ExitScreensaver`). On failure reply `code:-1, msg:"fail"`.
- `MessageContext.parseArray` (`message/base/MessageContext.java`) reads `jsonObject.getJSONArray("data").toJavaList(cls)`; a missing `data` array becomes an empty list, which **saves an empty profile list** — an easy way to brick the home screen. Never send 1108 without a non-empty array.
- `ProfileManager.batchSave` (`common/manager/ProfileManager.java:150-163`) maps every DTO with `toProfile()` and then `appData.setProfiles(list)` (line 421-424). Whole-list replace; no merge.
- `ProfileManager.toProfile` (lines 462-484): throws `ParamException("profile id cannot be empty")` if `id` is null/empty/`"null"`; throws `ParamException("item is not null")` if `widget` is null; null entries inside `widget[]` are filtered; each widget passes through `WidgetCoverRegistry.cover(profile, widget)`. A `ParamException` is reported back as `{code:-1, msg:<text>}` with the request id (`BusinessMessageProcessor.processing`, `catch (ParamException e2)`), and **nothing is saved** because the exception aborts the stream before `update()`.

JSON parsing is fastjson 1.2.83 (`com/alibaba/fastjson/JSON.java:52`). Property names are derived from getters/setters. Relevant consequence: the boolean field `isDefault` with accessors `isDefault()/setDefault()` is named **`default`** by fastjson; the key `isDefault` is still accepted on input because `JavaBeanDeserializer.smartMatch` strips a leading `is` (`JavaBeanDeserializer.java:884-940`, `str.startsWith("is") … substring(2)`). So send `"isDefault"` or `"default"`; the device would serialize it as `"default"`. Enum fields (`type`, `productId`, `player`) are serialized/parsed by **enum name**.

### ProfileDTO (CONFIRMED, `ProfileManager.java:111-148` + `common/bean/ProfileProperty.java`)

| key | type | default | required | notes |
|---|---|---|---|---|
| `id` | string | – | **yes** | non-empty, not `"null"`. Used by 1103 and by `TimeParamConverter` to find the existing profile. Device's own default profile has id `"default"` (`SharedPreferencesUtils.newDefaultProfile`). |
| `name` | string | null | no | shown in the on-device profile switcher (`ProfileAdapter`). |
| `icon` | string | null | no | profile tile image in the switcher; resolved by `GlideExtend.loadSmartCore` (http URL / `resId://` / relative path under external files dir / absolute path). Device default: `http://cdn.lifex360.com/ultrabar/desktop/default.png`. |
| `bgColor` | string | null | no | copied; no reader found for profiles. |
| `iconScale` | int | 0 → coerced to 100 | no | `Profile(ProfileDTO)` line 29. |
| `isDefault` / `default` | boolean | false | no | profile chosen on boot when no explicit selection (`SharedPreferencesUtils.getDefaultProfile`); falls back to the first profile. |
| `showName` | Boolean | true | no | |
| `module` | array of `ModuleConfig` | null → `[]` | no | `{serialNo, productId (DOT_KEY/KNOB_KEY/SENSE_CUBE/VIVO_CUBE/PC_BOOT), config}`; converted per product in `moduleConfigCovert` (lines 426-450). Send `[]` when you have no modules. SENSE_CUBE configs get fresh random ids on every save. |
| `widget` | array of widget items | – | **yes** (may be `[]`) | becomes `Profile.homeData`; order = left-to-right order on screen. |

Not accepted from the DTO (CONFIRMED): `albumId` (stays `"time_image_10"`, unread), `player` (stays `SONOS`), `homeData` (ignored; only `widget` is read).

### Widget item (CONFIRMED, `common/communication/bean/WidgetProperty.java` → `common/bean/HomeData.java` → `ProfileProperty`)

| key | type | notes |
|---|---|---|
| `id` | string | widget instance id. Built-in TIME/WEATHER use `sys.component.time` / `sys.component.weather` (`StaticID`); others are free-form but must be unique in the profile (used for targeted refresh). Keep the same id across saves so `TimeParamConverter` can preserve the on-device picked image. |
| `name` | string | card title where a card shows one. |
| `icon` | string | per-widget image (see "which widgets render `icon`" in F). Same resolution rules as above. |
| `bgColor` | string | no reader found. |
| `iconScale` | int | used by `PcControlHolder.process(bitmap, iconScale)` to scale a custom PC-control icon; stripped from 1002 replies. |
| `type` | `WidgetType` name | required in practice; `null` becomes `UNSUPPORTED` (`WidgetCoverRegistry.cover`). |
| `param` | object | type-specific; see F. Parsed by `Parameter.parseObj` which returns **null if `param` is not a JSON object** (so a missing `param` is tolerated at save time, but the holder may NPE at render — e.g. `WeatherHolder` casts `getParam()` to `WeatherParameter`). Always send an object for WEATHER/TIMER/WORLD_TIME/SOUNDSCAPE/SCENE/PC_CONTROL/HOT_KEY_GROUP. |
| `last` | Boolean | leaf marker in the 1002 tree; harmless to omit. `node`/`parentId` are `@JSONField(serialize=false, deserialize=false)` and ignored. |

The official client's strings confirm these exact keys in the deploy path: `widget` (UW:96/9366), `module` (UW:8651), `showName` (UW:8645), `iconScale` (UW:9078), `param` (UW:8554), `icon` (UW:8255), `name`/`last`/`type` (UW:7694-7696, the 1002 tree parser), `serialNo`/`productId` (UW:8712/8658), widget type names `TIME`, `WORLD_TIME`, `WEATHER`, `TIMER`, `SOUNDSCAPE`, `SCENE`, `HOT_KEY_GROUP`, `MEMORY`, `STORAGE`, `NETWORK`, `SENSE_CUBE_*`, `APPS` (UW:9040-9110).

### How the TIME background is resolved to a file (CONFIRMED)

- `TimeHolder.loadImage()` (`common/adapter/holder/TimeHolder.java:66`): `GlideExtend.loadSmartAsBitmap(ctx, mData.getIcon(), WidgetType.TIME)`; the result goes into `iv_cover` and `ClockCardBlurBackground.apply` (blur radius 22, 1/6 downscale, scrim `0x66000000`) becomes the card background. Default card background is `R.drawable.time_image_2` (`TimeBinder.bind`).
- `GlideExtend.loadSmartCore` (`common/utils/GlideExtend.java`): `http(s)://…` → network; `resId://<name>` → drawable by name; otherwise if the string does **not** start with `file://` or `/` → `new File(getExternalFilesDir(null), str)` if it exists, else Glide tries the raw string; if it starts with `file://` or `/` → absolute path, falling back to the same relative lookup.
- `TimeParamConverter` (`message/profile/convert/impl/TimeParamConverter.java`): on 1108, if the incoming TIME widget has an **empty `icon`**, the device copies the `icon` currently stored for the same `profile.id` + `widget.id`. So an empty icon means "keep what the user picked on the device", and to reset you must send an explicit `"resId://time_image_2"` (built-ins: `time_image_2,3,4,5,7,8,9,10,11`, `AlbumDataLoader.getXmlConfigDataInternal`).
- The device's own picker (`ui/activity/set/display/TimeImageActivity.java:381`) writes `homeData2.setIcon(resItem.getValue())` — exactly the same field — and user files appear there as absolute paths (`AlbumDataLoader.scanAndAddFiles`). Note the loader only lists `RES` items plus `DIRE` entries, and the static list contains no `DIRE` entry, so uploaded files **do not show up in the on-device picker** on this firmware.
- `/upload/zip?subDir=<x>&isFull=<b>` (`common/http/service/UploadServiceIns.java:206-235`): extracts into `getExternalFilesDir(null)/<x>/…` preserving zip folder structure, writing only `jpg|jpeg|png|webp|gif`, skipping `__MACOSX`/`.DS_Store`, rejecting path traversal; max 50 MB; then emits `ReloadProfileEvent("unzip icon")` which makes `HomeActivity` reload the current profile (so a re-upload of the same filename repaints without a 1108). Response body `{"state":200,"msg":"ok","data":<count of images written>}` (`HttpResult.onSuccess`), errors `{"state":-1,"msg":"…","data":null}`.
- Therefore the reference string for an uploaded file is the **relative path `"<subDir>/<file>"`** (e.g. `"deckhand/bg-home.png"`). CONFIRMED by code; the absolute path form also works but is device-specific (`/storage/emulated/0/Android/data/com.ultrabar.launch/files/<subDir>/<file>` is the usual Android location — HYPOTHESIS for the exact prefix).
- Image size: there is no dimension check anywhere. The cover is a rounded square and the blur fills the card, so any aspect works; the 1424×280 PNGs found in `lineos-imgs/res` (6V/SY/TF) are full-screen clock-face artwork, most likely screensaver skins rather than TIME-card covers (HYPOTHESIS). For the TIME card a roughly square or 5:1 image both look fine; what matters is that it is small (card is ~540×240 px).

### Minimal valid payloads

Page with a custom background on the clock card plus the clock itself (CONFIRMED structure). Upload first: `POST http://<ip>:8080/upload/zip?subDir=deckhand&isFull=false` with a zip containing `bg-home.png`.

```json
{"act":1108,"id":"<uuid>","data":[
  {"id":"default","name":"Standard Mode","isDefault":true,"showName":true,"iconScale":100,
   "icon":"http://cdn.lifex360.com/ultrabar/desktop/default.png",
   "module":[],
   "widget":[
     {"id":"sys.component.time","type":"TIME","name":"Time","icon":"deckhand/bg-home.png"},
     {"id":"sys.component.weather","type":"WEATHER","name":"Weather","param":{"lat":"","lon":""}}
   ]},
  {"id":"deckhand.page.2","name":"Deckhand","isDefault":false,"showName":true,"iconScale":100,
   "icon":"deckhand/page2-icon.png",
   "module":[],
   "widget":[
     {"id":"sys.component.time","type":"TIME","name":"Clock","icon":"deckhand/bg-page2.png"}
   ]}
]}
```

"Just a full-screen image" page: **not representable** (CONFIRMED, see summary §3). The closest profile-only approximation is a single TIME widget whose `icon` is your image (one card, blurred copy behind it). A true edge-to-edge image needs 30742 (one-shot) or the screensaver APK (D).

Reply on success: `{"act":1108,"code":200,"data":"success","id":"<uuid>","msg":null,"timestamp":…}`.

## Question B — reading profiles / avoiding clobber

- `GET_PROFILE_WIDGET` (1002) → `GetComponentMessage` → `ProfileManager.getComponentV3(parentId)`: returns the **catalogue** of placeable nodes (device tree under `sys.widget.iot`, apps under `sys.widget.apps`), not the stored profiles. `data` is a string parent id; the reply is a list of `WidgetProperty` with `iconScale` filtered out, sorted by name. Root ids: `"sys.widget.iot"` and `"sys.widget.apps"` (`getPrefixId`). An empty/unknown parent yields the children of the virtual root via `NodeFetcher` (HYPOTHESIS for the exact behaviour of `null`). Notably it does **not** enumerate TIME/WEATHER/PC widgets — those are known statically by the client (`CBBasicWidgetItem` list in the official binary: clock, worldClock, accuWeather, timer, whiteNoise; System: cpuUsage, memoryUsage, storageUsage, network speed; pcCtrl…).
- **No act returns stored profiles with widgets** (CONFIRMED by exhausting `MessageFactory` + `BusinessMessageProcessor`). The closest is `SCENE_DEPENDS_PROFILE` (30710, `message/scene/auto/depends/ProfileDependsMessage.java`): no input, reply `data:[{"label":"<name>","value":"<id>","last":true},…]` over `AppData.profiles`. Use it to (a) learn the ids/names currently on the device, (b) verify after a 1108 what was stored, (c) detect that someone else (official client, on-device edits) changed the set.
- How the official client avoids clobbering (CONFIRMED from strings): it does not read back. Profiles live in its project DB (`UltraWorkSpaceProject`, `ProjectDbBean`, `.umpf` file, `widgetConfigList`/`moduleConfigList`, `preferred`, `showName`), and "Deploy" writes the full list plus the asset zip. `Profile id not matched` / `invalid profile id:` errors are local consistency checks. Consequence: **the official client and Deckhand cannot co-own the device**; whichever deploys last wins, and on-device changes (time-image picker, HA device drops) are also overwritten by either client's next deploy, except for TIME icons that the client sends empty (preserved by `TimeParamConverter`).
- Recommended Deckhand model (HYPOTHESIS as policy, CONFIRMED mechanics): keep a local authoritative `profiles.json`; before each 1108, call 30710 and compare the id set with the local one; if they differ, warn and offer "adopt device ids" (names only, widgets unknown) or "overwrite". Always include the user's existing default profile id (`"default"` on a fresh device) so modules and the on-device switcher keep working.

## Question C — `TRIGGER_PROFILE_CHANGE` (1103)

CONFIRMED (`message/profile/ChangeProfileMessage.java`):

- Request `{"act":1103,"id":"<uuid>","data":"<profileId>"}` — `data` is a **plain string**, not an object.
- Looks up `AppData.profiles` by exact id. Unknown → `{"code":-1,"msg":"profile id error"}`. Known → `EventManager.triggerProfileChangeEvent(id, name)` then `{"code":200,"data":"ok"}`.
- Effects on device: `ProfileManager.triggerSwitchProfile` emits `ProfileChangeEvent(fromId, toId, name)` (no-op if already current) and `ExitScreensaver`; 500 ms later `SwitchModuleConfigEvent(id)` rebinds module key maps; `HomeActivity` reloads the card strip; `SharedPreferencesUtils` remembers `mProfileId` **in memory only** (not persisted — after reboot the `isDefault` profile is shown again; HYPOTHESIS that nothing else persists it, no writer found).
- Nothing is pushed back to the PC on a profile change (CONFIRMED: `PushType` usages are METRIC, MODULE_STATE, PC_CONTROL, SET/GET_VOLUME, SET/GET_BRIGHTNESS only). To know the current profile from the Mac you must track your own 1103 calls; on-device switches (the overlay `ProfilePanel`, or scene action `CHANGE_PROFILE`) are invisible to the client.
- Profile id format: any non-empty string; device default `"default"`; the official client uses its own ids (strings like `Default Profile` name + DB id; not recoverable from strings). Recommend `deckhand.<slug>` or UUIDs.

## Question D — screensaver route (`SET_COREBAR_CONFIG` / `BASE_SET`)

CONFIRMED mechanics:

- `SET_COREBAR_CONFIG` (30741) `data = {"type":"BASE_SET","value":{featureEnabled, lockTime, uri, packageName, ver}}` → `BaseSetReadWrite.set` casts `value` to `JSONObject` and stores it as `AppData.screensaver` (`message/generic/setting/impl/BaseSetReadWrite.java`). `GET_COREBAR_CONFIG` (30740) `{"type":"BASE_SET"}` returns it. `lockTime` enum names `TIME_30S, TIME_1MIN, TIME_2MIN, TIME_3MIN, TIME_4MIN, TIME_5MIN, NEVER`; default object is `{featureEnabled:false, lockTime:"NEVER", ver:1}` (`ScreensaverConfig()` constructor).
- `ScreensaverController.updateScreensaverConfig` (`common/service/ScreensaverController.java:290-303`): host = `uri` if `ver < 2`, else `packageName`; start intent = `VIEW screensaver://<host>/start?24h=0|1`, stop = `screensaver://<host>/stop`. Idle time = `clamp(20, 100, lockTime.seconds/60*20)` seconds (so `TIME_1MIN` → 20 s, `TIME_5MIN` → 100 s, `NEVER` → 100 s but see below). Note that `NEVER` still enables the timer if `featureEnabled` is true — disabling is done via `featureEnabled:false`.
- Which apps qualify (CONFIRMED, `common/utils/AppUtils.java:217-250`): an installed APK whose manifest `<meta-data>` has `ULTRABAR_APP_TYPE = "screensaver"` (→ `ver` 2, host = packageName) or `com.ultrabar.screensaver = "<host>"` (→ `ver` 1, host = that metadata value). The deprecated `ScreensaverActivity` wrote exactly `uri = metadata(com.ultrabar.screensaver)`, `packageName = pkg`, `ver = getScreensaverVer(pkg)` (`ScreensaverActivity.lambda$apply$1`). Screensaver apps are downloaded from the vendor store (`FetchVersion.fetchList(101, …)`, category 101) and installed as APKs.
- How to discover installed screensavers over the protocol (CONFIRMED): `GET_APP_LIST` (1000) with `data:"SCREENSAVER"` (or `"ALL"`) → `AppListRead` returns `[{application, appName, versionCode, versionName, icon, systemApp, isScreensaver, isConfig, configBtnName, port, sessionToken, allowProfile}]`. **Do this first on hardware**: it tells us the real `packageName` values present on the user's CoreBar. The official client reads the same list (`screensaver`, `allowProfile`, `iconUrl`, `package` strings at UW:9054-9060).
- What is NOT known (HYPOTHESIS territory): the launcher ships **no** screensaver renderer and no image folder convention. The 1424×280 PNGs in `lineos-imgs` (e.g. an "ASTEROID" digital-clock skin) look like screensaver artwork, but whether a store screensaver reads user images from `getExternalFilesDir` of *its own* package (which `/upload/zip` cannot reach — it only writes under `com.ultrabar.launch`'s external files dir) or from a shared folder is unknowable without that APK. The `/upload/zip` route cannot write into another package's private storage, so a "slideshow of my images" via a stock screensaver is **unlikely** unless the screensaver app explicitly scans the launcher's folder or shared storage. Exact zip `subDir` for a screensaver: **none established**.
- Practical use of this route today: enable/disable the existing screensaver and set its idle time; preview arbitrary media one-shot with 30742. Nothing more until a screensaver APK is pulled from the device (requires adb or the store URL from `FetchVersion`).

## Question E — can the device serve an uploaded file?

CONFIRMED (`common/http/config/WebServerConfig.java:15-16`, AndServer `StorageWebsite`):

- `/tgz/**` → `getCacheDir()` (e.g. `/data/user/0/com.ultrabar.launch/cache`). `/module/**` → `getFilesDir()/backup/module`. `StorageWebsite` serves `new File(rootPath, requestPath)` and falls back to an index file; no listing.
- `/upload/zip` writes to `getExternalFilesDir(null)` (external storage), which is **not** under either mount. Confirmed: no HTTP route reads from the external files dir; the earlier hardware test (preview of `http://<ip>:8080/…` failing) agrees.
- `/upload?serialNo=<sn>` writes `getCacheDir()/tgz/<sn>.tgz` (`UploadService.saveFile` with dir `"tgz"`, name `<serial>.tgz`, max 100 MB, extension check `.tgz` only) — that file **is** reachable at `http://<ip>:8080/tgz/tgz/<sn>.tgz` (the VivoCube is told to fetch exactly that URL, `UploadServiceIns.UpdateUI.process`: `String.format("http://%s:8080%s", ip, "/tgz/<sn>.tgz")`). But the handler first resolves `ModuleSupervisor.getModule(serial)` (throws for unknown serials) and then commands a VivoCube upgrade; the saved file keeps the `.tgz` name and content-type, so it cannot double as an image host. Not usable.
- `/widget/icon?id=&type=&scheme=` (`WidgetController.getICON`) only serves built-in drawables, `assets/static/icon/<id>.png` and installed-app icons — not uploaded files.
- Conclusion: keep Deckhand's `PreviewServer` (Mac serves the PNG) for 30742. For persistent profiles no HTTP hosting is needed because `icon` relative paths are read straight from disk.

## Question F — widget catalogue for the big screen

`WidgetType` enum (`common/enums/WidgetType.java`) and the render mapping (`common/adapter/HomeAdapter.java:85-181`, item types 5…705). CONFIRMED per type:

| `type` | renders on CoreBar | `param` schema (bean) | custom `icon`/image |
|---|---|---|---|
| `TIME` | yes (`TimeHolder`) | none | **yes** — `icon` = background/cover (any Glide-resolvable ref). |
| `WORLD_TIME` | yes | `{"offset":"<string>"}` (`WorldTimeParameter`); official client sends `timeZone` label internally but the wire key is `offset` | no reader of `icon`. |
| `WEATHER` | yes | `{"lat":"<str>","lon":"<str>"}` (`WeatherParameter`, strings parsed to double; empty → network location). API key / units are set separately via `INTEGRATED_CONFIG_SET` (1010) `{"packageName":"com.ultrabar.weather","config":{…apiKey, isUnitFahrenheit…}}` (official strings `apiKey`, `isUnitFahrenheit`, `com.ultrabar.weather`) | no. |
| `TIMER` | yes | `{"time":"HH:MM:SS","startSceneId":?, "endSceneId":?}` (`TimerParamter`); ids like `sys.countdown.10` from the 1002 tree need `com.ultrabar.countdown` installed | no. |
| `SOUNDSCAPE` | yes | `{"id":"sys.app.soundscape.1"}` (`WhiteNoiseParameter`); needs `com.ultrabar.whitenoise` | no. |
| `APPS` | yes (launch an app) | none; `id` = package name; icon comes from the installed app | no. |
| `SCENE` | yes | `{"type":"HA_SCENE"\|"LOCAL_SCENE"\|"ACTION","actions":[ActionConfig…]}` (`SceneWidgetParameter`) | **yes** (`SceneHolder.setSceneImageV2` loads `icon`). |
| `PC_CONTROL` | yes | `ParentControlParameter`: `{"output":5,"keys":[int…]}` = HID keyboard combo, or `{"output":10,"payload":<any>}` = TCP push to the Mac (`PUSH_MESSAGE` type `PC_CONTROL` with that payload) | **yes** (`PcControlHolder.updateUI`, scaled by `iconScale`); default icon `Constants.PC_CONTROL_WIDGET_DEF_ICON`. |
| `HOT_KEY_GROUP` | yes | `{"button":[RemoteChildren…]}` (`HotKeyGroupParamter`) — a group card that opens `RemoteActivity`; each child is a PC_CONTROL-like item | **yes** (`HotKeyGroupHolder.updateUI`). |
| `CPU`, `MEMORY`, `STORAGE`, `NETWORK` | yes (computer holders) | `{"data":"<string>"}` (`ComputerParameter`); values are fed by `PUSH_MESSAGE METRIC` queries from the Mac (`ScheduledQueryRegistry`) | no. |
| `PC_BOOT` | yes | `{"uid":"<module uid>"}` | no reader found. |
| `SENSE_CUBE`, `SENSE_CUBE_ALS/RADAR/TEMP/HUM/AUDIO` | yes | `{"uid":"<module uid>"}` | no. |
| `EMAIL_CARD` | yes | configured through 1500-1502 | no. |
| `AUDIO_PLAYER` | yes | `{"source":…}` (`AudioPlayerParameter`); id `sys.player.sonos|music|spotify` | no. |
| `TEMPERATURE_SENSOR`, `HUMIDITY_SENSOR`, HA device types (`SWITCH`, `LIGHT*`, `AC`, `FAN`, `CURTAIN*`) | yes (`DeviceV2Holder`) via HA ids from the 1002 tree | none | no. |
| `SET` | not in `HomeAdapter` switch → falls to default type 550 (`UnsupportedWidgetHolder`-like) | – | – |
| `UNSUPPORTED` | placeholder card | – | – |

So an "image button" page is achievable with `PC_CONTROL` cards (custom icon + name, press → HID keys or a push to Deckhand) and `SCENE` cards; a "picture" is achievable only as the TIME cover. There is no generic image/label widget.

## Recommended Deckhand implementation plan

Order is chosen so every step is reversible and verified before the destructive one.

1. **Read-only reconnaissance on hardware (no state change).** `30710` (profile ids/names), `1000` with `"ALL"` and `"SCREENSAVER"` (installed apps, real screensaver `packageName`), `30740 BASE_SET` (current screensaver config), `1002` with `"sys.widget.iot"` / `"sys.widget.apps"` (catalogue + confirms id formats). Record the raw replies; they define the baseline to restore.
2. **Backup before any 1108.** Because profiles cannot be read back, the only real backup is on the device: `adb` is not available, so instead *write down* the 30710 ids and make the first 1108 a **superset**: re-send the existing default profile (`id:"default"`, TIME+WEATHER, TIME `icon` empty so the device keeps the user's picked image — CONFIRMED behaviour of `TimeParamConverter`) plus one new Deckhand page. Verify with 30710 that both ids exist and that `1103 "default"` still works. (HYPOTHESIS to verify: that `module:[]` on the default profile does not break any KnobKey/DotKey bindings the user made with the official client — if the user has modules, ask before deploying.)
3. **Asset upload discipline.** Always `subDir=deckhand`, `isFull=false` for incremental adds; use `isFull=true` only on `subDir=deckhand` to garbage-collect. Never POST without `subDir`. Show a warning in the UI that the official client's "Deploy" erases the `deckhand/` folder (CONFIRMED default `isFull=true` with empty `subDir`); mitigate by re-uploading assets automatically before each page switch if a cheap probe fails — there is no probe, so simply re-upload (idempotent, small files) whenever Deckhand (re)connects. HYPOTHESIS to verify: PNG with alpha and WEBP both render in the TIME cover.
4. **Page switching.** `1103` with the stored id; treat `"profile id error"` as "device was re-deployed by someone else" → re-run step 1 and re-send 1108. Keep the "current page" state locally; it is not pushed by the device.
5. **One-shot preview stays as is** (Mac-hosted http URL, 30742, no ack).
6. **Screensaver.** Only expose enable/disable + idle time (`30741 BASE_SET` with the `packageName`/`uri`/`ver` values read in step 1 copied verbatim; CONFIRMED that `ver` decides which field is the host). Do not promise custom slideshow images until a screensaver APK has been analysed (HYPOTHESIS blocker).
7. **Future: obtain a screensaver APK** via the store list (`FetchVersion.fetchList(101,0,1000)` — endpoint in `common/utils/FetchVersion` not examined here) to learn whether any screensaver reads a user folder.

### Hardware verification checklist

- [ ] 30710 reply shape and the real ids on this device (CONFIRMED shape, unknown content).
- [ ] 1108 with `isDefault` key is accepted (fastjson smartMatch, CONFIRMED by code; still confirm).
- [ ] TIME `icon:"deckhand/bg.png"` renders after upload with `subDir=deckhand` (CONFIRMED path logic; confirm render + that re-upload repaints via `ReloadProfileEvent`).
- [ ] Switching with 1103 shows the new card strip and `ExitScreensaver` fires.
- [ ] `module:[]` on the default profile does not disturb existing module bindings (HYPOTHESIS).
- [ ] `GET_APP_LIST "SCREENSAVER"` lists the stock screensaver and its `packageName`; `30740` shows `ver` 1 or 2.
- [ ] Behaviour after an official-client Deploy: `deckhand/` folder gone (CONFIRMED by code), profile ids replaced.

## Evidence index (file:line)

- `common/manager/ProfileManager.java:111-148` (ProfileDTO), `:150-163` (batchSave), `:421-424` (setProfiles), `:462-484` (toProfile validation), `:266-278` (getComponentV3), `:413-415` (`sys.widget.*` ids).
- `common/bean/profile/Profile.java:14-34` (defaults, DTO constructor without albumId), `common/bean/ProfileProperty.java`, `common/bean/HomeData.java`, `common/communication/bean/WidgetProperty.java` (`@JSONField` exclusions).
- `common/communication/message/profile/BatchProfileMessage.java:15-19`, `ChangeProfileMessage.java:15-27`, `GetComponentMessage.java:22-34`, `scene/auto/depends/ProfileDependsMessage.java`.
- `common/communication/message/profile/convert/WidgetCoverRegistry.java` and `impl/*ParamConverter.java`; `common/bean/parameter/*.java` (param beans).
- `common/adapter/holder/TimeHolder.java:66-88`, `binder/ClockCardBlurBackground.java`, `binder/TimeBinder.java:528-532`, `PcControlHolder.java:95-115`, `HotKeyGroupHolder.java:72-90`, `SceneHolder.java:48-66`; `common/adapter/HomeAdapter.java:85-181, 486-548`; `ui/activity/HomeActivity.java:310, 336-348`.
- `common/utils/GlideExtend.java` (`loadSmartCore`), `common/utils/AlbumDataLoader.java:43-55, 80-99`, `ui/activity/set/display/TimeImageActivity.java:377-387`.
- `common/http/service/UploadServiceIns.java:32-34, 113-115, 117-182, 206-235`; `common/http/controller/UploadControllerUploadZipHandler.java` (defaults `subDir=""`, `isFull="true"`); `common/http/service/UploadService.java` (cacheDir/tgz); `common/http/config/WebServerConfig.java:15-16`; `common/http/controller/WidgetController.java`; `common/http/service/HttpResult.java`.
- `common/bean/ScreensaverConfig.java`, `common/service/ScreensaverController.java:80-91, 278-318`, `common/communication/message/generic/setting/impl/BaseSetReadWrite.java`, `impl/AppListRead.java`, `common/utils/AppUtils.java:32-33, 217-250`, `ui/activity/set/display/ScreensaverActivity.java` (`lambda$apply$1`).
- `common/communication/BusinessMessageProcessor.java` (reply/forward paths, ParamException → `code -1`), `common/init/GatewayHub.java:125-130` (PUSH_MESSAGE), `common/bean/PushMessage.java`, `common/utils/SharedPreferencesUtils.java:288-305, 320-330`.
- `com/alibaba/fastjson/JSON.java:52` (1.2.83), `parser/deserializer/JavaBeanDeserializer.java:884-940` (smartMatch `is` prefix).
- Official binary strings: `http://%1:8080/upload/zip` (UW:9372), `core_bar_assets.zip`/`CoreBarAssets` (UW:9360-9373), no `subDir`/`isFull`/`albumId` strings anywhere; widget keys UW:7694-7696, 8255, 8554, 8645, 8651, 8658, 8712, 9078; catalogue names UW:9030-9110; symbols `UM::MainProfileWidget`, `UM::ModuleVivoCubeProfileEditor`, `UM::CoreBarWidgetListPanel`, `UM::CBBasicWidgetItem`, `UM::CloudImagePicker` (`nm`). No `Album*`/`Screensaver*` classes exist in the binary.
