/**
 * HTTP upload server (:8080).
 *
 *  POST /upload?serialNo=<serial>   multipart field `file`  — a module .tgz
 *      (gzip+ustar RGB565 deploy package). We DECODE it to a PNG and store the
 *      latest image per serialNo. Returns {"state":200,"msg":"ok"}.
 *
 *  POST /upload/zip?subDir=&isFull=  multipart field `file` — a .zip of plain
 *      images for the big screen. We unzip and store images under subDir.
 *
 * The real :8080 surface is unauthenticated (openapi.yaml); the mock rejects
 * nothing — it just logs sizes.
 */

import express from 'express';
import multer from 'multer';
import AdmZip from 'adm-zip';
import path from 'node:path';
import { Ports } from './protocol';
import { state } from './state';
import { decodePackage, rgbaToPng } from './decodeImage';

const IMAGE_EXT = new Set(['.jpg', '.jpeg', '.png', '.webp', '.gif']);
const CONTENT_TYPES: Record<string, string> = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
};

export function startHttpUpload(): import('http').Server {
  const app = express();
  const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 64 * 1024 * 1024 } });

  // POST /upload?serialNo= — module .tgz deploy package.
  app.post('/upload', upload.single('file'), async (req, res) => {
    const serialNo = String(req.query.serialNo ?? '');
    const file = req.file;
    if (!file) {
      state.record('in', 'http', `POST /upload?serialNo=${serialNo} — no file`);
      res.json({ state: 200, msg: 'ok' });
      return;
    }
    state.record('in', 'http', `POST /upload?serialNo=${serialNo} (${file.size} B tgz)`);

    try {
      const pkg = await decodePackage(file.buffer);
      // Pick the first widget that has a decoded default image.
      let stored = false;
      for (const [widgetId, imgs] of pkg.widgets) {
        const img = imgs.default ?? imgs.pressed;
        if (!img) continue;
        state.images.set(serialNo, {
          png: rgbaToPng(img),
          width: img.width,
          height: img.height,
          hasAlpha: img.hasAlpha,
          widgetId,
          serialNo,
          receivedAt: Date.now(),
          packageBytes: file.size,
        });
        state.record(
          'evt',
          'http',
          `decoded widget ${widgetId} → ${img.width}x${img.height}${img.hasAlpha ? ' +alpha' : ''} for ${serialNo}`,
        );
        stored = true;
        break;
      }
      if (!stored) {
        state.record('evt', 'http', `no decodable com_res*/default.bin in package for ${serialNo}`);
      }
    } catch (e) {
      state.record('evt', 'http', `decode failed for ${serialNo}: ${(e as Error).message}`);
    }

    res.json({ state: 200, msg: 'ok' });
  });

  // POST /upload/zip?subDir=&isFull= — big-screen image zip.
  app.post('/upload/zip', upload.single('file'), (req, res) => {
    const subDir = String(req.query.subDir ?? '');
    const isFull = String(req.query.isFull ?? 'true') === 'true';
    const file = req.file;
    if (!file) {
      state.record('in', 'http', `POST /upload/zip?subDir=${subDir}&isFull=${isFull} — no file`);
      res.json({ state: 200, msg: 'ok', count: 0 });
      return;
    }
    state.record('in', 'http', `POST /upload/zip?subDir=${subDir}&isFull=${isFull} (${file.size} B zip)`);

    if (isFull) {
      // Wipe the target subdir first (full replace).
      const prefix = subDir ? subDir.replace(/\/+$/, '') + '/' : '';
      for (const key of [...state.assets.keys()]) {
        if (!prefix || key.startsWith(prefix)) state.assets.delete(key);
      }
    }

    let count = 0;
    try {
      const zip = new AdmZip(file.buffer);
      for (const entry of zip.getEntries()) {
        if (entry.isDirectory) continue;
        const name = entry.entryName;
        if (name.includes('__MACOSX') || name.endsWith('.DS_Store')) continue;
        if (name.includes('..')) continue; // block traversal
        const ext = path.extname(name).toLowerCase();
        if (!IMAGE_EXT.has(ext)) continue;
        const rel = subDir ? `${subDir.replace(/\/+$/, '')}/${name}` : name;
        const dataBuf = entry.getData();
        state.assets.set(rel, {
          path: rel,
          bytes: dataBuf.length,
          contentType: CONTENT_TYPES[ext] ?? 'application/octet-stream',
          data: dataBuf,
          at: Date.now(),
        });
        state.record('evt', 'http', `extracted ${rel} (${dataBuf.length} B)`);
        count++;
      }
    } catch (e) {
      state.record('evt', 'http', `unzip failed: ${(e as Error).message}`);
    }

    // openapi.yaml marks this body shape as unconfirmed; mirror /upload's shape.
    res.json({ state: 200, msg: 'ok', count });
  });

  // Minimal widget-icon stub (openapi.yaml /widget/icon) — returns a 1x1 PNG.
  app.get('/widget/icon', (_req, res) => {
    const onePx = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'base64',
    );
    res.type('image/png').send(onePx);
  });

  const server = app.listen(Ports.upload, () => {
    state.record('evt', 'sys', `HTTP upload listening on :${Ports.upload}`);
  });
  return server;
}
