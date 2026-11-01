/**
 * Self-signed certificate for the TLS control socket, issued for SNI
 * "ultrabar.local". The real CoreBar presents a self-signed cert and the client
 * uses trust-on-first-use (pins the leaf SHA-256), so any self-signed cert works.
 */

import selfsigned from 'selfsigned';
import { TLS_HOST } from './protocol';

export interface Pems {
  key: string;
  cert: string;
}

export function generateSelfSigned(): Pems {
  const attrs = [{ name: 'commonName', value: TLS_HOST }];
  const pems = selfsigned.generate(attrs, {
    days: 3650,
    keySize: 2048,
    algorithm: 'sha256',
    extensions: [
      {
        name: 'subjectAltName',
        altNames: [
          { type: 2, value: TLS_HOST }, // DNS: ultrabar.local
          { type: 2, value: 'localhost' },
          { type: 7, ip: '127.0.0.1' }, // IP
        ],
      },
    ],
  });
  return { key: pems.private, cert: pems.cert };
}
