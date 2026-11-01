/**
 * Web viewer (:8081) — mock-only, NOT part of the real device protocol.
 *
 * Auto-refreshing page showing each module's latest uploaded image, the last
 * PREVIEW_SCREENSAVER, current fake sensor values, saved profiles/scenes, and a
 * live frame log. Plain HTML + a little JS polling /state.
 */

import express from 'express';
import { Ports } from './protocol';
import { state } from './state';

export function startViewer(): import('http').Server {
  const app = express();

  // Latest decoded module image as PNG.
  app.get('/img/module/:serial', (req, res) => {
    const img = state.images.get(req.params.serial);
    if (!img) {
      res.status(404).end();
      return;
    }
    res.type('image/png').set('Cache-Control', 'no-store').send(img.png);
  });

  // A big-screen zip asset by relative path.
  app.get('/asset/*', (req, res) => {
    const rel = decodeURIComponent((req.params as Record<string, string>)[0] ?? '');
    const asset = state.assets.get(rel);
    if (!asset) {
      res.status(404).end();
      return;
    }
    res.type(asset.contentType).set('Cache-Control', 'no-store').send(asset.data);
  });

  // The image the mock fetched for the last PREVIEW_SCREENSAVER.
  app.get('/img/preview', (_req, res) => {
    const p = state.preview;
    if (!p?.image) {
      res.status(404).end();
      return;
    }
    res.type(p.imageType ?? 'application/octet-stream').set('Cache-Control', 'no-store').send(p.image);
  });

  // JSON snapshot the page polls.
  app.get('/state', (_req, res) => {
    res.set('Cache-Control', 'no-store').json({
      device: { serialNo: state.serialNo, name: state.name, version: state.version, ip: state.ip },
      modules: state.modules.map((m) => {
        const img = state.images.get(m.serialNo);
        return {
          ...m,
          image: img
            ? {
                url: `/img/module/${encodeURIComponent(m.serialNo)}?t=${img.receivedAt}`,
                width: img.width,
                height: img.height,
                hasAlpha: img.hasAlpha,
                widgetId: img.widgetId,
                receivedAt: img.receivedAt,
                packageBytes: img.packageBytes,
                round: m.productName === 'VIVO_CUBE',
              }
            : null,
        };
      }),
      preview: resolvePreview(),
      sensors: {
        illuminanceLux: state.sensors['10/1'],
        temperatureC: state.sensors['11/1'] / 10,
        humidityPct: state.sensors['12/1'] / 10,
        shockWake: state.sensors['15/2'],
        raw: state.sensors,
      },
      screensaver: state.screensaver,
      profiles: state.profiles,
      scenes: state.scenes,
      activeProfileId: state.activeProfileId,
      assets: [...state.assets.values()].map((a) => ({
        path: a.path,
        bytes: a.bytes,
        url: `/asset/${a.path.split('/').map(encodeURIComponent).join('/')}?t=${a.at}`,
      })),
      log: state.recentLog(200),
    });
  });

  app.get('/', (_req, res) => res.type('html').send(PAGE));

  const server = app.listen(Ports.viewer, () => {
    state.record('evt', 'sys', `Web viewer listening on http://127.0.0.1:${Ports.viewer}`);
  });
  return server;
}

/** Resolve the preview to a viewable URL when possible. */
function resolvePreview(): {
  url: string;
  mediaType: string;
  at: number;
  viewUrl: string | null;
  fetched: boolean;
  fetchBytes?: number;
  fetchError?: string;
  note?: string;
} | null {
  if (!state.preview) return null;
  const { url, mediaType, at, fetched, fetchBytes, fetchError, note } = state.preview;
  // Only what the mock actually fetched is "on screen" — exactly like the device.
  const viewUrl = fetched ? `/img/preview?t=${at}` : null;
  return { url, mediaType, at, viewUrl, fetched, fetchBytes, fetchError, note };
}

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mock CoreBar Viewer</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; font: 14px/1.5 -apple-system, system-ui, sans-serif; background: #0d1117; color: #e6edf3; }
  header { padding: 14px 20px; background: #161b22; border-bottom: 1px solid #30363d; position: sticky; top: 0; }
  header h1 { margin: 0; font-size: 16px; }
  header .meta { color: #8b949e; font-size: 12px; margin-top: 2px; }
  main { padding: 20px; display: grid; gap: 20px; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); align-items: start; }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 14px; }
  .card h2 { margin: 0 0 10px; font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: #8b949e; }
  .modules { display: flex; flex-wrap: wrap; gap: 16px; }
  .module { text-align: center; }
  .module .frame { background: #0d1117; border: 1px solid #30363d; display: inline-flex; align-items: center; justify-content: center; }
  .module img { display: block; image-rendering: pixelated; }
  .module.round .frame { border-radius: 50%; overflow: hidden; }
  .module .cap { font-size: 11px; color: #8b949e; margin-top: 6px; }
  .empty { color: #6e7681; font-style: italic; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 3px 6px; border-bottom: 1px solid #21262d; }
  td:first-child { color: #8b949e; }
  pre { margin: 0; white-space: pre-wrap; word-break: break-word; font-size: 12px; color: #c9d1d9; }
  .log { grid-column: 1 / -1; max-height: 340px; overflow: auto; background: #0d1117; border-radius: 8px; padding: 8px; }
  .log .l { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; padding: 1px 0; }
  .log .in { color: #7ee787; } .log .out { color: #79c0ff; } .log .evt { color: #d29922; }
  .log .chan { color: #6e7681; }
  .screensaver img { max-width: 100%; border-radius: 6px; border: 1px solid #30363d; }
</style>
</head>
<body>
<header>
  <h1>Mock CoreBar Viewer</h1>
  <div class="meta" id="meta">connecting…</div>
</header>
<main id="main"></main>
<script>
const $ = (h) => { const t = document.createElement('template'); t.innerHTML = h.trim(); return t.content.firstChild; };
function esc(s){ return String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

async function tick() {
  let s;
  try { s = await (await fetch('/state')).json(); }
  catch { document.getElementById('meta').textContent = 'offline'; return; }

  document.getElementById('meta').textContent =
    s.device.name + ' · ' + s.device.serialNo + ' · v' + s.device.version + ' · ip ' + s.device.ip;

  const main = document.getElementById('main');
  main.innerHTML = '';

  // Modules
  const mcard = $('<section class="card"><h2>Modules — latest upload</h2><div class="modules"></div></section>');
  const mwrap = mcard.querySelector('.modules');
  if (!s.modules.length) mwrap.appendChild($('<div class="empty">no modules</div>'));
  for (const m of s.modules) {
    const round = m.image && m.image.round;
    const cls = 'module' + (round ? ' round' : '');
    let inner;
    if (m.image) {
      const w = m.image.width, h = m.image.height;
      inner = '<div class="frame" style="width:'+w+'px;height:'+h+'px"><img src="'+m.image.url+'" width="'+w+'" height="'+h+'"></div>'
        + '<div class="cap">'+esc(m.name)+'<br>'+w+'×'+h+(m.image.hasAlpha?' +α':'')+' · widget '+m.image.widgetId+'<br>'+esc(m.serialNo)+'</div>';
    } else {
      inner = '<div class="frame" style="width:120px;height:120px"><span class="empty">no image</span></div>'
        + '<div class="cap">'+esc(m.name)+'<br>'+esc(m.serialNo)+'<br>'+esc(m.productName)+'</div>';
    }
    mwrap.appendChild($('<div class="'+cls+'">'+inner+'</div>'));
  }
  main.appendChild(mcard);

  // Screensaver preview
  const pc = $('<section class="card screensaver"><h2>PREVIEW_SCREENSAVER</h2></section>');
  if (s.preview) {
    pc.appendChild($('<div class="cap"><pre>'+esc(s.preview.url)+'\\n('+esc(s.preview.mediaType)+')</pre></div>'));
    if (s.preview.viewUrl) pc.appendChild($('<img src="'+s.preview.viewUrl+'">'));
    else pc.appendChild($('<div class="empty">(url not resolvable to an uploaded asset)</div>'));
  } else pc.appendChild($('<div class="empty">none yet</div>'));
  main.appendChild(pc);

  // Sensors
  const sc = $('<section class="card"><h2>SenseCube sensors (fake)</h2><table>'
    + '<tr><td>Illuminance</td><td>'+s.sensors.illuminanceLux+' lux</td></tr>'
    + '<tr><td>Temperature</td><td>'+s.sensors.temperatureC.toFixed(1)+' °C</td></tr>'
    + '<tr><td>Humidity</td><td>'+s.sensors.humidityPct.toFixed(1)+' %RH</td></tr>'
    + '<tr><td>Shock-wake</td><td>'+s.sensors.shockWake+'</td></tr>'
    + '</table></section>');
  main.appendChild(sc);

  // Screensaver config + profiles/scenes
  const cfg = $('<section class="card"><h2>State</h2></section>');
  cfg.appendChild($('<table>'
    + '<tr><td>Screensaver</td><td>'+esc(JSON.stringify(s.screensaver))+'</td></tr>'
    + '<tr><td>Active profile</td><td>'+esc(String(s.activeProfileId))+'</td></tr>'
    + '<tr><td>Profiles</td><td>'+s.profiles.length+'</td></tr>'
    + '<tr><td>Scenes</td><td>'+s.scenes.length+'</td></tr>'
    + '<tr><td>Zip assets</td><td>'+s.assets.length+'</td></tr>'
    + '</table>'));
  if (s.profiles.length) cfg.appendChild($('<pre>'+esc(JSON.stringify(s.profiles, null, 1))+'</pre>'));
  if (s.scenes.length) cfg.appendChild($('<pre>'+esc(JSON.stringify(s.scenes, null, 1))+'</pre>'));
  main.appendChild(cfg);

  // Log
  const lc = $('<section class="card"><h2>Frame log</h2><div class="log"></div></section>');
  const lwrap = lc.querySelector('.log');
  for (const e of s.log) {
    const t = new Date(e.ts).toLocaleTimeString();
    lwrap.appendChild($('<div class="l '+e.dir+'"><span class="chan">'+t+' ['+e.chan+'] </span>'
      + (e.dir==='in'?'← ':e.dir==='out'?'→ ':'· ') + esc(e.text) + '</div>'));
  }
  lwrap.scrollTop = lwrap.scrollHeight;
  main.appendChild(lc);
}
tick();
setInterval(tick, 1500);
</script>
</body>
</html>`;
