# OpenBarX site

The public site for Deckhand and the OpenBarX marketplace: plain HTML and CSS, no build step. It is set in the De Noronha Consulting house style (tokens from the DNC design system: ink + viking cyan, Avenir with Nunito Sans as the web fallback, JetBrains Mono for meta, 4 px corners).

## Layout

- `index.html` — landing page: download, what Deckhand does, the bar apps, the Mac-app screenshots, the port warning, how to get started.
- `deckhand/index.html` — the Mac app: requirements, every page of the window, how it talks to the bar, security and privacy.
- `bar-apps/index.html` — the eleven bar apps: how they work (pages in the APK, beacon + data API on :7432), each app, install over Wi-Fi ADB, build your own.
- `marketplace/index.html` — the marketplace shell; it renders `marketplace/registry.json`.
- `manual/index.html` — **generated** from `../MANUAL.md` by `tools/build-manual.py` (needs pandoc). Run it after every manual change and commit the result; do not edit the page by hand.
- `404.html` — GitHub Pages serves it for unknown paths (its links are absolute under `/UltraWorkspaceMac/`; change them with the domain).
- `marketplace/registry.json` — the machine-readable index of apps and cards (phase 1 of the marketplace, see `docs/ROADMAP.md`). Deckhand will fetch this file later; keep it valid JSON and keep `version` in step with `android/DeckhandMonitor/app/build.gradle.kts` and `AppModel.barAppsVersion` (1.6 today).
- `assets/img/screens/bar-*.png` — 1424 × 280 renders of the bar apps. Deckhand no longer serves the pages (bar apps 2.0), so take them from the bar (`adb exec-out screencap -p`); the Claude, Calendar and Tasks renders use demo data, never a real session, calendar or issue list.
- `assets/img/icons/*.png` — the bar apps' launcher icons (the 216 px previews that `android/DeckhandMonitor/tools/make-icons.swift` writes to `dist/bar-apps/icons/`; Fluent Emoji glyphs on gradients since bar apps 1.5).

Mac-app screenshots (`assets/img/screens/app-*.png`): 2× captures of Deckhand's window with `screencapture -l <window id>` (the Activity panel hidden with its toolbar button), then scaled to 1600 px wide with `sips -Z 1600` so the landing page stays light. CoreBar and Apps are in; the VivoCube page is still to add once the cube accepts uploads again, so the page is free of its red error line.

## Publishing

`.github/workflows/pages.yml` (repository root) publishes this folder to GitHub Pages on every push to `main` that touches it. One-time: repository Settings → Pages → Source: **GitHub Actions**. When openbarx.com is registered, add a `CNAME` file here with the domain and point the DNS at GitHub Pages.

The download buttons link to `download/Deckhand.dmg`, which does not live in git: the Pages workflow fetches the newest release's `Deckhand.dmg` (pre-releases included) into `site/download/` at deploy time and writes `download/latest.json` (tag, size, date) next to it, which the buttons read for their label. So every release must attach the DMG under exactly that name (see `docs/RELEASING.md`), and publishing a release also redeploys the site. This also keeps the download working while the repository is private; the GitHub links on the site (source, protocol, issues) do not.

Preview locally with any static server, for example `python3 -m http.server 8000 --directory site`.
