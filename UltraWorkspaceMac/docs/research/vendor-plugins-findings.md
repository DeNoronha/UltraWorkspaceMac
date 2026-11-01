# Vendor plugin packs ("hotkey packs") — format findings and Deckhand import spec

Scope: the 9 official plugin packs of the UltraBar X desktop client, downloaded from the vendor CDN (`Fetched/vendor-cloud/plugins/*.zip`, SHA-256 of every zip matches the `sha256` in `docs/research/vendor-cloud/plugin-catalog.json` — CONFIRMED), read-only analysis of `config.json` + icon files. Firmware behaviour is quoted from the earlier decompile notes (`device-first-findings.md` §F, `corebar-pages-findings.md` §F, `corebar-screen-findings.md`, `official-client-findings.md` §4/§6/§7); nothing below was executed from the zips. Every claim is tagged **CONFIRMED** (seen in the files or in the decompiled code quoted by those notes) or **HYPOTHESIS**.

Snapshot date 2026-11-01. Extraction scratch: `/private/tmp/claude-501/-Users-ramondenoronha-DEV-DNC-UltraWorkspace/68f0bc0a-0901-470c-814a-2f01c9c757db/scratchpad/vendor-plugins/` (`x/<pack>/` = unzipped packs, `tools/summary.json` = machine-readable per-pack inventory, `tools/tables.md` = all decoded shortcut tables).

## 0. Summary (what matters for the importer)

1. **CONFIRMED — one format, nine packs.** Every zip is flat (no top-level folder): `config.json` at the root plus zero or more image folders. `config.json` is UTF-8 without BOM, CRLF line endings, valid strict JSON (no trailing commas, no comments), key order `button, identifier, name, icon, homepage, versionName, versionCode, author, description`. Button key order `id, icon, type, name, spanSize, param`.
2. **CONFIRMED — exactly two action kinds exist in the wild.** `param = {"output":5,"keys":[HID usage ids]}` (5 packs, 145 buttons: Word, Excel, Windows, Photoshop, OBS, Zoom) and `param = {"output":10,"payload":{"action":"openBrowser"|"inputText","params":{"url"|"text":…}}}` (3 packs, 95 buttons: Website, AI Website, Emoji). No other `output`, no other `payload.action`, no other button `type` except one typo (`"Center"` in Excel). `spanSize` is only ever `1` or `2`. `iconScale` never appears in a pack.
3. **CONFIRMED — "open a website" is not a key sequence**, it is a PC push: `{"output":10,"payload":{"action":"openBrowser","params":{"url":"https://…"}}}`. The CoreBar forwards the payload verbatim to the connected PC client (`PUSH_MESSAGE` type `PC_CONTROL`); the official client's `OSCtrlUseCase` dispatches on `payload.action ∈ {openFile, openBrowser, startApp, inputText, execCmd}`. Deckhand must implement `openBrowser` and `inputText` to make 3 of the 9 packs work; a pack like Emoji depends entirely on the Mac being connected.
4. **CONFIRMED — every HID pack is authored for Windows.** 224 (LCtrl) is the main modifier in Word/Excel/Photoshop/OBS; Zoom uses 226 (LAlt) = Zoom's Windows defaults; Windows pack uses 227 (LGUI = Windows key). No pack is macOS-specific. Importing 1:1 on a Mac would type Ctrl+C instead of Cmd+C. Deckhand needs a translation layer (§3.3) and should mark the vendor packs "Windows layout".
5. **CONFIRMED — icon references are `file://<path relative to zip root>` or absolute `http(s)://cdn.lifex360.com/...` URLs**; 48 of 240 buttons point at the CDN (the whole Windows pack has no local files at all). Local paths use three layouts: `icon/`, a second folder (`excel/`), and the zip root (`file://01_bold.png` in Word). The pack-level `icon` is also either http or `file://` (Excel: `file://excel/excel.png`).
6. **CONFIRMED — icons are 256×256 RGBA PNGs** (bit depth 8, colour type 6) in 219 of 227 files; the exceptions are 128×128 (2), 512×512 (1) and a few 257–348 px wide non-square variants. Two visual styles: white glyph on transparent (OBS, Photoshop, Zoom "353.png", Word bold…), and full-colour brand logos / blue line icons (Website, AI Website, Emoji, Word/Excel `icon/`).
7. **Data-quality bugs in the vendor packs that the importer must survive**: duplicate button ids (Photoshop, 2 pairs), a non-enum `type:"Center"` (Excel), unreferenced files (Website 6, Excel 2, Emoji 1, Photoshop 4, AI Website 2), wrong shortcuts (Excel "Superscript"=Ctrl+E, "Format Cell"=Ctrl+I; Word/Excel "Screenshot" = `Alt+N+S` which is a Windows KeyTips *sequence* encoded as a simultaneous chord), `RShift` (229) used where `LShift` was meant, trailing space in a name (`"Perplexity AI "`), Github button linking to the brand page.

## 1. Manifest schema (all packs)

### 1.1 Keys seen

Top-level object (9/9 packs have all nine keys — CONFIRMED):

| key | type | present | values seen | notes |
|---|---|---|---|---|
| `button` | array of Button | 9/9 | 9–64 items | order = display order (2-span items are listed first in Zoom/OBS/AI Website) |
| `identifier` | string | 9/9 | 32 chars `[A-Za-z0-9]` | equals the catalogue `identifier`; the official client unzips into `<app>/plugin/<uuid>` keyed by it (official-client-findings §7) |
| `name` | string | 9/9 | "OBS Hotkey Plugin" … | equals catalogue `name` |
| `icon` | string | 9/9 | 8× `http(s)://…png`, 1× `file://excel/excel.png` | pack icon; the catalogue carries its own `icon` which differs from the in-zip one for 6 packs (CDN re-upload) |
| `homepage` | string | 9/9 | always `""` | |
| `versionName` | string | 9/9 | always `"v1.0.0"` | |
| `versionCode` | integer | 9/9 | always `1` | |
| `author` | string | 9/9 | `"Sanytron"` (8), `"sanytron"` (1) | |
| `description` | string | 9/9 | one sentence | equals catalogue `desc` |

Button object (240/240 buttons have exactly these six keys — CONFIRMED; no `iconScale`, no `bgColor`, no `pluginUuid`, no `keysDesc`):

| key | type | present | values seen |
|---|---|---|---|
| `id` | string | 240/240 | 32-char alnum, same alphabet as `identifier`; **not unique** in Photoshop (`rR2zG7fH…` used by Eyedropper + Direct Selection, `zD1jL8aW…` by Rectangular Marquee + Crop) |
| `icon` | string | 240/240 | `file://<relpath>` (192) or `http://cdn.lifex360.com/icon/…png` / `https://sslcdn.lifex360.com/icon/…png` (48); never empty, never `resId://` |
| `type` | string | 240/240 | `"PC_CONTROL"` (239), `"Center"` (1, Excel row 26 — a copy/paste error, its `param` is a normal hotkey) |
| `name` | string | 240/240 | 1–31 chars, UTF-8 (Japanese `楽天市場`), may have trailing space |
| `spanSize` | integer | 240/240 | `1` (228), `2` (12: 3 each in Zoom, OBS, AI Website, always the first three buttons) |
| `param` | object | 240/240 | one of the two shapes below |

`param` shapes (CONFIRMED, exhaustive for these packs):

| shape | `output` | other keys | count | packs |
|---|---|---|---|---|
| HID keyboard | `5` | `keys`: array of 1–3 integers, each a USB HID keyboard usage id (4–82 or 224–229) | 145 | Word 36, Excel 39, Windows 25, Photoshop 23, OBS 9, Zoom 13 |
| PC push | `10` | `payload`: `{"action":"openBrowser","params":{"url":string}}` (31) or `{"action":"inputText","params":{"text":string}}` (64) | 95 | Website 22, AI Website 9, Emoji 64 |

Catalogue-only fields (not in the zip): `id` (40–48), `file` (zip URL), `sha256`, `icon`, `preview[]` (one screenshot PNG each), `official:1`, `pluginType:0`, `regionIds:["1","10","20"]`, `desc`. The official client's own on-disk plugin manifest is documented as `{uuid, type:"Widgets"|"Images", name, author, official, versionCode, pack}` (official-client-findings §7) — that is the *client's* wrapper record, not this zip format; **HYPOTHESIS**: the client maps `identifier → uuid`, `button[] → pack`, and `type:"Images"` packs (icon libraries) exist in the store API but none of the 9 current records is one (`pluginType` is 0 for all).

### 1.2 JSON Schema (draft 2020-12) — describes the vendor format as observed

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://deckhand.denoronha.nl/schemas/vendor-plugin-pack.json",
  "title": "UltraBar X plugin pack config.json (vendor format, as observed 2026-11)",
  "type": "object",
  "required": ["button", "identifier", "name", "icon", "versionName", "versionCode", "author", "description"],
  "properties": {
    "identifier": { "type": "string", "pattern": "^[A-Za-z0-9]{32}$" },
    "name": { "type": "string", "minLength": 1 },
    "icon": { "$ref": "#/$defs/iconRef" },
    "homepage": { "type": "string" },
    "versionName": { "type": "string" },
    "versionCode": { "type": "integer", "minimum": 1 },
    "author": { "type": "string" },
    "description": { "type": "string" },
    "button": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/button" } }
  },
  "additionalProperties": true,
  "$defs": {
    "iconRef": {
      "type": "string",
      "description": "file://<path relative to the zip root> | http(s)://… ; observed only .png",
      "pattern": "^(file://[^\\\\]+|https?://.+)$"
    },
    "button": {
      "type": "object",
      "required": ["id", "icon", "type", "name", "spanSize", "param"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "icon": { "$ref": "#/$defs/iconRef" },
        "type": { "type": "string", "enum": ["PC_CONTROL"], "$comment": "one vendor pack contains the typo \"Center\"; importers coerce unknown types with a PC_CONTROL-shaped param to PC_CONTROL" },
        "name": { "type": "string" },
        "spanSize": { "type": "integer", "enum": [1, 2] },
        "param": { "oneOf": [ { "$ref": "#/$defs/hidParam" }, { "$ref": "#/$defs/pushParam" } ] }
      },
      "additionalProperties": true
    },
    "hidParam": {
      "type": "object",
      "required": ["output", "keys"],
      "properties": {
        "output": { "const": 5 },
        "keys": { "type": "array", "minItems": 1, "maxItems": 8, "items": { "type": "integer", "minimum": 0, "maximum": 255 },
                  "$comment": "USB HID Keyboard/Keypad usage ids; 224-231 are modifiers; observed max length 3 (modifiers + 1 key), one 'Alt+N+S' chord" }
      },
      "additionalProperties": false
    },
    "pushParam": {
      "type": "object",
      "required": ["output", "payload"],
      "properties": {
        "output": { "const": 10 },
        "payload": {
          "type": "object",
          "required": ["action", "params"],
          "properties": {
            "action": { "type": "string", "enum": ["openBrowser", "inputText", "openFile", "startApp", "execCmd"],
                        "$comment": "openBrowser and inputText observed in packs; the other three are dispatched by the official client (OSCtrlUseCase) but not used by any pack" },
            "params": { "type": "object" }
          }
        }
      },
      "additionalProperties": false
    }
  }
}
```

Observed `params` per action (CONFIRMED): `openBrowser → {"url": string}` (always absolute `https://`), `inputText → {"text": string}` (one emoji, sometimes with a trailing U+FE0F variation selector). From the official client (CONFIRMED key names, official-client-findings §6): `openFile → {path}`, `startApp → {path, launchMode}`, `execCmd → {cmd}`.

## 2. Per-pack inventory

All packs: `homepage:""`, `versionName:"v1.0.0"`, `versionCode:1`, `author:"Sanytron"` (Emoji: `"sanytron"`), catalogue `official:1`, `pluginType:0`, `regionIds ["1","10","20"]`, one `preview` PNG on the CDN. "Folder layout" lists what is inside the zip besides `config.json`.

| id | name | identifier | buttons | span 2 | output | folder layout | image inventory | icon refs (file / http) | oddities |
|---|---|---|---|---|---|---|---|---|---|
| 40 | Website | `jY9xS9aV4tK8fM9jT8zG0oA5wY7zC1lB` | 22 | 0 | 10 `openBrowser` ×22 | `icon/` (21 PNG, one named `楽天市場_24.png`, UTF-8 flag set in the zip) | 18× 256², 2× 128² (`youtube.png`, `website.png`), 1× 272×256 | 15 / 7 | 6 unreferenced files (`website, instagram, X, youtube, google, facebook.png` — the buttons use CDN copies instead); Github URL is the brand-logo page |
| 41 | Word | `fX9zP3iD9bC0oV9mA1dL8uA7nY7lX6xO` | 36 | 0 | 5 ×36 | `icon/` (21 PNG, blue line icons) **plus 15 PNG at the zip root** (`01_bold.png`…`15_go_end.png`, white glyphs) | 36× 256² | 36 / 0 | root-level icons referenced as `file://01_bold.png`; `Zoom In` uses RShift (229) |
| 42 | Excel | `qY4yG3nZ5bN1lH7zS9qH6pY5bT7iL5cE` | 39 | 0 | 5 ×39 | `icon/` (21 PNG, identical set to Word) + `excel/` (20 PNG incl. pack icon `excel.png`) | 41× 256² | 39 / 0 | pack `icon` is `file://excel/excel.png`; button 26 has `type:"Center"`, name "Superscript", keys Ctrl+E; "Format Cell" = Ctrl+I (should be Ctrl+1); "Align Right" and "Fill Right" both Ctrl+R; 2 unreferenced (`excel/19_superscript.png`, `20_subscript.png`) |
| 43 | Emoji | `iG7bD1gV5zN7oH6rX4tA0xJ7wC5mS3kO` | 64 | 0 | 10 `inputText` ×64 | `icon/` (65 PNG, numeric names `1.png`…`44.png` and `24-1.png`…`44-1.png`) | 64× 256², 1× 314×256 (`37.png`, unreferenced) | 64 / 0 | relies entirely on the PC client typing the text |
| 44 | Windows | `wM2xD0nG9vO2qG9vM5eA8kD1hG9yH8gU` | 25 | 0 | 5 ×25 | **no files** (zip = config.json only, 1.9 KB) | – | 0 / 25 | all icons on `cdn.lifex360.com`; two buttons share one icon URL; uses 227 (Windows key) ×16 |
| 45 | Photoshop | `yR8tG4sF8fG0eF0cE9hA6tF1fS7vJ6bU` | 23 | 0 | 5 ×23 | `icon/` (17 PNG, numeric, white glyphs) | 17× 256² | 13 / 10 | **2 duplicate ids**; 4 unreferenced files (`6, 8, 16, 17.png`); 10 single-letter tool shortcuts (OS-neutral) |
| 46 | AI Website | `jF0hT7nS0eA9zY6hA3mL1zX0sI1iY5sD` | 9 | 3 | 10 `openBrowser` ×9 | `icon/` (10 PNG) | 6× 256², 257×256, 258×256, 348×256 (`perplexity-fill.png`), 512² (`manus.png`) | 8 / 1 | 2 unreferenced (`AI.png`, `deepseek-copy-copy.png`); `"Perplexity AI "` trailing space |
| 47 | OBS Hotkey Plugin | `yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ` | 9 | 3 | 5 ×9 | `icon/` (8 PNG, pinyin names, white glyphs ≈104 px glyph in 256 canvas) | 8× 256² | 8 / 1 (`Redo` on CDN) | none |
| 48 | ZOOM Hotkey Plugin | `zG0pN6aV1pF6yM5uX2qV0cH1cC0aK5gJ` | 13 | 3 | 5 ×13 | `icon/` (13 PNG, pinyin names + `353.png`) | 10× 256², 269×256, 272×256, 276×256 | 13 / 0 | Alt-based = Zoom for Windows |

Catalogue vs manifest (CONFIRMED): `name`, `identifier`, `author`, `desc/description`, `versionName/versionCode` agree for all nine; the catalogue `icon` URL differs from the in-zip `icon` for Website, Word, Excel, Windows, AI Website (CDN `attach/2026/08/…` vs the zip's URL) and is identical for Emoji, Photoshop, OBS, Zoom. The catalogue's `preview[]` and `sha256` have no counterpart inside the zip. Deckhand's marketplace record should therefore be the catalogue row + the manifest, keyed by `identifier`.

## 3. HID usage table and shortcut decoding

### 3.1 Usage ids actually used (55 distinct — CONFIRMED)

| usage | key | usage | key | usage | key | usage | key |
|---|---|---|---|---|---|---|---|
| 4–29 | `a`–`z` (every letter is used except 20 = `q`) | 30–39 | `1`–`0` (only 34 = `5` used) | 40 | Enter | 41 | Esc |
| 43 | Tab | 44 | Space | 45 | `-` | 46 | `=` |
| 47 | `[` | 48 | `]` | 49 | `\` | 51 | `;` |
| 55 | `.` | 58 | F1 | 59 | F2 | 61 | F4 |
| 64 | F7 | 74 | Home | 75 | PageUp | 76 | Delete (forward) |
| 77 | End | 78 | PageDown | 79 | Right | 80 | Left |
| 81 | Down | 82 | Up | 224 | Left Ctrl | 225 | Left Shift |
| 226 | Left Alt | 227 | Left GUI (Win / Cmd) | 229 | Right Shift (Word/Excel "Zoom In" only) | | |

Not used by any pack: 42 Backspace, 57 CapsLock, 70–73, 83+ keypad, 101 Application, 102+ power/media, 228/230/231 right-hand Ctrl/Alt/GUI, consumer-page media keys. The official client's `HotkeyHidTable` covers usages 4..115 and 224..231 plus Power 102/Sleep 103/Wake 104 (official-client-findings §6) — CONFIRMED range, so a Deckhand pack may use the full keyboard page; whether the firmware sends consumer-page (volume/play) usages through this path is unknown (HYPOTHESIS: no — `keys[]` is a keyboard report).

Semantics (from the firmware notes, CONFIRMED there): `output:5` → the CoreBar hub emits HID keyboard events over its USB connection to the PC on TAP, repeats with a 700 ms heartbeat while LONG_PRESS_DOWN, releases on LONG_PRESS_RELEASE; the Mac client is not involved. `keys[]` order is irrelevant for simultaneous combos (packs mix `[224,225,x]` and `[225,224,x]`). **HYPOTHESIS**: all listed usages are sent in one report (modifier bitmask + up to 6 keys), so `Alt+N+S` (Word/Excel "Screenshot") presses N and S together instead of the Windows KeyTips sequence Alt, N, S — that button is broken even on Windows.

### 3.2 Decoded shortcuts per pack (Windows reading, as authored)

Full tables for all 240 buttons are in `tools/tables.md` in the scratch folder; the hotkey packs are reproduced here because the macOS translation depends on them.

**OBS** (all Ctrl): Reset Transform `[224,21]` Ctrl+R · Edit Transform `[224,8]` Ctrl+E · Stretch to Screen `[224,22]` Ctrl+S · Center to Screen `[224,7]` Ctrl+D · Fit to Screen `[224,9]` Ctrl+F · Move Up `[224,82]` Ctrl+Up · Move Down `[224,81]` Ctrl+Down · Undo `[224,29]` Ctrl+Z · Redo `[224,28]` Ctrl+Y.

**Zoom** (all Alt, = Zoom for Windows defaults): Start/stop video `[226,25]` Alt+V · Mute/unmute `[226,4]` Alt+A · Screen share `[226,22]` Alt+S · Raise hand `[226,28]` Alt+Y · Switch camera `[226,17]` Alt+N · Local recording `[226,21]` Alt+R · Cloud recording `[226,6]` Alt+C · Participants `[226,24]` Alt+U · Chat `[226,11]` Alt+H · Full screen `[226,9]` Alt+F · Speaker view `[226,58]` Alt+F1 · Invite `[226,12]` Alt+I · Push to Talk `[44]` Space.

**Word** (36): Ctrl+C/X/V/Z/Y/S, Ctrl+Shift+S (Save As), Ctrl+O/N/P/F/H/A/W, F1, F7, Zoom In `[224,229,49]` Ctrl+RShift+\ (not a real Word shortcut), Zoom Out `[224,225,45]` Ctrl+Shift+-, Ctrl+K, Ctrl+Alt+M (comment), `[226,17,22]` Alt+N+S (screenshot, KeyTips sequence), Ctrl+B/I/U, Ctrl+5 (strikethrough), Ctrl+Shift+= (superscript), Ctrl+= (subscript), Ctrl+Space (clear format), Ctrl+L/E/R/J (align), Ctrl+] / Ctrl+[ (font size), Ctrl+Home / Ctrl+End.

**Excel** (39): the first 21 are byte-identical to Word's first 21 (same icons, same keys — the Zoom In/Out, Comment and Screenshot entries are Word's, not Excel's); then Ctrl+B/I/U, Ctrl+L (Align Left — not an Excel default), "Superscript" `[224,8]` Ctrl+E (type `"Center"`, icon `05_align_center.png` → this row was meant to be "Center"), Ctrl+R (Align Right), "Format Cell" Ctrl+I (should be Ctrl+1 `[224,30]`), AutoSum `[226,46]` Alt+=, Fill Down Ctrl+D, Fill Right Ctrl+R, Insert Row/Col Ctrl+Shift+=, Delete Ctrl+-, New Line in Cell `[226,40]` Alt+Enter, Ctrl+Home, Ctrl+End, Ctrl+G, Ctrl+PageDown / Ctrl+PageUp.

**Windows** (25): Ctrl+Y, Ctrl+F, F2, Shift+Delete, Alt+Tab, Alt+F4, Win+D/Up/Down/Left/Right, Win+Ctrl+F4, Win+L/E/I/R, Win+Shift+S, Win+G, Ctrl+Shift+Esc, Win+X, Win+. (emoji), F1, Win+P, Ctrl+R, Win+V.

**Photoshop** (23): Shift+Ctrl+A (Camera Raw), Ctrl+U, Ctrl+I, Ctrl+Shift+U, B, Ctrl+Shift+R, Shift+Delete (content-aware fill), Ctrl+M, Ctrl+B, Ctrl+L, Ctrl+Shift+N, Ctrl+; , Ctrl+Shift+X, V, H, T, G, E, I, A, L, M, C.

### 3.3 macOS vs Windows — what a 1:1 import would do on a Mac

CONFIRMED facts: the CoreBar types HID usages; macOS maps 224→Control, 226→Option, 227→Command. So every `224` combo arrives as Control+key (which in most Mac apps does nothing or something else), and the Windows pack's `227` combos arrive as Command+key (Win+D "show desktop" becomes Cmd+D "bookmark"/"duplicate"). No pack carries a platform flag; none is macOS-specific.

Translation rules for the importer (HYPOTHESIS — standard macOS conventions, not from the files; verify per app on hardware):

| Windows chord in pack | generic macOS rule | known app exceptions (per pack) |
|---|---|---|
| `224` Ctrl + letter/digit/punct | → `227` Cmd + same key | Word Mac: Redo = Cmd+Y OK; Strikethrough Cmd+Shift+X (not Cmd+5); Insert Comment Cmd+Option+A; Zoom In/Out have no default; Screenshot (KeyTips) has no equivalent. Excel Mac: Format Cells Cmd+1; Go To Ctrl+G (Fn+F5) — Cmd+G is "find next"; New Line in Cell Option+Cmd+Enter (Control+Option+Return); Next/Prev sheet Option+Right/Left or Ctrl+PageDown works. Photoshop Mac: Cmd+… for all; Shift+Delete → Shift+Delete still works (Fill). OBS Mac: Cmd+R/E/S/D/F/Up/Down/Z, Redo = Cmd+Shift+Z (not Cmd+Y). |
| `224,225` Ctrl+Shift | → `227,225` Cmd+Shift | see above (OBS redo, Excel insert row = Cmd+Shift+= ok) |
| `224,226` Ctrl+Alt | → `227,226` Cmd+Option | |
| `226` Alt + key | app-specific — **do not** blindly map to Option | Zoom Mac: video Cmd+Shift+V, mute Cmd+Shift+A, share Cmd+Shift+S, raise hand Option+Y, switch camera Cmd+Shift+N, local rec Cmd+Shift+R, cloud rec Cmd+Shift+C, participants Cmd+U, chat Cmd+Shift+H, full screen Cmd+Shift+F, speaker view Cmd+Shift+W, invite Cmd+I, PTT Space. Excel AutoSum Cmd+Shift+T; Alt+Enter → Option+Cmd+Enter. Windows Alt+Tab → Cmd+Tab (`227,43`), Alt+F4 → Cmd+Q (`227,20`) or Cmd+W. |
| `227` Win + key | **drop or hand-map** (Windows shell only) | Win+D → Show Desktop = F11 (`[68]`, needs Fn or "standard function keys") or better an `output:10` push to Deckhand (`{"action":"hotKey","params":{"keys":[68],"fn":true}}`), Win+L → Ctrl+Cmd+Q (`224,227,20`), Win+E → Cmd+Option+Space / open Finder via push, Win+Shift+S → Cmd+Shift+4 (`227,225,33`), Win+. → Ctrl+Cmd+Space (`224,227,44`), Win+V → none (clipboard history is third-party), Win+Up/Down/Left/Right → window tiling shortcuts (macOS 15+: Fn+Ctrl+arrows / Globe) — recommend `output:10` pushes handled by Deckhand instead. |
| single key (B, V, F1, F2, F7, Space) | unchanged | F-keys require "Use F1, F2… as standard function keys" or Fn; Rename F2 → Enter (`40`) on Mac Finder. |
| `229` RShift | treat as `225` | typo in vendor data |

Recommendation: the importer stores the pack's `keys[]` unchanged (`winKeys`) and derives `macKeys` by rule, lets the user accept/override per button in the Deckhand UI before publishing, and sets a pack-level `platform: "windows"` on all nine vendor packs. The Windows pack should be imported as "Windows only" and hidden on a Mac by default.

## 4. How "Website" / "AI Website" open URLs

CONFIRMED (from `40-Website` and `46-AI_Website` `config.json`): there is no key sequence at all. Each button is

```json
{"id":"eE5nR0wW2gY3hD6hA5mV3pR8dM4rK8rY","icon":"http://cdn.lifex360.com/icon/2026/01/lx60rqvbuqslcr8d5e42.png","type":"PC_CONTROL","name":"Google","spanSize":1,
 "param":{"output":10,"payload":{"action":"openBrowser","params":{"url":"https://www.google.com"}}}}
```

Path on press (CONFIRMED by the firmware notes): `HomeDeviceHolderListener` / `RemoteActivity` sees `output == 10` → `GatewayHub.push(PushMessage.pcControl(payload))` → the hub broadcasts `{"act":1000000,"id":"sys.push.<hex>","data":{"type":"PC_CONTROL","payload":{"action":"openBrowser","params":{"url":"https://www.google.com"}}}}` to every connected PC client; no reply is required (replying `{"act":1000000,"id":<same>,"code":200,"data":{"type":"PC_CONTROL","payload":…}}` is harmless). The official client then runs `QDesktopServices::openUrl`-style handling in `OSCtrlUseCase`. Emoji does the same with `{"action":"inputText","params":{"text":"😊"}}` — the client types the string into the focused app (on macOS that would be a CGEvent unicode keystroke or pasteboard+Cmd+V; Deckhand needs Accessibility permission for either).

So in a pack "PC_CONTROL openBrowser" is exactly the official client's OS-control action object `{action, params}` wrapped as the `payload` of an `output:10` param — the same objects the client puts in DotKey/scene actions (official-client-findings §6: `typeId hotKey/inputText/openFileOrFolder/openBrowser/startApp/execCmd`). Deckhand's `PUSH_MESSAGE` handler must therefore accept both its own `{"deckhand":…}` payloads and the vendor `{"action":…,"params":…}` payloads (and ignore `execCmd` unless the user opts in — it is remote command execution from any LAN peer that can write a profile, see `security-findings.md`).

HYPOTHESIS: `openBrowser` opens the default browser (not a specific one); `startApp` `launchMode` is unknown; none of the packs uses `openFile`/`startApp`/`execCmd`, so Deckhand can ship without them.

## 5. Icons

CONFIRMED:

- Reference forms: `file://<relative path from zip root>` (192 buttons + Excel pack icon) and absolute `http://cdn.lifex360.com/…` / `https://sslcdn.lifex360.com/…` (48 buttons + 8 pack icons). The `file://` path is always relative to the zip root, never absolute, never `./` or `../`; it may contain a subfolder (`icon/`, `excel/`) or none (Word root PNGs); filenames may be non-ASCII (UTF-8, zip bit 11 set in the one case that has it). Every referenced file exists in its zip (0 missing references across 192).
- Format: PNG only (227 files), all 8-bit RGBA (colour type 6) — no JPG/WebP/GIF/SVG in any pack. Sizes: 256×256 in 219 files; outliers 128×128 (Website `youtube.png`, `website.png`), 512×512 (`manus.png`), and non-square 257–348 × 256 (seven files; the renderer evidently tolerates them). File size 0.6–17 KB, average ≈5 KB; biggest pack Emoji ≈ 640 KB.
- Styles: (a) white (#E0E0E0–#FFFFFF) glyph on transparent, glyph occupying ≈ 40 % of the canvas (OBS: bbox 76–179 of 256; Photoshop 72–182) — meant for the dark CoreBar card background; (b) full-colour logos filling ≈ 85 % (Website/AI Website/Emoji, bbox 16–240); (c) blue (#2196F3-ish) outline icons (Word/Excel `icon/`, bbox 50–198). The Rakuten icon is a fully opaque white square with red text (the only icon with a non-transparent background).
- Naming: free-form; vendor uses pinyin (`bianhuan.png` = 变换 "transform", `chexiao` = undo, `shiping` = video, `jushou` = raise hand…), numbers, or English slugs. Nothing depends on the name.
- Device rendering (firmware notes): a `PC_CONTROL`/RemoteChildren icon is drawn on a 265×265 px canvas scaled by `iconScale/100` (`WidgetCardIconUtils.getScaledBitmap(265,265,bmp,iconScale)`); `iconScale` 0 may draw nothing, so the importer must set it (60–100; the official client's default slider is 60 %, and its export path trims transparent borders first). The CDN icons are fetched by the CoreBar itself over the network (`GlideExtend`: http → network) — they only render if the CoreBar has internet access and the CDN still serves them.

Recommendation for Deckhand-authored icons: **256×256 PNG, RGBA, transparent background, glyph within the central 60–70 %** (≈ 160–180 px) for monochrome glyphs in white, or full-bleed colour logos with ≈ 16 px margin; keep files ≤ 20 KB; never rely on a remote URL (bundle everything so the pack works offline and after the CDN changes). 256 px is 1:1 with the 265 px on-device canvas at `iconScale:100`, and matches the vendor's own assets, so no resampling is needed. (The VivoCube's 240×240 LVGL canvas is a different target; see `vivocube-findings.md`.)

## 6. Import spec: vendor pack → CoreBar `HOT_KEY_GROUP`

### 6.1 Target JSON (device side — CONFIRMED structure)

A page (`ProfileDTO`, written with `BATCH_SAVE_PROFILE` 1108 — destructive, always send the complete page list; see `CoreBarSession.savePages`) gets one widget per pack:

```
{ "id": "<unique widget id>", "type": "HOT_KEY_GROUP", "name": "<pack name>", "icon": "<pack icon ref>", "iconScale": 100,
  "param": { "button": [ { "id", "type": "PC_CONTROL", "name", "icon", "iconScale", "spanSize": 1|2, "param": {output:5,keys} | {output:10,payload} }, … ] } }
```

`HotKeyGroupParamter.button[]` children are `RemoteChildren = HomeData + spanSize` (device-first-findings §F). The official client additionally writes `pluginUuid` on the group widget (official-client-findings §4) — HYPOTHESIS: ignored by the firmware (not in `ProfileProperty`), but harmless to include; Deckhand should include `"pluginUuid": "<identifier>"` for parity with vendor projects.

### 6.2 Algorithm

1. **Verify & unpack.** Download the catalogue `file`, check `sha256` against the catalogue (CONFIRMED values match today), unzip with UTF-8 entry names, reject entries with `..`/absolute paths, accept only `config.json` + `png/jpg/jpeg/webp/gif` (the device's own allow-list, `UploadServiceIns.ALLOWED_IMG_EXTENSIONS`). Parse `config.json` as strict UTF-8 JSON.
2. **Validate against §1.2**, but recover from the known vendor defects: unknown `type` with a `param.output` → coerce to `PC_CONTROL`; duplicate/missing `id` → re-key; missing `spanSize` → 1; `output` other than 5/10 or malformed `keys` → drop button with a warning; ignore unreferenced files.
3. **Re-key ids.** Device ids must be unique within a page; vendor ids are only unique within a pack (and not even that in Photoshop). Use `widget.id = "deckhand.pack.<identifier>"` and `button.id = "<identifier>.<index>"` (keep the vendor id in Deckhand's own model for round-tripping).
4. **Collect icons.** For each `file://<p>` reference, take the zip entry `<p>`; for each `http(s)://` reference download it once (cache by URL hash, name it `remote/<sha1-8>.png`) — or, if offline, keep the URL and let the CoreBar fetch it. Validate it is an image (magic bytes), optionally normalise to 256×256 RGBA PNG. The pack icon is handled the same way.
5. **Build the asset zip** with the entry names **relative to the pack folder**, preserving the vendor's folder structure so the rewrite is mechanical: `icon/bianhuan.png` stays `icon/bianhuan.png`, Word's root `01_bold.png` stays `01_bold.png`. (`ZipWriter.archive` already exists in UltraBarKit; the device ignores non-image entries and `__MACOSX`.)
6. **Upload** `POST http://<ip>:8080/upload/zip?subDir=deckhand/plugins/<identifier>&isFull=true` (multipart field `file`). A nested `subDir` works because the firmware does `new File(externalFilesDir, "/" + subDir)` (CONFIRMED in corebar-screen-findings §5; nested dirs are created by `unzipWithStructure`). `isFull=true` is safe here because it wipes only that pack's folder (re-import = clean replace); never call without `subDir`. Success body `{"state":200,…,"data":<number of images written>}` — compare the count with the number of icons sent. Our `CoreBarSession.uploadScreenZip(zip, subDir:, isFull:)` already percent-encodes the query and keeps `/`.
7. **Rewrite icon refs** to the device-relative path `deckhand/plugins/<identifier>/<entry>` (CONFIRMED: `GlideExtend` resolves any string that is not http/`resId://`/`file://`/`/` as `new File(getExternalFilesDir(null), str)`, and `/upload/zip` extracts into exactly that dir). Do **not** keep `file://…` — on the device that means an absolute path and would not resolve.
8. **Set `iconScale`** on every child and on the group (vendor packs omit it; 0 may render nothing). Default 100 for the vendor's 256-px assets with built-in margins, 60–70 if Deckhand trims transparent borders like the official client does.
9. **Translate keys** for macOS per §3.3 when the pack is marked `platform:"windows"` and the target is a Mac; keep the original for the "as authored" option.
10. **Emit the widget**, append it to the chosen page, write all pages with 1108, then 1103 to show the page. Remember that a vendor-app "Deploy" wipes the external files dir (including `deckhand/plugins/…`) — Deckhand should keep the asset zip locally so a re-upload is one click.

### 6.3 Worked example — OBS Hotkey Plugin (pack 47)

Input: `47-OBS_Hotkey_Plugin.zip` (`config.json` + `icon/{bianhuan,bianji,lashendaopingmu,zhongxindaopingmu,shiyingpingmu,yuanliebiaoshangyi,yuanliebiaoxiayi,chexiao}.png`, all 256×256 RGBA white glyphs; the `Redo` icon and the pack icon are CDN URLs).

Step 4–6: asset zip entries → `icon/bianhuan.png`, `icon/bianji.png`, `icon/lashendaopingmu.png`, `icon/zhongxindaopingmu.png`, `icon/shiyingpingmu.png`, `icon/yuanliebiaoshangyi.png`, `icon/yuanliebiaoxiayi.png`, `icon/chexiao.png`, plus downloaded `remote/2wjkxbk2.png` (from `https://sslcdn.lifex360.com/icon/2026/07/2wjkxbk2qkttiqxogzry.png`) and `remote/lwp7zd73.png` (pack icon). `POST /upload/zip?subDir=deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ&isFull=true` → expect `data: 10`.

Step 7–10: widget to append to a page's `widget[]` (keys as authored = Windows; the `macKeys` column of §3.3 would turn every leading `224` into `227` and Redo into `[227,225,29]`):

```json
{
  "id": "deckhand.pack.yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ",
  "type": "HOT_KEY_GROUP",
  "name": "OBS Hotkey Plugin",
  "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/remote/lwp7zd73.png",
  "iconScale": 100,
  "pluginUuid": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ",
  "param": {
    "button": [
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.0", "type": "PC_CONTROL", "name": "Reset Transform",   "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/bianhuan.png",           "iconScale": 100, "spanSize": 2, "param": {"output": 5, "keys": [224, 21]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.1", "type": "PC_CONTROL", "name": "Edit Transform",    "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/bianji.png",             "iconScale": 100, "spanSize": 2, "param": {"output": 5, "keys": [224, 8]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.2", "type": "PC_CONTROL", "name": "Stretch to Screen", "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/lashendaopingmu.png",    "iconScale": 100, "spanSize": 2, "param": {"output": 5, "keys": [224, 22]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.3", "type": "PC_CONTROL", "name": "Center to Screen",  "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/zhongxindaopingmu.png",  "iconScale": 100, "spanSize": 1, "param": {"output": 5, "keys": [224, 7]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.4", "type": "PC_CONTROL", "name": "Fit to Screen",     "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/shiyingpingmu.png",      "iconScale": 100, "spanSize": 1, "param": {"output": 5, "keys": [224, 9]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.5", "type": "PC_CONTROL", "name": "Move Up",           "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/yuanliebiaoshangyi.png", "iconScale": 100, "spanSize": 1, "param": {"output": 5, "keys": [224, 82]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.6", "type": "PC_CONTROL", "name": "Move Down",         "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/yuanliebiaoxiayi.png",   "iconScale": 100, "spanSize": 1, "param": {"output": 5, "keys": [224, 81]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.7", "type": "PC_CONTROL", "name": "Undo",              "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/icon/chexiao.png",            "iconScale": 100, "spanSize": 1, "param": {"output": 5, "keys": [224, 29]}},
      {"id": "yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ.8", "type": "PC_CONTROL", "name": "Redo",              "icon": "deckhand/plugins/yN3uV9aO0eO7gT5yX0bP9tQ1jR5pQ3iJ/remote/2wjkxbk2.png",         "iconScale": 100, "spanSize": 1, "param": {"output": 5, "keys": [224, 28]}}
    ]
  }
}
```

Full page write (the existing Deckhand page plus this group; ids/structure as in `AppModel+Pages.swift`): `data = [ {standard page…}, {"id":"deckhand.page.2","name":"Deckhand","isDefault":false,"showName":true,"iconScale":100,"icon":"deckhand/cover.png","module":[],"widget":[ {TIME…}, {WEATHER…}, <the HOT_KEY_GROUP above> ]} ]` → act 1108, then act 1103 `"deckhand.page.2"`.

Open points to confirm on hardware (all HYPOTHESIS until tested): that nested `subDir` paths survive `isFull=true` without touching `deckhand/cover.png` (code says only the named subdir is deleted); the RemoteActivity grid column count (span 2 = double width is CONFIRMED by name only); whether `iconScale:100` on a 256-px white glyph is visually right or needs 70; whether the group card's own icon honours `iconScale`.

## 7. Proposal: "Deckhand pack" authoring format (strict superset)

Goal: a vendor zip loads unchanged (every vendor key keeps its meaning), and additional keys — all optional, all namespaced so a vendor client that ignores unknown keys still works — add macOS key translation, richer `output:10` actions and bundled metadata. Validation = §1.2 schema with `additionalProperties:true` plus the keys below. File name stays `config.json` at the zip root; Deckhand may also write `deckhand.json` (same content) if we ever need to hide extensions from the vendor client, but there is no evidence that the vendor client rejects unknown keys, so start with one file.

### 7.1 Pack-level additions

| key | type | meaning |
|---|---|---|
| `formatVersion` | integer | `1` = this proposal; absent = plain vendor pack |
| `platform` | `"windows"` \| `"macos"` \| `"any"` | layout the `keys` arrays were authored for; vendor packs are imported as `"windows"` |
| `locale` | BCP-47 | language of `name`s (vendor: en, one ja) |
| `license`, `homepage` (vendor key, reused), `preview` (array of `file://` or http refs — mirrors the catalogue field so a pack is self-describing), `tags` (array of strings, e.g. `["video","obs"]`), `minDeckhandVersion` | strings / arrays | marketplace metadata |
| `groupIconScale` | integer 10–100 | `iconScale` to emit on the HOT_KEY_GROUP card (default 100) |
| `defaultIconScale` | integer 10–100 | default for children without their own (default 100) |

### 7.2 Button-level additions

| key | type | meaning |
|---|---|---|
| `iconScale` | integer 10–100 | passed through to the device child (vendor children lack it) |
| `platforms` | object `{ "macos": {output,keys\|payload}, "windows": {…}, "linux": {…} }` | per-OS override of `param`; the importer picks `platforms[<host os>] ?? param`. This is how a Deckhand pack ships both Ctrl+C and Cmd+C while a vendor client still sees the Windows `param`. |
| `keysDesc` | string | human-readable chord (`"Cmd+Shift+V"`); the official client already uses this key name inside scene hot-key actions (official-client-findings §6), so it reads naturally to vendor tooling |
| `sequence` | array of `keys[]` arrays | for KeyTips-style sequences (`[[226],[17],[22]]`); **requires** `output:10` handling by Deckhand (the firmware sends one report per button), so a pack using it must also give a `param` fallback |
| `longPress` | `{output, keys\|payload}` | optional second action; HYPOTHESIS that the firmware has no per-child long-press variant, so Deckhand would implement it for `output:10` only (it receives TAP and LONG_PRESS_DOWN pushes identically — not distinguishable today; mark as future) |
| `description`, `tags` | string / array | tooltips / search |

### 7.3 `output:10` payload vocabulary

Keep the vendor envelope `{"action": string, "params": object}` so vendor clients can still execute the subset they know, and Deckhand executes everything:

| `action` | `params` | status |
|---|---|---|
| `openBrowser` | `{url}` | vendor-compatible (CONFIRMED in packs) |
| `inputText` | `{text}` | vendor-compatible (CONFIRMED in packs) |
| `openFile` | `{path}` | vendor-compatible (client code, no pack uses it) |
| `startApp` | `{path, launchMode}`; Deckhand adds `{bundleId}` | vendor-compatible / extended |
| `execCmd` | `{cmd}` | vendor-compatible; **off by default** in Deckhand (prompt per pack) |
| `hotKey` | `{keys:[…], keysDesc}` — same object the official client uses for scene hot-keys | Deckhand-only: lets the Mac synthesise the chord itself (CGEvent) instead of the CoreBar's USB HID path — the way to get Cmd-chords, F-keys with Fn, media keys, and sequences without touching `keys[]` |
| `deckhand` | free object (`{"deckhand":"next"}` style, already used by our scene bindings) | Deckhand-only |
| `shortcut` | `{name}` — run a macOS Shortcuts.app shortcut | Deckhand-only |
| `appleScript` | `{source}` | Deckhand-only, opt-in like `execCmd` |
| `media` | `{key: "playPause"\|"next"\|"prev"\|"volumeUp"\|"volumeDown"\|"mute"}` | Deckhand-only (NX media keys) |
| `url` | `{url}` for non-http schemes (`obs://`, `zoommtg://`, `x-apple…`) | Deckhand-only |

Because the device forwards `payload` verbatim (CONFIRMED), none of these need firmware support; a vendor client receiving an unknown `action` will simply do nothing (HYPOTHESIS: `OSCtrlUseCase` ignores unknown actions rather than crashing — not verified).

### 7.4 Example Deckhand pack button (loads in a vendor client as the Windows chord; on a Mac Deckhand uses `platforms.macos`)

```json
{
  "id": "dh.zoom.video", "type": "PC_CONTROL", "name": "Start/stop video", "icon": "file://icon/video.png",
  "spanSize": 2, "iconScale": 80, "keysDesc": "Alt+V",
  "param": {"output": 5, "keys": [226, 25]},
  "platforms": {
    "macos": {"output": 5, "keys": [227, 225, 25], "keysDesc": "Cmd+Shift+V"}
  }
}
```

and a Mac-only action that has no HID equivalent:

```json
{
  "id": "dh.mac.desktop", "type": "PC_CONTROL", "name": "Show Desktop", "icon": "file://icon/desktop.png", "spanSize": 1,
  "param": {"output": 10, "payload": {"action": "hotKey", "params": {"keys": [68], "keysDesc": "F11", "fn": true}}}
}
```

### 7.5 Publishing

A Deckhand pack is the same zip layout (`config.json` + `icon/*.png`, 256×256 RGBA, all icons bundled, no remote URLs), `identifier` = 32-char random alnum (vendor alphabet) so vendor tooling accepts it, `versionCode` monotonically increasing, `sha256` published alongside in our catalogue (mirror the vendor catalogue row shape `{id, identifier, name, author, desc, file, sha256, icon, preview[], versionName, versionCode, official, pluginType, regionIds}` so one importer handles both stores). Validation before publish: §1.2 schema, unique ids, every `file://` resolves, every `keys[]` within 4–231, `platforms.macos` present for every `output:5` button when `platform:"windows"`.

## 8. Checklist for the importer tests (kitcheck)

- Parse all nine vendor zips without error; expect button counts 22/36/39/64/25/23/9/9/13, 240 total; 145 HID, 95 push; 12 span-2.
- Excel row 26 coerced to PC_CONTROL; Photoshop produces 23 unique child ids; Word root-level `file://01_bold.png` resolves; Website's `楽天市場_24.png` resolves (UTF-8 zip names).
- Windows pack yields an asset zip with 0 local files and 25 remote refs (download or pass-through).
- Rewritten refs all start with `deckhand/plugins/<identifier>/` and contain no `file://`.
- macOS translation: every leading 224 → 227 unless the per-app table overrides; 227 chords from the Windows pack are flagged, not translated.
- Round trip: exporting an imported vendor pack reproduces the vendor `config.json` byte-for-byte except key order/whitespace (vendor keys untouched, Deckhand keys only added).
