/**
 * Decoders that REVERSE the exact CoreBar upload encoders:
 *   - Sources/UltraBarKit/DeviceImage.swift  (RGB565(+alpha) + 8-byte header)
 *   - Sources/UltraBarKit/DeployPackager.swift (gzip + ustar tar "deploy package")
 *
 * Turns an uploaded VivoCube .tgz package back into a viewable PNG.
 */

import zlib from 'node:zlib';
import { Readable } from 'node:stream';
import * as tar from 'tar-stream';
import { PNG } from 'pngjs';

export interface DecodedBin {
  width: number;
  height: number;
  hasAlpha: boolean;
  /** RGBA8888, row-major, width*height*4 bytes. */
  rgba: Buffer;
}

/**
 * Decode the 8-byte header + RGB565(+alpha) payload produced by
 * DeviceImage.encode(). Mirrors it in reverse.
 *
 * Header:
 *   word  = uint32 LE @0 = (((width & 0x7FF) | (height << 11)) << 10) | (hasAlpha ? 5 : 4)
 *   bytes = uint32 LE @4 = width*height*bpp
 * Pixels: RGB565 big-endian (high byte first), then 1 alpha byte if hasAlpha.
 */
export function decodeDeviceImage(bin: Buffer): DecodedBin {
  if (bin.length < 8) throw new Error(`bin too short: ${bin.length} bytes`);

  const word = bin.readUInt32LE(0);
  const payloadCount = bin.readUInt32LE(4);
  const flag = word & 0x3ff; // low 10 bits: 4 = opaque (2bpp), 5 = alpha (3bpp)
  const v = word >>> 10; // (width & 0x7FF) | (height << 11)
  const width = v & 0x7ff;
  const height = v >>> 11;
  const hasAlpha = (flag & 0x1) === 1; // 5 → alpha, 4 → opaque
  const bpp = hasAlpha ? 3 : 2;

  const expected = width * height * bpp;
  if (width <= 0 || height <= 0) {
    throw new Error(`bad dimensions ${width}x${height} (word=0x${word.toString(16)})`);
  }
  if (payloadCount !== expected) {
    // Not fatal: trust the derived dimensions, but surface the mismatch.
    // (payloadCount in the header should equal width*height*bpp.)
    // eslint-disable-next-line no-console
    console.warn(
      `[decode] header payload=${payloadCount} != width*height*bpp=${expected} (continuing)`,
    );
  }
  if (bin.length < 8 + expected) {
    throw new Error(`payload short: have ${bin.length - 8}, need ${expected}`);
  }

  const rgba = Buffer.alloc(width * height * 4);
  let i = 8;
  let o = 0;
  for (let p = 0; p < width * height; p++) {
    const hi = bin[i++];
    const lo = bin[i++];
    const val = (hi << 8) | lo;
    const r5 = (val >> 11) & 0x1f;
    const g6 = (val >> 5) & 0x3f;
    const b5 = val & 0x1f;
    // Expand to 8-bit. The encoder truncated (r>>3 etc.); we scale back up.
    rgba[o++] = (r5 << 3) | (r5 >> 2);
    rgba[o++] = (g6 << 2) | (g6 >> 4);
    rgba[o++] = (b5 << 3) | (b5 >> 2);
    rgba[o++] = hasAlpha ? bin[i++] : 0xff;
  }

  return { width, height, hasAlpha, rgba };
}

/** Encode a decoded RGBA image to a PNG buffer. */
export function rgbaToPng(dec: DecodedBin): Buffer {
  const png = new PNG({ width: dec.width, height: dec.height });
  dec.rgba.copy(png.data);
  return PNG.sync.write(png);
}

export interface ExtractedPackage {
  /** All tar member names → raw bytes. */
  members: Map<string, Buffer>;
  /** Parsed config.json if present. */
  config?: unknown;
  /** widgetId → { default, pressed } decoded images. */
  widgets: Map<number, { default?: DecodedBin; pressed?: DecodedBin }>;
}

/**
 * gunzip → untar an uploaded module deploy package and decode every
 * com_res<widgetId>/{default,pressed}.bin into RGBA.
 */
export async function decodePackage(tgz: Buffer): Promise<ExtractedPackage> {
  // DeployPackager.gzip() prepends a standard gzip header around a raw DEFLATE
  // stream, so Node's gunzip handles it (as it does any other client's gzip).
  const tarBuf = zlib.gunzipSync(tgz);

  const members = new Map<string, Buffer>();
  const extract = tar.extract();

  await new Promise<void>((resolve, reject) => {
    extract.on('entry', (header, stream, next) => {
      const chunks: Buffer[] = [];
      stream.on('data', (c: unknown) => chunks.push(c as Buffer));
      stream.on('end', () => {
        members.set(header.name, Buffer.concat(chunks));
        next();
      });
      stream.on('error', reject);
      stream.resume();
    });
    extract.on('finish', resolve);
    extract.on('error', reject);
    Readable.from(tarBuf).pipe(extract);
  });

  const widgets = new Map<number, { default?: DecodedBin; pressed?: DecodedBin }>();
  for (const [name, bytes] of members) {
    const m = name.match(/^com_res(\d+)\/(default|pressed)\.bin$/);
    if (!m) continue;
    const widgetId = parseInt(m[1], 10);
    const kind = m[2] as 'default' | 'pressed';
    let entry = widgets.get(widgetId);
    if (!entry) {
      entry = {};
      widgets.set(widgetId, entry);
    }
    try {
      entry[kind] = decodeDeviceImage(bytes);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn(`[decode] ${name}: ${(e as Error).message}`);
    }
  }

  let config: unknown;
  const cfg = members.get('config.json');
  if (cfg) {
    try {
      config = JSON.parse(cfg.toString('utf8'));
    } catch {
      /* ignore malformed config */
    }
  }

  return { members, config, widgets };
}
