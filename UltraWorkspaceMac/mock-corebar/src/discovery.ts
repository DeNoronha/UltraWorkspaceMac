/**
 * UDP discovery server (:5319).
 *
 * Mirrors Sources/UltraBarKit/Discovery.swift: the client broadcasts
 * `{"act":"discover"}` to 255.255.255.255:5319; we reply (to the sender) with a
 * descriptor JSON that the client's `parse()` accepts — it REQUIRES a `tcpPort`
 * field and also reads `serialNo`, `ver`, `ip`, `name`.
 */

import dgram from 'node:dgram';
import { Ports } from './protocol';
import { state } from './state';

export function startDiscovery(): dgram.Socket {
  const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  sock.on('error', (err) => {
    state.record('evt', 'udp', `discovery socket error: ${err.message}`);
  });

  sock.on('message', (msg, rinfo) => {
    const text = msg.toString('utf8').trim();
    state.record('in', 'udp', `${rinfo.address}:${rinfo.port} ${text}`);

    let isDiscover = false;
    try {
      const obj = JSON.parse(text);
      isDiscover = obj && obj.act === 'discover';
    } catch {
      // Tolerate non-JSON probes; match on the substring as a fallback.
      isDiscover = text.includes('"discover"');
    }
    if (!isDiscover) return;

    const descriptor = {
      serialNo: state.serialNo,
      ver: state.version,
      ip: state.ip,
      name: state.name,
      tcpPort: Ports.control,
    };
    const reply = Buffer.from(JSON.stringify(descriptor));
    sock.send(reply, rinfo.port, rinfo.address, (err) => {
      if (err) {
        state.record('evt', 'udp', `reply send failed: ${err.message}`);
      } else {
        state.record('out', 'udp', `${rinfo.address}:${rinfo.port} ${descriptor.serialNo} tcpPort=${descriptor.tcpPort}`);
      }
    });
  });

  sock.bind(Ports.discovery, () => {
    try {
      sock.setBroadcast(true);
    } catch {
      /* ignore */
    }
    state.record('evt', 'sys', `UDP discovery listening on :${Ports.discovery}`);
  });

  return sock;
}
