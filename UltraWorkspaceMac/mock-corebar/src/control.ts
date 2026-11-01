/**
 * TLS control server (:7431).
 *
 * Line-delimited JSON frames {act, data, id}. Replies are
 * {act, code, msg, data, id, timestamp}. Some acts push extra frames
 * (30102 discovery replay, 1635 Wi-Fi list). Mirrors the framing in
 * Sources/UltraBarKit/CoreBarClient.swift.
 */

import tls from 'node:tls';
import crypto from 'node:crypto';
import { Act, Ports, reply, type RequestFrame, type ReplyFrame } from './protocol';
import { state } from './state';
import { generateSelfSigned } from './cert';

function newId(): string {
  return crypto.randomUUID().replace(/-/g, '');
}

/** Write one JSON frame followed by '\n' (the client splits on newlines). */
function sendFrame(socket: tls.TLSSocket, frame: object, note?: string): void {
  const line = JSON.stringify(frame);
  socket.write(line + '\n');
  state.record('out', 'tls', note ? `${note} ${line}` : line);
}

/** A pushed frame (device-initiated) carries code 200 and a fresh id. */
function pushFrame(socket: tls.TLSSocket, act: number, data: unknown): void {
  const frame: ReplyFrame = {
    act,
    code: 200,
    msg: 'ok',
    data,
    id: newId(),
    timestamp: Date.now(),
  };
  sendFrame(socket, frame, `PUSH act=${act}`);
}

function handleFrame(socket: tls.TLSSocket, req: RequestFrame): void {
  const { act, id } = req;
  const data = req.data;

  switch (act) {
    case Act.REQ_AUTH_TOKEN: {
      // Simulate the user walking to the device and tapping "Approve" ~1s later.
      state.record('evt', 'tls', 'Pairing requested — waiting for Approve…');
      setTimeout(() => {
        const token = 'mock-token-' + newId().slice(0, 16);
        state.issuedToken = token;
        state.record('evt', 'tls', 'Approve tapped — issuing token ' + token);
        sendFrame(socket, reply(Act.REQ_AUTH_TOKEN, id, { token }));
      }, 1000);
      return;
    }

    case Act.AUTH: {
      // Accept any token (and the one we issued). data is the token string.
      state.record('evt', 'tls', `AUTH token="${String(data)}" accepted`);
      sendFrame(socket, reply(Act.AUTH, id, null));
      return;
    }

    case Act.GET_DEVICE: {
      // A small logical/integration device list. (Physical modules come from
      // the live bus scan, 30100 → 30102; see PROTOCOL.md.)
      const devices = [
        { id: 'pcboot-1', name: 'PC Boot Card', deviceType: 'PC_BOOT', online: true },
        { id: 'computer-1', name: 'This PC', deviceType: 'COMPUTER_INFO', online: true },
      ];
      sendFrame(socket, reply(Act.GET_DEVICE, id, devices));
      return;
    }

    case Act.GET_APP_LIST: {
      const apps = [
        { id: 'com.ultrabar.launch', name: 'LineOS Launcher' },
        { id: 'com.ultrabar.screensaver', name: 'Screensaver' },
      ];
      sendFrame(socket, reply(Act.GET_APP_LIST, id, apps));
      return;
    }

    case Act.MODULE_START_DISCOVERY: {
      const bus = String(data); // "can" | "mesh"
      state.record('evt', 'tls', `MODULE_START_DISCOVERY bus="${bus}"`);
      // Fire-and-forget on the client side; results arrive as pushed 30102.
      const matches = state.modules.filter((m) => m.interfaceType === bus);
      // Stagger the pushes slightly, like a real bus scan trickling in.
      matches.forEach((m, idx) => {
        setTimeout(() => {
          pushFrame(socket, Act.MODULE_START_DISCOVERY_REPLAY, {
            serialNumber: m.serialNo,
            serialNo: m.serialNo,
            uid: m.serialNo,
            name: m.name,
            online: m.online,
            productId: m.productId,
            interfaceType: m.interfaceType,
          });
        }, 150 * (idx + 1));
      });
      // Also ack the request itself (harmless; the client collects act 30102).
      sendFrame(socket, reply(Act.MODULE_START_DISCOVERY, id, null));
      return;
    }

    case Act.MODULE_STOP_DISCOVERY: {
      sendFrame(socket, reply(Act.MODULE_STOP_DISCOVERY, id, null));
      return;
    }

    case Act.SET_GATEWAY_CONFIG: {
      state.gatewayConfig = data ?? state.gatewayConfig;
      state.record('evt', 'tls', 'SET_GATEWAY_CONFIG stored');
      sendFrame(socket, reply(Act.SET_GATEWAY_CONFIG, id, null));
      return;
    }

    case Act.MODULE_PROPERTY_READ: {
      const d = (data ?? {}) as { serialNo?: string; deviceId?: number; propertyId?: number };
      const key = `${d.deviceId}/${d.propertyId}`;
      let result: number | null = null;
      if (key in state.sensors) {
        result = state.sensors[key];
      } else {
        // Non-sensor read (e.g. VivoCube screen propertyId 4): return a plausible value.
        result = d.propertyId === 4 ? 1 : 0;
      }
      sendFrame(
        socket,
        reply(Act.MODULE_PROPERTY_READ, id, {
          serialNo: d.serialNo,
          deviceId: d.deviceId,
          propertyId: d.propertyId,
          result,
        }),
      );
      return;
    }

    case Act.MODULE_PROPERTY_WRITE: {
      const d = (data ?? {}) as { deviceId?: number; propertyId?: number; value?: unknown };
      state.record('evt', 'tls', `MODULE_PROPERTY_WRITE ${d.deviceId}/${d.propertyId} = ${JSON.stringify(d.value)}`);
      // Success replies strip the `result` field (per asyncapi.yaml).
      sendFrame(socket, reply(Act.MODULE_PROPERTY_WRITE, id, null));
      return;
    }

    case Act.QUERY_MODULE_STATE: {
      // Empty on tested firmware; mirror that.
      sendFrame(socket, reply(Act.QUERY_MODULE_STATE, id, []));
      return;
    }

    case Act.GET_COREBAR_CONFIG: {
      const d = (data ?? {}) as { type?: string };
      if (d.type === 'BASE_SET') {
        sendFrame(socket, reply(Act.GET_COREBAR_CONFIG, id, state.screensaver));
      } else if (d.type === 'APP_LIST') {
        sendFrame(socket, reply(Act.GET_COREBAR_CONFIG, id, []));
      } else {
        // GATEWAY_CONFIG get() returns null on the device.
        sendFrame(socket, reply(Act.GET_COREBAR_CONFIG, id, null));
      }
      return;
    }

    case Act.SET_COREBAR_CONFIG: {
      const d = (data ?? {}) as { type?: string; value?: unknown };
      if (d.type === 'BASE_SET' && d.value && typeof d.value === 'object') {
        state.screensaver = { ...state.screensaver, ...(d.value as object) };
        state.record('evt', 'tls', 'SET_COREBAR_CONFIG BASE_SET (screensaver) stored');
      } else if (d.type === 'GATEWAY_CONFIG') {
        state.gatewayConfig = d.value ?? state.gatewayConfig;
        state.record('evt', 'tls', 'SET_COREBAR_CONFIG GATEWAY_CONFIG stored');
      }
      sendFrame(socket, reply(Act.SET_COREBAR_CONFIG, id, null));
      return;
    }

    case Act.PREVIEW_SCREENSAVER: {
      const d = (data ?? {}) as { url?: string; mediaType?: string };
      state.preview = {
        url: d.url ?? '',
        mediaType: d.mediaType ?? 'IMAGE',
        at: Date.now(),
      };
      state.record('evt', 'tls', `PREVIEW_SCREENSAVER url="${state.preview.url}" (${state.preview.mediaType})`);
      sendFrame(socket, reply(Act.PREVIEW_SCREENSAVER, id, null));
      return;
    }

    case Act.SYS_REBOOT: {
      state.record('evt', 'tls', 'SYS_REBOOT (mock: ignored)');
      sendFrame(socket, reply(Act.SYS_REBOOT, id, null));
      return;
    }

    case Act.START_SCAN_WIFI: {
      sendFrame(socket, reply(Act.START_SCAN_WIFI, id, null));
      // Push a Wi-Fi list a moment later (open networks filtered out by device).
      setTimeout(() => {
        pushFrame(socket, Act.CUBE_SCAN_WIFI_LIST_RESULT, [
          { name: 'MockNet-5G', signal: -48, frequency: 5180 },
          { name: 'Office-WiFi', signal: -63, frequency: 2437 },
        ]);
      }, 500);
      return;
    }

    case Act.STOP_SCAN_WIFI: {
      sendFrame(socket, reply(Act.STOP_SCAN_WIFI, id, null));
      return;
    }

    case Act.BATCH_SAVE_PROFILE: {
      state.profiles = Array.isArray(data) ? (data as unknown[]) : [];
      state.record('evt', 'tls', `BATCH_SAVE_PROFILE stored ${state.profiles.length} profile(s)`);
      sendFrame(socket, reply(Act.BATCH_SAVE_PROFILE, id, null));
      return;
    }

    case Act.BATCH_CREATE_SCENE: {
      state.scenes = Array.isArray(data) ? (data as unknown[]) : [];
      state.record('evt', 'tls', `BATCH_CREATE_SCENE stored ${state.scenes.length} scene(s)`);
      sendFrame(socket, reply(Act.BATCH_CREATE_SCENE, id, null));
      return;
    }

    case Act.TRIGGER_PROFILE_CHANGE: {
      state.activeProfileId = String(data ?? '');
      state.record('evt', 'tls', `TRIGGER_PROFILE_CHANGE active="${state.activeProfileId}"`);
      sendFrame(socket, reply(Act.TRIGGER_PROFILE_CHANGE, id, null));
      return;
    }

    default: {
      // Unknown acts: reply code 200 with empty data so new client calls don't
      // break testing, and log them for discovery.
      state.record('evt', 'tls', `UNKNOWN act=${act} data=${JSON.stringify(data ?? null)}`);
      sendFrame(socket, reply(act, id, null));
      return;
    }
  }
}

export function startControl(): tls.Server {
  const pems = generateSelfSigned();
  const fingerprint = crypto
    .createHash('sha256')
    .update(new crypto.X509Certificate(pems.cert).raw)
    .digest('hex')
    .toUpperCase();

  const server = tls.createServer({ key: pems.key, cert: pems.cert }, (socket) => {
    const peer = `${socket.remoteAddress}:${socket.remotePort}`;
    state.record('evt', 'tls', `client connected ${peer}`);

    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk: string) => {
      buffer += chunk;
      let nl: number;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl).replace(/\r$/, '');
        buffer = buffer.slice(nl + 1);
        if (!line.trim()) continue;
        state.record('in', 'tls', line);
        let req: RequestFrame;
        try {
          req = JSON.parse(line);
        } catch (e) {
          state.record('evt', 'tls', `bad JSON: ${(e as Error).message}`);
          continue;
        }
        try {
          handleFrame(socket, req);
        } catch (e) {
          state.record('evt', 'tls', `handler error for act=${req.act}: ${(e as Error).message}`);
          sendFrame(socket, reply(req.act, req.id, null, 11, 'exception'));
        }
      }
    });

    socket.on('error', (err) => state.record('evt', 'tls', `socket error ${peer}: ${err.message}`));
    socket.on('close', () => state.record('evt', 'tls', `client disconnected ${peer}`));
  });

  server.on('tlsClientError', (err) => {
    state.record('evt', 'tls', `tlsClientError: ${err.message}`);
  });

  server.listen(Ports.control, () => {
    state.record('evt', 'sys', `TLS control listening on :${Ports.control} (SNI ultrabar.local)`);
    state.record('evt', 'sys', `leaf cert SHA-256 = ${fingerprint}`);
  });

  return server;
}
