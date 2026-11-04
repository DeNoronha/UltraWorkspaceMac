#!/usr/bin/env python3
"""Render MANUAL.md as site/manual/index.html in the site's house style.

Run from anywhere: `python3 site/tools/build-manual.py`. Needs pandoc (brew install pandoc).
The page is committed, so run this after every change to MANUAL.md and commit the result.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]          # UltraWorkspaceMac/
SRC = ROOT / "MANUAL.md"
OUT = ROOT / "site" / "manual" / "index.html"

HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Deckhand manual · OpenBarX</title>
<meta name="description" content="The Deckhand user manual: install, connect the UltraBar X, pages on the CoreBar, cards on the VivoCube, bindings, apps, troubleshooting.">
<link rel="icon" href="../assets/img/favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Nunito+Sans:ital,opsz,wght@0,6..12,400;0,6..12,700;0,6..12,900&family=JetBrains+Mono:wght@400&display=swap">
<link rel="stylesheet" href="../assets/site.css">
</head>
<body>

<header class="site-header">
  <div class="container">
    <a class="brand" href="../" aria-label="OpenBarX home">
      <span class="name">OpenBar<i>X</i></span>
      <span class="tag">Deckhand for macOS</span>
    </a>
    <nav class="nav" aria-label="Site">
      <a href="../deckhand/">Deckhand</a>
      <a href="../bar-apps/">Bar apps</a>
      <a href="../marketplace/">Marketplace</a>
      <a href="./" aria-current="page">Manual</a>
      <a href="https://github.com/DeNoronha/UltraWorkspaceMac">GitHub</a>
    </nav>
  </div>
</header>

<main>
  <section class="hero hero-compact">
    <div class="container">
      <p class="eyebrow">Manual <span class="sep">·</span> Deckhand 0.1</p>
      <h1>How to use Deckhand.</h1>
      <p class="lede">The same text ships inside the repository as <a href="https://github.com/DeNoronha/UltraWorkspaceMac/blob/main/UltraWorkspaceMac/MANUAL.md">MANUAL.md</a>; this page is generated from it. Something missing or wrong? <a href="https://github.com/DeNoronha/UltraWorkspaceMac/issues">Open an issue</a>.</p>
    </div>
  </section>

  <section class="section">
    <div class="container manual-grid">
      <nav class="toc" aria-label="Contents">
        <p class="eyebrow">Contents</p>
__TOC__
      </nav>
      <article class="prose">
__BODY__
      </article>
    </div>
  </section>
</main>

<footer class="site-footer">
  <div class="container">
    <div class="cols">
      <div class="dnc">
        <img src="../assets/img/dnc-logo-white.svg" alt="De Noronha Consulting">
        <p>Deckhand and OpenBarX are made by De Noronha Consulting in Sassenheim, the Netherlands.</p>
        <a href="https://denoronha.consulting">denoronha.consulting <span class="arrow">→</span></a>
      </div>
      <div>
        <h4>Deckhand</h4>
        <ul>
          <li><a href="../download/Deckhand.dmg">Download the DMG</a></li>
          <li><a href="../deckhand/">The Mac app</a></li>
          <li><a href="../deckhand/#security">Security and privacy</a></li>
          <li><a href="https://github.com/DeNoronha/UltraWorkspaceMac/blob/main/UltraWorkspaceMac/docs/ROADMAP.md">Roadmap</a></li>
        </ul>
      </div>
      <div>
        <h4>For builders</h4>
        <ul>
          <li><a href="https://github.com/DeNoronha/UltraWorkspaceMac">Source on GitHub</a></li>
          <li><a href="https://github.com/DeNoronha/UltraWorkspaceMac/blob/main/UltraWorkspaceMac/PROTOCOL.md">The CoreBar protocol</a></li>
          <li><a href="../bar-apps/#build">Build a bar app</a></li>
          <li><a href="../marketplace/registry.json">Marketplace registry (JSON)</a></li>
        </ul>
      </div>
    </div>
    <p class="fine">Deckhand is independent, community software under the MIT license. UltraBar X, CoreBar, VivoCube, SenseCube, KnobKey and DotKey are names of Sanytron products; this project is not affiliated with or endorsed by Sanytron.</p>
  </div>
</footer>
</body>
</html>
"""


def main() -> int:
    md = SRC.read_text(encoding="utf-8")
    # The page has its own title and intro; drop the H1 and the first paragraph + rule of the Markdown.
    md = re.sub(r"\A# [^\n]+\n\n", "", md)
    try:
        body = subprocess.run(
            ["pandoc", "--from", "gfm", "--to", "html5", "--wrap=none", "--section-divs=false"],
            input=md, capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        print("pandoc is needed: brew install pandoc", file=sys.stderr)
        return 1
    # Table of contents from the H2s (pandoc gives them ids).
    toc = ["        <ol>"]
    for m in re.finditer(r'<h2 id="([^"]+)">(.*?)</h2>', body):
        title = re.sub(r"<[^>]+>", "", m.group(2))
        toc.append(f'          <li><a href="#{m.group(1)}">{title}</a></li>')
    toc.append("        </ol>")
    # Mark the warning blockquote so the stylesheet can colour it.
    body = body.replace("<blockquote>\n<p>⚠️", '<blockquote class="warn">\n<p>⚠️')
    html = HEAD.replace("__TOC__", "\n".join(toc)).replace("__BODY__", body.rstrip())
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(html)} bytes, {len(toc) - 2} sections)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
