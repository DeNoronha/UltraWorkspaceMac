# Collaboration opportunity — the Windows "VivoCube Weather Tool" author

A frustrated UltraBar X backer ("The Developer Incognito") — a senior developer, swamped on time — built an unofficial **Windows** app that shows weather on a VivoCube (`ultrabar-weather.pages.dev`, a Windows ClickOnce `.application`). In a Kickstarter comment (26 Oct 2026) he announced he will set up a **full open-source GitHub project** around the software over the Christmas break, invites contributors, and says a macOS version is possible but "not soon". He shares a contact email in that comment.

This is the same tool that originally inspired this project. He and Deckhand are complementary:

- **He**: Windows client + community momentum + an about-to-exist open-source home. Same end goal — "replace all of the vendor's software."
- **Us (Deckhand)**: a working, feature-rich **macOS** client, plus a deep reverse-engineering of the local protocol (see PROTOCOL.md), 13 widgets, the CoreBar big-screen preview path, SenseCube reads, input bindings (understood, not yet implemented), and a security review (SECURITY.md).

## Why reach out now (before Christmas)

He hasn't architected the open-source project yet. If we align first, the **widget format and protocol library can be shared from day one**, so a widget built once runs on both his Windows client and Deckhand on macOS — exactly the "build once, runs on both" goal. If we wait until his repo is built over Christmas, two incompatible standards may harden.

## What we propose to him

1. **Shared, open widget format** — the TypeScript/web spec in WIDGETS.md (HTML/CSS/JS → rendered to an image), so one widget runs on Windows + macOS.
2. **Shared protocol knowledge** — offer PROTOCOL.md as a head start so he doesn't re-derive it; keep it current together.
3. **One marketplace** on GitHub both clients read.
4. **Complementary ownership** — he leads Windows, we lead macOS, shared core.

## What we bring as goodwill

PROTOCOL.md (discovery, pairing/TLS, provisioning, module upload, CoreBar big-screen pages/screensaver, SenseCube reads, input bindings — the last two mapped, input bindings not yet implemented), SECURITY.md (he'll care — he asked about units "burning up"), and a working macOS implementation of the device path (discovery through module upload, SenseCube reads, big-screen preview) plus a mock CoreBar and an end-to-end test (`kitcheck e2e`).

## Status

- Contact details are in the user's screenshot of the Kickstarter comment (public site: `ultrabar-weather.pages.dev`). The user will decide whether/how to reach out; we do not contact anyone automatically.
- Draft outreach email prepared (kept out of this file to avoid republishing a personal address in a repo that may go public).
