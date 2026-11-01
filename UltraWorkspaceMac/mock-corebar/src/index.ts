/**
 * Mock CoreBar — entrypoint. Seeds fake QuantumLink modules and starts all four
 * servers: UDP discovery (:5319), TLS control (:7431), HTTP upload (:8080), and
 * the web viewer (:8081).
 */

import { ProductId } from './protocol';
import { state } from './state';
import { startDiscovery } from './discovery';
import { startControl } from './control';
import { startHttpUpload } from './http';
import { startViewer } from './viewer';

// Allow overriding the advertised IP (useful behind Docker: set MOCK_IP).
if (process.env.MOCK_IP) state.ip = process.env.MOCK_IP;

// Seed the fake modules reported by the live bus scan (30100 → 30102).
// Serials are realistic-looking 16-hex-char QuantumLink ids.
state.modules.push(
  {
    serialNo: 'A1B2C3D4E5F60001',
    name: 'Living Room Cube',
    productId: ProductId.VIVO_CUBE,
    productName: 'VIVO_CUBE',
    interfaceType: 'can',
    online: true,
  },
  {
    serialNo: 'A1B2C3D4E5F60002',
    name: 'Desk Sensor',
    productId: ProductId.SENSE_CUBE,
    productName: 'SENSE_CUBE',
    interfaceType: 'can',
    online: true,
  },
  {
    serialNo: 'A1B2C3D4E5F60003',
    name: 'Volume Knob',
    productId: ProductId.KNOB_KEY,
    productName: 'KNOB_KEY',
    interfaceType: 'can',
    online: true,
  },
  {
    serialNo: 'A1B2C3D4E5F60004',
    name: 'Macro Keys',
    productId: ProductId.DOT_KEY,
    productName: 'DOT_KEY',
    interfaceType: 'mesh',
    online: false, // asleep — exercises the merge-on-provision path
  },
);

function main(): void {
  state.record('evt', 'sys', '=== Mock CoreBar starting ===');
  startDiscovery();
  startControl();
  startHttpUpload();
  startViewer();
  state.record('evt', 'sys', 'All servers up. Open http://127.0.0.1:8081 for the viewer.');
}

main();

process.on('SIGINT', () => {
  state.record('evt', 'sys', 'SIGINT — shutting down');
  process.exit(0);
});
