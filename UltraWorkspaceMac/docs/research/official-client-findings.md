# Official UltraWorkSpace 1.0.1.0 (macOS) — network behaviour reconstructed from the binary

Target: `/Volumes/UltraWorkSpace-V1.0.1.0-Installer/UltraWorkSpace.app/Contents/MacOS/UltraWorkSpace` (universal x86_64+arm64, Qt 6.5.3, nlohmann::json 3.11.3, OpenSSL 3; bundle id `com.sanytron.ultraworkspace.app`, `NSAllowsArbitraryLoads`, `NSLocalNetworkUsageDescription`). The binary is **not stripped of local symbols** (`UM::` namespace, 745 functions), so function names below are real. Offsets are arm64-slice virtual addresses (`0x1000xxxxx`); cstring offsets are x86 file offsets from `strings -t x`. Cross-checked against decompiled LineOS 1.0.9(9) (`lineos-src/.../com/ultrabar/launch`) and `quantum/link`.

Confidence tags: **CONFIRMED** = read directly from disassembly/literals (and usually matches firmware); **LIKELY** = strong inference from constants/control flow; **HYPOTHESIS** = plausible but not verified.

Working files (scratchpad `ocl/`): `strings.txt`, `cstring_x86.txt` (ordered __cstring dump, groups by source file), `nm.txt`, `um_methods.txt`, `dis_arm64.txt`, `annot3.txt` (per-function literal/constant/call listing), `qtcalls.txt` (resolved Qt stub calls per function), `cb_root_ca.crt`.

---

## Executive summary — top corrections/additions for Deckhand

1. **Discovery payload is wrong in PROTOCOL.md.** The official client broadcasts the plain 18-byte ASCII string `discovery.ultrabar` (not `{"act":"discover"}`) to the interface **broadcast address** (not 255.255.255.255) on UDP **5319**, every **2000 ms**, from a socket whose own replies it filters out; it parses `serialNo`, `ip`, `tcpPort` from the JSON reply (firmware `Announcer` also sends `ver`, `name:"ultrabar"`). CONFIRMED (`CoreBarSearcher::sendBroadcast` 0x1001af79c, `onReceivedDatagram` 0x1001af994; `NetworkUtils::broadcastAddress` uses `QNetworkAddressEntry::broadcast()`).
2. **Pairing request body:** `{"act":101,"id":"<n>","data":{"id":"550e8400-e29b-41d4-a716-446655440000","name":"Ultra WorkSpace"}}` — a **hard-coded fixed UUID** and the display name; there is **no `clientType`** anywhere in the binary. Reply must have `code==200` and `data.state` truthy, token is `data.token`. Timeout 15 s ("authorize on the Core Bar within 15 seconds"). CONFIRMED (0x1001adab0–0x1001adb48, 0x1001aded0, 0x1001ae010).
3. **Re-auth:** `{"act":100,"id":"<n>","data":"<token>"}` (bare string, no object), 3 s timeout; success = `code==200`. Token is stored **encrypted (custom `SecureCipher`, SHA-based key + base64) in the project's SQLite `json_store` host row** (`connType, name, ip, port, sn, token`), i.e. per project file (`*.umpf`), not in Keychain. CONFIRMED.
4. **TLS:** `QSslSocket::connectToHostEncrypted(ip, port)` with the embedded **root CA `:/file/cb_root_ca.crt`** (self-signed, CN=`ultrabar.local`, O=sanytron, RSA-4096, valid 2026-07-07 → 2126-06-13, extracted to `ocl/cb_root_ca.crt`) added via `addCaCertificate`, `setProtocol(...)`, **`setPeerVerifyMode(...)` + `ignoreSslErrors()`** → effectively no verification; a `QNetworkProxy(NoProxy)` is forced. No SNI string is set explicitly. Deckhand's TOFU pin is stricter than the vendor; consider also accepting that CA. CONFIRMED (`CoreBarConnectionTcp::CoreBarConnectionTcp` 0x1001a64e4ff).
5. **Framing / ids / keep-alive:** messages are `\n`-terminated JSON (`write` appends `0x0a`, `read` splits on `0x0a` and trims). `id` is a **decimal string from a global counter** (`std::to_string(++counter)`). Request object order: `id, act, data` (plus `code`, `msg` only on replies). Heartbeat: `{"act":20,"id":..}` every **3 s** when ≥1.5 s since last RX; link declared dead after **15 s** without RX; reconnect retried every **30 s**; timer tick 1 s. CONFIRMED (`CoreBarDevice::onTimer` 0x1001a82c8–0x1001a83dc).
6. **Deploy order ("Deploy project" button, `ProjectManager::deployProject`, runs on a worker thread, each step awaited):** (1) wipe local temp `CoreBarAssets` dir → (2) **30300 SET_GATEWAY_CONFIG** with `{canGateway:{endpoints:[…]},meshGateway:{endpoints:[…]}}` built from *all* DB module beans (5 s timeout) → (3) **1108 BATCH_SAVE_PROFILE** with the array of all profiles (8 s) → (4) **1010 INTEGRATED_CONFIG_SET** per integration bean (AccuWeather, 8 s) → (5) **30500 BATCH_CREATE_SCENE** with all automations (8 s) → (6) zip the temp assets dir and **POST `http://<ip>:8080/upload/zip`** (multipart `file`, filename `core_bar_assets.zip`, **no `subDir`/`isFull` query** → firmware unzips into the external-files root with `isFull=true` wiping only what the zip's top-level dir already contains... see §2) → (7) on success toast + **1103 TRIGGER_PROFILE_CHANGE** with the currently selected profile id. No read-back before writing: the PC owns the authoritative copy. CONFIRMED.
7. **Profile DTO on the wire (1108 `data` = array):** `{id, name, showName, icon, iconScale, default, widget:[…], module:[{productId, serialNo, config}]}` — key list recovered from x86 `makeDeployData` (0x1001d3320–0x1001d3700); firmware `ProfileManager.ProfileDTO`/`toProfile` requires non-empty `id` and non-null `widget`, and fastjson maps `default`→`isDefault`. `widget[]` items are the card `deploymentData` objects `{id, type, name, icon, iconScale, param}`; local icons are rewritten to `file://…/CoreBarAssets/image/<uuid>.png` (`CoreBarCard::convertDeployIconIfNeeded`, `CoreBarUtils::makeImageAssetsFilePath`). CONFIRMED/LIKELY (see §4).
8. **VivoCube pipeline is as we had it, with exact numbers:** button icon stored at **240 px** (raw icon → `scaled(240*scale%)`, pressed = 0.8×), preview 120 px (so the panel is 240×240 — HIGH confidence); LVGL bin header word = `(w<<10)|(h<<21)|(hasAlpha?5:4)`, RGB565 big-endian + optional alpha byte, RGBA8888 source — identical to PROTOCOL.md; `config.json = {"defaultLayer":L,"layers":[{"id":..,"items":[{"id":W,"type":T}]}]}`, files `com_res<W>/default.bin|pressed.bin`, ustar + gzip, POSTed as field `file`, filename **`config.tgz`**, `application/octet-stream`, to `http://<ip>:8080/upload?serialNo=<moduleSn>`. Reply `state`: 200 ok, 1 = "not connected to the network", 2/4 = "busy", 3 = other error. The *same* layer/widget config is also persisted on the CoreBar inside the module endpoint `extraConfig.dataConfig` via 30300. CONFIRMED.
9. **Input events:** the CoreBar never pushes raw key/knob events; the PC receives `{"act":1000000,"id":"sys.push-…","data":{"type":T,"payload":P}}` and **must reply** `{"act":1000000,"id":<same>,"code":200,"data":{"type":T,"payload":<value>}}`. Types handled: `TEST`, `PC_CONTROL` (payload `{action, params}` with actions `openFile{path}`, `openBrowser{url}`, `startApp{path,launchMode}`, `inputText{text}`, `execCmd{cmd}`), `SET_VOLUME`/`GET_VOLUME`/`SET_MUTE`/`GET_MUTE`/`SET_BRIGHTNESS`/`GET_BRIGHTNESS`, `CPU`/`MEMORY`/`STORAGE`/`NETWORK` (`{totalReceived,totalSent}`). Hot-keys are **not** sent to the PC (device emits USB-HID itself); the client only ships HID key-code lists in the profile. CONFIRMED.
10. **Module OTA (30400/30401) fully reconstructed:** file format `UBX-OTA-FILE` (64-byte header, MD5 over header[0:36]+payload — verified on `Sence.Cube_V2_ota.bin`), 30400 `{gatewayType, epSn, fileSize, packSize, fileMD5}` (12 s timeout), then 30401 `{gatewayType, packNumber, isEndPack, data:<hex>}` per pack; result codes 0 ok / 1 reboot-timeout / 2 start-timeout / 254 data-timeout / 255 other. See §7.

Other notable additions: act **30102/30104/1635** are consumed as pushes by dialogs; **1617** (knob device tree), **1205** (scene action tree), **30700–30752** (automation/app-capability trees), **30600/30601** (APK install/uninstall with progress push), **30730** (module online state) are all used. Cloud endpoints are on `gatewayssl.dev.aiks360.com` (icon library, app store, plugin store). An `/upload/zip` of `CoreBarAssets/image/*.png` is the only "big screen" asset path the vendor uses; **no wallpaper/screensaver/PREVIEW_SCREENSAVER (30742) usage exists in the client** — only the screensaver *app* appears in the app list (`"screensaver"` filtered in `CBAppWidgetGroup::onDataChanged`).

---

## 1. `act` codes the client sends / handles

Numeric immediates found in each `UM::CoreBarApi::*` body right before `CoreBarMessage` construction (`mov wN,#imm; str wN,[sp+…]`), plus pushes it listens for. Reply timeout (ms) = 2nd arg of `CoreBarDevice::addMessageListener`.

| act | name (LineOS) | client function | request `data` (keys in client order) | timeout | tag |
|---|---|---|---|---|---|
| 20 | HEARTBEAT_PACKAGE | `CoreBarDevice::onTimer` | none/null | – (fire&forget) | CONFIRMED |
| 100 | AUTH | `connectAndAuth` $_4 | `"<token>"` (plain string) | 3000 | CONFIRMED |
| 101 | REQ_AUTH_TOKEN | `connectAndAuth` $_5 | `{"id":"550e8400-e29b-41d4-a716-446655440000","name":"Ultra WorkSpace"}` → reply `data.state`, `data.token` | 15000 | CONFIRMED |
| 1000 | GET_APP_LIST | `getAppList` | – | 5000 | CONFIRMED |
| 1002 | GET_PROFILE_WIDGET | `getWidgetList(dev, profileId)` | profile id string | 5000 | CONFIRMED |
| 1010 | INTEGRATED_CONFIG_SET | `deployAppConfig` | integration config object (AccuWeather: `packageName:"com.ultrabar.weather"`, `apiKey`, `lat`, `lon`, `metric`/`isUnitFahrenheit`…) | 8000 | CONFIRMED (keys LIKELY) |
| 1103 | TRIGGER_PROFILE_CHANGE | `setCurrentProfile` | profile id string | 5000 | CONFIRMED |
| 1108 | BATCH_SAVE_PROFILE | `deployProfiles` | array of profile DTOs (§4) | 8000 | CONFIRMED |
| 1205 | SCENE_ACTION_V2 | `getSceneActionTree(dev, parentId)` | string (tree node id) | 5000 | CONFIRMED |
| 1617 | GET_KNOB_FUNCTION_DEVICE | `getKnobCtrlDeviceTree(dev, s)` | string | 5000 | CONFIRMED |
| 1633 / 1634 | START/STOP_SCAN_WIFI | `startScanWifiList` / `stopScanWifiList` | – | 5000 | CONFIRMED |
| 1635 | CUBE_SCAN_WIFI_LIST_RESULT | `ScanWifiDialog` listener | push; items `{name, signal, frequency:"GHZ_2_4G"}` | – | CONFIRMED |
| 30100 / 30101 | MODULE_START/STOP_DISCOVERY | `startDiscoveryModule(dev,"can"|"mesh")` | `"can"` or `"mesh"` | 5000 | CONFIRMED |
| 30102 | MODULE_START_DISCOVERY_REPLAY | `ModuleAddDialog*::onModuleListReceived` | push; array of `{interfaceType, serialNumber, productId, netId?, …}` | – | CONFIRMED |
| 30103 | GATEWAY_SUB_PAIRING | `pairMeshModule(dev, address, netId)` | `{address, …}` | 5000 (dialog waits 30 s) | CONFIRMED |
| 30104 | GATEWAY_PAIRING_RESULT | `onModulePairResult` | push `{serialNumber, errorCode}` | – | CONFIRMED |
| 30200 | MODULE_PROPERTY_READ | `readProperty(dev, sn, deviceId, propertyId, extra)` | `{serialNo, deviceId, propertyId, extra}` → reply `data.result` / `data.error` | 5000 | CONFIRMED |
| 30201 | MODULE_PROPERTY_WRITE | `writeProperty` | `{serialNo, deviceId, propertyId, value}` | 5000 | CONFIRMED |
| 30300 | SET_GATEWAY_CONFIG | `deployCoreBarConfig` | `{canGateway:{endpoints[]}, meshGateway:{endpoints[]}}` | 5000 | CONFIRMED |
| 30400 / 30401 | MODULE_OAT_START / DATA | `startEpOTA` / `sendEpOTAData` | §7 | 12000 / none | CONFIRMED |
| 30500 | BATCH_CREATE_SCENE | `deployAutoConfig` | array of automation `deployData` | 8000 | CONFIRMED |
| 30600 | APP_MANAGER | `downloadAndInstallApk` / `uninstallApk` | `{type:"INSTALL"|"UNINSTALL"?, appType, packageName, …}` | 5000 | CONFIRMED (type values LIKELY) |
| 30601 | APP_MANAGER_PROGRESS_EVENT | `StoreAppInstallDialog` | push `{packageName, type:"DOWNLOAD"|"INSTALL"|"STATUS", result}` | ∞ | CONFIRMED |
| 30700 | SCENE_GET_TRIGGER_PARAM | `getAutoTriggerTypes` / `getAutoTriggerChildData(dev,int,json)` | – / child query | 5000 | CONFIRMED |
| 30730 | QUERY_MODULE_STATE | `getModuleOnlineState(dev, vector<sn>)` | array of serials | 5000 | CONFIRMED |
| 30750 / 30751 / 30752 | THREE_CAPABILITY_ACTION/PARAM/OPTION | `getAppCapabilityActions(pkg)`, `…Params{actionId,packageName}`, `…ParamValues{actionId,packageName,describeId,cursor,limit,params}` | | 5000 | CONFIRMED |
| 1000000 | PUSH_MESSAGE | `CBCmdUseCase::onReceiveMessage` via global listener | §6 | – | CONFIRMED |

**Not used by the official client** (present in firmware): 1300 GET_DEVICE, 1204, 1500–1502 email, 20100 reboot, 30701–30721 (only 30700 root is called; children via `getAutoTriggerChildData`), **30740/30741/30742 (CoreBar config / screensaver preview)**. The client never reads config back from the device except 1000/1002/1617/1205/30700/30750-2 (catalogue reads) and 30730 (online state).

Reply handling: every `CoreBarApi` lambda checks `msg.act == <same act>` and `code == 200` (error 6001 "CoreBar reply error", 6000 "Request api timeout"). `CoreBarMessage::decode` reads `id, act, code, msg, data`.

## 2. HTTP routes

CoreBar (port 8080, `HttpUploader::uploadFile`, QHttpMultiPart form-data, part header `form-data; name="%1"; filename="%2"`, content-type `application/octet-stream`; timeouts: connect, stall ("no progress"), total):

| route | used by | multipart | notes | tag |
|---|---|---|---|---|
| `POST http://<ip>:8080/upload?serialNo=<moduleSn>` | `ModuleVivoCubeLayer::onClickBtnDeploy` | field `file`, filename `config.tgz` | VivoCube layer package. Reply JSON `{state, msg, data}`; client maps `state` 200→ok, 1→"VivoCube is not connected to the network.", 2 and 4→"VivoCube is currently busy.", else "Upload error: <msg>". Firmware: `UploadServiceIns.uploadConfig` → `Module.upgrade("http://<ip>:8080/<path>")`, VivoCube pulls the file itself (needs Wi-Fi), 5 s wait. | CONFIRMED |
| `POST http://<ip>:8080/upload/zip` | `ProjectManager::deployProject` lambda3 | field `file`, filename `core_bar_assets.zip` (built by `ZlibUtils::packToZip` from `<temp>/CoreBarAssets`) | **No query string**: firmware defaults `subDir=""`, `isFull=true` → `deleteDirFiles(externalFilesDir)` is attempted on the whole external-files root(!) then unzip-with-structure; the zip root folder is `CoreBarAssets/` with `image/<uuid>.png` inside (`CoreBarUtils::getLocalTempCoreBarAssetsDir`, `writeDeployImageFile`). Icons are referenced on-device as `file://<externalFilesDir>/CoreBarAssets/image/<name>.png`. Triggers `ReloadProfileEvent("unzip icon")`. | CONFIRMED |
| `GET http://<ip>:8080/widget/icon?type=&id=&scheme=` | not called by the client (firmware `WidgetController.getICON`, schemes ID/HOME_TYPE/APPLICATION/PLAYER) | | HYPOTHESIS that Deckhand could use it for previews | – |
| `http://<ip>:<port>?sessionToken=<tok>` | `AppLocalItem::openDashboard` ("Web UI") | | opens an installed app's web UI (port/token from app list `config.sessionToken`) | CONFIRMED |

Cloud (`UM::HttpClient`, header `Accept-Language: <Settings::getLanguage>`, `Content-Type: application/json` on POST):

| URL | purpose | params | tag |
|---|---|---|---|
| `https://gatewayssl.dev.aiks360.com/api/v1/base-service/pub/icon/tags/locales/allGrouped` | icon library tag groups (`group`/`category`/`iconStyle`) | – | CONFIRMED |
| `…/pub/icon/v2/page` | icon library page | `pi`, `ps`, `keyword`, `projectId`, `groupId`, `categoryId`, `iconStyleId` → `{state,data:{current,total,records:[{path,…}]}}` | CONFIRMED |
| `…/pub/apps/100/fetchListV2`, `…/pub/apps/100/<id>/fetchLastVerV3` | CoreBar app store list / latest version (`fileUrl`, `sha256`, `versionName`, `versionCode`, `packageName`, `appType`) | | CONFIRMED |
| `…/pub/plugin/page` | PC plugin store (zip packs with `config.json`, types `Widgets`/`Images`) | | CONFIRMED |

Image cache: `<cache>/ImageCache/manifest.tsv`.

## 3. VivoCube deploy pipeline

Code: `ProjectModuleUseCase::buildVivoCubeExtraConfig` (0x1000fbc70–0x1000fc8a8), `buildVivoCubeWidgetFile`, `buildVivoCubeWidgetButtonFile`, `PixmapToLVGLBinUtils::pixmapToLVGLBin` (0x1000fde48), `ZlibUtils::createTarFromDirectory/writeTarHeader/gzipCompress`, `VivoCubeWidgetButton::updateWidgetInfoFromUI` (0x10010d908), `VivoCubeImageEditor`.

Module bean `extraConfig` (stored locally and sent in the 30300 endpoint) = `{"netConfig":{"ssid","password"},"dataConfig":{"layers":[{"id","name"?,"default":bool,"widgets":[{"id","uniqueId","name","type"(1=Button,2=Toggle: typeId),"icon","iconScalePercent","iconUnpressed","iconPressed"}]}]}}`. CONFIRMED keys: `netConfig, ssid, password, dataConfig, layers, default, items, widgets, type, defaultLayer, iconUnpressed, iconPressed, rawIcon, unpressedIcon, pressedIcon, uniqueId, typeId, iconScalePercent`. Limits: "Maximum of %1 layer items" / "%1 widget items" (values not recovered).

Build (`buildVivoCubeExtraConfig(bean, buildFiles, outTgzPath)`):
1. dir = `<tempDir>/vivoCube-build-<moduleId>/config` (deleted & recreated).
2. For each layer: `config.layers[]={"id":L,"items":[{"id":W,"type":T}, …]}`; `defaultLayer` = id of the layer whose `default` is true. Written to `<dir>/config.json`. (`items` carry only `id` and `type`; everything else lives in the .bin files.) CONFIRMED.
3. Per widget `buildVivoCubeWidgetFile(dir, productId, W, T, json)`: only `type==1 (button)` is supported ("unknown widget type: %1" otherwise) → `<dir>/com_res<W>/default.bin` + `pressed.bin` from DB images `widget/<W>/unpressedIcon` and `widget/<W>/pressedIcon`. CONFIRMED.
4. `packDirectoryToTarGz(dir, "<dir>.tgz")`: custom ustar writer (`%07o` mode/uid/gid, `%011o` size/mtime, `%06o` chksum + NUL + space, magic `ustar`, 512-byte blocks) then zlib `deflateInit2(…, 31, …)` gzip. The checksum field uses `%06o` + `\0` + ` ` (standard) — our `EmulateVendorChecksumBug` flag is not needed. LIKELY.
5. Upload `config.tgz` (see §2). The client **also** calls `ProjectHostUseCase::deployConfig` (30300) after Wi-Fi config writes so the CoreBar holds the same `dataConfig`.

Image sizes (`updateWidgetInfoFromUI`): `raw.scaled(QSize(240*p/100, 240*p/100))` with p = `iconScalePercent` (slider 10–100, default 60) → **unpressed**; **pressed = unpressed scaled by 0.8**; both after `UIHelper::trimPixmapTransparentBorder`. Double constants 0x406e000000000000 = **240.0**, 0x3fe999999999999a = **0.8**, preview label 120×120 inside a 160×160 "screenPanel" (`setScaledIconPixmap` uses 120.0). **Display resolution target: 240×240 — HIGH confidence** (consistent with the 11-bit width/height header fields and the 2:1 preview).

`pixmapToLVGLBin` (CONFIRMED, matches PROTOCOL.md exactly): `QImage::Format_RGBA8888` (17); scan all pixels, `hasAlpha = any A != 0xff`; `bpp = hasAlpha?3:2`, flag `5`/`4`; per pixel bytes `((R & 0xF8) | (G >> 5))`, `(((G << 3) & 0xE0) | (B >> 3))`, then `A` if hasAlpha (RGB565 **big-endian**); header `u32 LE word = flag | (w<<10) | (h<<21)` (`bfi w23,w9,#10,#11; bfi w23,w21,#21,#11`), `u32 LE size = w*h*bpp`, inserted at offset 0 and 4.

Wi-Fi (ModuleVivoCubeNetwork): `readProperty(sn, deviceId **256**, propertyId <P1>)` → hex string decoded with `hexStringToByteArray` → ssid/password ("wifiConfig"); `writeProperty(sn, 256, <P1>, hexString)` after `updateVivoCubeConfig` + `deployConfig`; `readWifiState` → int state 0 Not configured / 1 Connected / 2 Not connected / 3 Connecting (strings). Property id numbers not recovered from the listing (HYPOTHESIS: 6 = wifi as in our table).

## 4. CoreBar profile pipeline

Local model (SQLite `json_store`, record types `profile`, `profileCbWidget`, `module`, `host`, `plugin`, `auto`, `integration`, `meta`; `file_store(owner_id,file_name,data BLOB)` holds PNGs: `profile_icon`, `widget_icon`, `widget/<id>/{rawIcon,unpressedIcon,pressedIcon}`, `profile/<pid>/<key>-promptIcon`).
- Profile bean `data`: `{name, showName, icon, preferred, widgetConfigList:[], moduleConfigList:[]}` (`ProjectDbProfileBean` ctor 0x1000e91c0). The profile id is the row id (`getProfileId`), name uniqueness "New Profile %1".
- Widget bean (`profileCbWidget`, k1 = profileId): `{uid, name, icon, widgetType, deploymentData}` where `deploymentData` is produced by each card (`CoreBarCard::getDeploymentData`).
- Module bean (`module`): `{gatewayType:"can"|"mesh", productId, name, sn, netId, workMode, extraConfig:{…, profiles:{<profileId>:{config}}}}` — per-profile module configs are stored under `extraConfig.profiles[profileId]` (SSO literal `profiles` + key `config` at 0x1001cbbd0/0x1001d2ed0).

**Wire DTO (`makeDeployData`, x86 0x1001d3320–0x1001d3700, in emission order):**
```
{ "id": "<profileId>", "name": …, "showName": bool, "icon": "<file://…/CoreBarAssets/image/<x>.png | http… | resId://…>",
  "iconScale": int, "default": bool(preferred), 
  "widget": [ <deploymentData of each profileCbWidget, local icons rewritten> ],
  "module": [ {"productId": <int>, "serialNo": "<sn>", "config": <extraConfig.profiles[profileId].config>} ] }
```
Firmware `ProfileManager.toProfile` → `Profile(ProfileDTO)` (sets icon,name,default,bgColor,iconScale→100 if ≤0,id,module,showName) and `homeData = widget.map(WidgetCoverRegistry.cover)`; `batchSave` **replaces** `AppData.profiles` wholesale. CONFIRMED. (`bgColor` is accepted by the firmware but never sent by the client.)

Widget `deploymentData` shapes (CONFIRMED key sets from `CoreBarCard*::updateConfig/initConfig`):
- Basic: `{id:<shortUuid>, type:"TIME"}`; `{type:"WORLD_TIME", name, param:{timeZone? offset:"GMT+0:00"}}`; `{type:"WEATHER", name, param:{latitude, longitude}}`; `{type:"TIMER", name, param:{time:"h:m:s", hour,min,sec}}`; `{type:"SOUNDSCAPE", name, param:{soundId:"sys.app.soundscape.1", soundName}}`.
- PC control: `{type:"PC_CONTROL", name, icon, iconScale, param:{action, params}}` with the same OS-control action objects as §6 (`typeId`: hotKey/inputText/openFileOrFolder/openBrowser/startApp/execCmd; plus `cpuUsage|memoryUsage|storageUsage|network` → types `CPU|MEMORY|STORAGE|NETWORK`).
- Plugin / shortcut group: `{type:"HOT_KEY_GROUP", name, icon, iconScale, pluginUuid, param:{button:[…]}}` (`CBPluginWidgetGroup::createTitleExtWidget`); icons exported from the plugin zip (`exportPCCtrlGroupIcons`).
- Multi-action: `{type:"SCENE", name, icon, iconScale, param:{type:"ACTION", deployData:{actions:[…]}}}` (`actionList`).
- Module cards: `{type:"SENSE_CUBE_TEMP|SENSE_CUBE_HUM|SENSE_CUBE_ALS|SENSE_CUBE_AUDIO|SENSE_CUBE_RADAR|SENSE_CUBE(temp&hum)", name, param:{moduleUid}}`, `{type:"PC_BOOT", name, param:{moduleUid}}`.
- Apps: `{type:"APPS", name, param:{package}}` (icon from `iconUrl`; `allowProfile` filter; `screensaver` app hidden). Home Assistant: `{type:"HA_SCENE", name, icon, iconScale, param:{…}}` (IoT list via `sys.widget.iot`).
`GET_PROFILE_WIDGET` (1002) returns the placeable tree (`WidgetProperty{id,name,icon,type,param,last,node}`) with `iconScale` filtered out.

Icons: picked from the cloud library or local file → `trimPixmapTransparentBorder` → zoom slider (`CoreBarCardIconEditor`, preview 100 px, default 50 %) → saved as **PNG** in `file_store` (`QPixmap::save(..,"PNG")`), exported unscaled into `CoreBarAssets/image/<uid>.png` at deploy; the on-device scale is carried as `iconScale`. The big-screen page size is never hard-coded in the client (1424×280 only matters on-device).

Order of operations and read-back: see summary item 6. There is **no** read-back of profiles (no act lists them); `1002/1617/1205/30700/30750` are catalogue reads only. After deploy the client calls 1103 with the selected profile. Module config edits (knob/dot/sense/vivo editors) only write the local DB (`ProjectModuleUseCase::updateConfig`) — nothing reaches the device until "Deploy project".

Automation (30500): array of `ProjectDbAutoBean.deployData` = `{uuid, name, icon, enabled, type:"AUTO", triggers:[{type, desc, params}], actions:[…]}` (CONFIRMED keys; from `AutoMainWindow`/`AutoTriggerSelector`).

## 5. Discovery / pairing / auth differences

- UDP: `QUdpSocket` bound once; `QTimer` 2000 ms → `writeDatagram("discovery.ultrabar", 18, <broadcast of current IPv4 interface>, 5319)`; falls back to `QHostAddress::Broadcast`. Replies from own addresses (`Any`, `LocalHost`, own IP) ignored; keyed by `serialNo` (`qHash`) to dedupe; UI shows SN + IP; "Manual" entry also possible (IP regex `^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}…$`, port). Firmware `Announcer.getBroadcast()` = `{"serialNo","ver":"1.0.9(9)","ip","name":"ultrabar","tcpPort":7431}`. CONFIRMED.
- Host record: `{connType:"tcp"|"usb", name, ip, port, sn, token}`; only `tcp` is implemented ("unsupported connType"). The `usb` value and `QtSerialPort` linkage hint at a future USB transport (USB/HID bridge) — HYPOTHESIS.
- Connect workflow (`Workflow::then` ×3): connect (socket error → "failed to connect core bar") → if token: decrypt + act 100 (3 s) else skip → if no/invalid token: act 101 (15 s, UI text "Please authorize it on the [Core Bar] within 15 seconds.") → store `SecureCipher::encryptString(token)` in host bean. States: Offline / Connection… / Online.
- TLS: see summary 4. QSslSocket, `QSsl::SslProtocol` set (value not recovered; LIKELY `TlsV1_2OrLater`), peer verification disabled + `ignoreSslErrors`, custom CA added anyway. No client certificate.
- Discovery is only active while the "Search Core Bar" dialog is open (`showEvent` → `start`, `onClose` → `stop`).

## 6. Input handling (KnobKey / DotKey / SenseCube) and PUSH_MESSAGE

Inbound (`ProjectManager::registerGlobalMsgListener` → `CBCmdUseCase::onReceiveMessage`, CONFIRMED):
- `data.type == "TEST"` → reply `makeReply(msg, 200, data)`.
- `data.type == "PC_CONTROL"` → `OSCtrlUseCase::onReceiveMessage(payload)`: `payload.action ∈ {openFile(path), openBrowser(url), startApp(path, launchMode), inputText(text), execCmd(cmd)}`, `payload.params` holds the args. (No `hotKey` branch: hot-keys are emitted by the CoreBar over USB-HID.)
- `isExtCmd(type)` for `GET_VOLUME, SET_VOLUME, GET_MUTE, SET_MUTE, GET_BRIGHTNESS, SET_BRIGHTNESS, CPU, MEMORY, STORAGE, NETWORK` → `OSCtrlUseCase::onReceiveMessage2` → `sendExtCmdReply(dev, msg, {type, payload})` = `{"act":1000000,"id":<same>,"code":200,"data":{"type":T,"payload":V}}`. Volume/brightness payload int 0–100 (`OSControllerMac::setVolume` clamps to 100, uses CoreAudio), NETWORK payload `{totalReceived, totalSent}`.
- Firmware side: `PcVolumeController` (knob `ModalType.PC_VOLUME`) sends `GET_VOLUME` at start and every 5 s (1 s wait), `SET_VOLUME <int>` on each knob step; it reads the reply's `data.payload`. Push ids are `sys.push-<uuid>`.

Profile bindings written by the client (CONFIRMED key sets):
- KnobKey (`ModuleKnobKeyProfileEditor::saveConfig`): module config `{button:{click|doubleClick|longPress…}, knob:{turnLeft:{enabled, deviceName, deviceId, deviceType}, turnRight:{…}}}` where the device comes from act 1617 tree (`{name, type, id}`; firmware `KnobDevice{id,type:ModalType}` with `PC_VOLUME`, `PC_BRIGHT`, `LOCAL_VOLUME`, `AUDIO_PLAYER`, `LIGHT_*`, `AC`, `CURTAIN`, `FAN`); firmware field names are `clockwise`/`counterclockwise` (`KnobConfig.Detail{button, clockwise, counterclockwise}`) — the client literals contain both `turnLeft/turnRight` (UI ids) and `clockwise/counterclockwise` (0x1002c9...); LIKELY mapping turnRight→clockwise.
- DotKey (`ModuleDotKeyProfileEditor`): per button `button1..3` → `{keyCode, singleClick|doubleClick|longPress:{enabled, show(promptEnabled), name(promptText), icon(promptDialogBg), actions:[…]}}` via `MainSceneActionConfigWidget::getProfileSceneActionConfig` (`actionList` → `actions`, each action `{type, name, objectParams, values:[{param,value}], deployData}`; types `PC_CONTROL`, `VIVO_CUBE_TOGGLE`, `PLUGIN_WIDGET`, `APP_CAPABILITY`). Firmware `KeyCodeConfig extends ModuleClick{singleClick,doubleClick,longPress: ClickEvent(Scene){show,…}}`.
- SenseCube (`TapDetailConfigPanel`): `{detail:[{mode:1..5, enabled, show, actions…}]}` ("Tap Rhythm" modes `mode1..mode5`, 500 ms intervals preview).
- VivoCube (`ModuleVivoCubeProfileEditor`): per widget `{uniqueId, widgetType, keyCode?, click events…}` = firmware `VivoCubeCodeConfig extends KeyCodeConfig{widgetType}`.
- Hot-key definitions: `SceneOSCtrlHotKey` → `{type:"hotKey", objectParams:{output, keys:[hid codes], keysDesc}}`; HID table in `HotkeyHidTable` (USB usage ids 4..115, 224..231 modifiers, media/system keys Power 102, Sleep 103, Wake 104…). The DotKey "Action List" entries flow into the scene `actions` array; the CoreBar executes them (HID keystrokes locally; PC_CONTROL via push).
- Online state badge: `getModuleOnlineState` (30730) with the list of module serials; `ON_RECV_MODULE_ONLINE_ST` event.

## 7. OTA, screensaver, store, misc

**Module OTA** (`ModuleOTADialog`, `ModuleOTAUtils::checkOTAFile`, `CoreBarApi::startEpOTA/sendEpOTAData`; firmware `ModuleOtaStartMessage`, `QLinkGateway`, `QLinkCanGateway`), CONFIRMED unless noted:
- File: `*.bin`, size must be ≥ 64 and (client check) < 256 KiB; header (64 B): `[0:12]="UBX-OTA-FILE"`, `[12:16]=productId u32 BE` (Sence.Cube_V2: 0x10000004 = SENSE_CUBE; must equal the module's productId else "Product ID mismatch"), `[16:32]=versionName` (NUL-padded, "V2"), `[32:36]=versionCode u32 BE` (2), `[36:52]=MD5`, `[52:64]=reserved 0`. **MD5 = md5(file[0:36] + file[64:])** (verified: `0b560699…9fb5`) — mismatch → "Invalid file signature". Dialog shows "Version Name / Version Code / File Size / MD5".
- 30400 `data = {gatewayType:"can"|"mesh", epSn:"<moduleSn hex>", fileSize:<int>, packSize:<int>, fileMD5:"<hex>"}`; client timeout 12 s; reply `data={epSn, err}`: 0 ok, 1 "Reboot module timeout.", 2 "Start OTA timeout.", 255 other. Firmware reboots the endpoint, waits ≤8 s for boot event, 1 s, then sends CAN cmd 17 with `{sn, fileSize(u32), packSize(u8), md5}`; so **packSize ≤ 255**. The dialog sets packSize from the gateway type (`ModuleOTADialog` ctor: 200 after the `"can"` compare, 32 otherwise) — LIKELY `can=200`, `mesh=32`.
- 30401 `data = {gatewayType, packNumber:<0-based int>, isEndPack:<bool>, data:"<hex of ≤packSize bytes>"}` (CAN cmd 18 = `{packNumber u32, bytes}`); device replies per pack `{epSn, err}` with 0 ok / 254 timeout (2 s, or 5 s for the last pack; 2 retries) / 255 other ("Signature verification failed." is shown for one of the non-zero codes, LIKELY 255 on the end pack). Client sends packs sequentially on a worker thread (`WaiterUtils::waitOnce` up to 10–20 s each), updates progress "packNumber:%d/%d", then "Upgrade succeeded.".
- Firmware OTA file is pulled by the CoreBar itself only for VivoCube layer packages; module firmware always streams over 30401.

**App store / APK**: 30600 `{type:"INSTALL", appType, packageName, url?…}` after the cloud `fetchLastVerV3` lookup (fields `fileUrl`, `sha256`, `versionCode`); progress pushes 30601 `{packageName, type:"DOWNLOAD"|"INSTALL"|"STATUS", result}` (states `DOWNLOADING, INSTALLING, INSTALLED, NOT_INSTALLED, FAIL`); uninstall 30600 `{type:"UNINSTALL"?, packageName}` (exact `type` literal LIKELY). App list (1000) items: `{packageName, appName, versionName, versionCode, systemApp, iconUrl, allowProfile, config:{port, sessionToken}}`.

**Screensaver / wallpaper**: the client has **no** code path for 30740/30741/30742, `BASE_SET`, `lockTime`, or any wallpaper upload; the only "screensaver" reference hides that app from the APPS widget list. Deckhand's screensaver work has no vendor counterpart to mirror (the firmware launcher UI drives it).

**Plugins** (`ProjectPluginUseCase`): zip packs from the plugin store or local, `config.json` with `uuid, type ("Widgets"|"Images"), name, author, official, versionCode, pack`, unzipped under `<app>/plugin/<uuid>`; provide `HOT_KEY_GROUP` shortcut-group widgets and icon packs.

**Project file**: `*.umpf` SQLite (`UltraMate Project`), meta `create_app_version_name/code`, `project_data_format_version`; recent list `recent_project_list.json`; settings `settings.json` (`theme`, `en_US`/`zh_CN`, autostart via `~/Library/LaunchAgents/*.plist` with `--autostart`); single-instance lock `/tmp/UltraWorkSpace_ProcessLock_9F2A7C1E4B8D3F0A.lock`; log `log.txt`.

**Module add/replace**: Pogo-pin ("can") dialog: 30100 `"can"` → 30102 list rows `{interfaceType, serialNumber, productId, netId, workMode, isAdded, selected}` → assigns a free `netId` ("Module exceeds count limit") → `saveNewModules` → immediately 30300 `deployConfig`. Mesh dialog: 30100 `"mesh"` → 30103 `{address:<serialNumber>, netId}` (wait dialog 30 s; errors: "Mesh gateway is busy", "Network configuration timeout/failed", "AppKey configuration timeout/failed", "Pairing timeout") → 30104 `{serialNumber, errorCode}` → save + 30300. Endpoint objects sent in 30300: `{interfaceType:"can"|"mesh", uid:<sn>, name, serialNumber:<sn>, workMode, productId, netId, extraConfig}` (CONFIRMED order 0x1000ffe1c–0x10010016c). Product ids/names: DOT_KEY/KNOB_KEY/VIVO_CUBE/SENSE_CUBE/PC_BOOT.

---

### Items we could not pin down (for hardware verification)
- Exact `QSsl::SslProtocol` enum value passed to `setProtocol` and `PeerVerifyMode` value (treated as "verification off" because `ignoreSslErrors()` is called unconditionally).
- VivoCube Wi-Fi property ids and the hex layout of the `wifiConfig` value.
- `30600` `type` literal for uninstall, and `appType` enum.
- Whether `state` in the 101 reply is compared to `1` or just non-zero (`cmp w8,#1` after reading it).
