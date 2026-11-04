# OpenBarX site

The public site for Deckhand and the OpenBarX marketplace: plain HTML and CSS, no build step. It is set in the De Noronha Consulting house style (tokens from the DNC design system: ink + viking cyan, Avenir with Nunito Sans as the web fallback, JetBrains Mono for meta, 4 px corners).

## Layout

- `index.html` — landing page: download, what Deckhand does, the six bar apps, the port warning, how to get started.
- `marketplace/index.html` — the marketplace shell; it renders `marketplace/registry.json`.
- `marketplace/registry.json` — the machine-readable index of apps and cards (phase 1 of the marketplace, see `docs/ROADMAP.md`). Deckhand will fetch this file later; keep it valid JSON and keep `version` in step with `android/DeckhandMonitor/app/build.gradle.kts`.
- `assets/img/screens/bar-*.png` — 1424 × 280 renders of the bar apps. Make them with headless Chrome against a running Deckhand (`http://127.0.0.1:7432/<page>`); the Claude and Calendar renders use demo data, never a real session or calendar.
- `assets/img/icons/*.png` — the bar apps' launcher icons (copied from the Android project's `mipmap-xxxhdpi`).

Mac-app screenshots (`assets/img/screens/app-*.png`): 2× captures of Deckhand's window with `screencapture -l <window id>` (the Activity panel hidden with its toolbar button, the status bar cropped off: 3022×1928). CoreBar and Apps are in; the VivoCube page is still to add once the cube accepts uploads again, so the page is free of its red error line.

## Publishing

`.github/workflows/pages.yml` (repository root) publishes this folder to GitHub Pages on every push to `main` that touches it. One-time: repository Settings → Pages → Source: **GitHub Actions**. When openbarx.com is registered, add a `CNAME` file here with the domain and point the DNS at GitHub Pages.

The download button links to `https://github.com/DeNoronha/UltraWorkspaceMac/releases/latest/download/Deckhand.dmg`, so every release must attach the DMG under exactly that name (see `docs/RELEASING.md`).

Preview locally with any static server, for example `python3 -m http.server 8000 --directory site`.
