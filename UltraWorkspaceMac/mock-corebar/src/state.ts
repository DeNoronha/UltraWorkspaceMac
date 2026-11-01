/**
 * Shared in-memory state for the mock, plus a bounded frame/event log that the
 * web viewer polls via /state.
 */

export interface LogEntry {
  ts: number;
  /** 'in' = received from client, 'out' = sent to client, 'evt' = internal. */
  dir: 'in' | 'out' | 'evt';
  /** Transport channel that produced the line. */
  chan: 'udp' | 'tls' | 'http' | 'sys';
  text: string;
}

export interface StoredImage {
  /** PNG bytes, served by the viewer. */
  png: Buffer;
  width: number;
  height: number;
  hasAlpha: boolean;
  widgetId: number;
  /** Which fake module this was uploaded to (serialNo). */
  serialNo: string;
  receivedAt: number;
  /** Raw uploaded package size in bytes. */
  packageBytes: number;
}

export interface FakeModule {
  serialNo: string;
  name: string;
  productId: number;
  productName: string;
  interfaceType: 'can' | 'mesh';
  online: boolean;
}

export interface PreviewRecord {
  url: string;
  mediaType: string;
  at: number;
  /** Like the real FullScreenMediaDialog: the device PULLS the image over HTTP. */
  fetched: boolean;
  fetchBytes?: number;
  fetchError?: string;
  /** Human note, e.g. why the real firmware would show nothing. */
  note?: string;
  /** Fetched image bytes + content type (served by the viewer at /img/preview). */
  image?: Buffer;
  imageType?: string;
}

export interface ZipAsset {
  path: string; // "<subDir>/<file>"
  bytes: number;
  contentType: string;
  data: Buffer;
  at: number;
}

class AppState {
  readonly serialNo = 'MOCK0000000000001';
  readonly name = 'Mock CoreBar';
  readonly version = '1.0.0-mock';
  /** Advertised LAN ip; discovery replies also fall back to the sender ip. */
  ip = '127.0.0.1';

  /** The token issued at pairing (any token is also accepted on AUTH). */
  issuedToken: string | null = null;

  /** Fake QuantumLink modules the bus scan reports. */
  readonly modules: FakeModule[] = [];

  /** Latest decoded image per module serialNo. */
  readonly images = new Map<string, StoredImage>();

  /** Latest PREVIEW_SCREENSAVER call. */
  preview: PreviewRecord | null = null;

  /** Current (fake) SenseCube sensor raw values, keyed by `${deviceId}/${propertyId}`. */
  readonly sensors: Record<string, number> = {
    '10/1': 473, // illuminance (lux)
    '11/1': 235, // temperature raw → 23.5 °C
    '12/1': 540, // humidity raw → 54.0 %RH
    '15/2': 0, // shock-wake state
  };

  /** Screensaver config (BASE_SET). */
  screensaver = {
    featureEnabled: true,
    lockTime: 'TIME_1MIN',
    packageName: '',
    uri: '',
    ver: 1,
  };

  /** Gateway endpoint config written by SET_GATEWAY_CONFIG. */
  gatewayConfig: unknown = { canGateway: { endpoints: [] }, meshGateway: { endpoints: [] } };

  /** Last saved profile list (BATCH_SAVE_PROFILE). */
  profiles: unknown[] = [];
  /** Last saved scene list (BATCH_CREATE_SCENE). */
  scenes: unknown[] = [];
  /** Active profile id (TRIGGER_PROFILE_CHANGE). */
  activeProfileId: string | null = null;

  /** Big-screen zip assets, keyed by relative path. */
  readonly assets = new Map<string, ZipAsset>();

  /** Bounded log ring. */
  private readonly log: LogEntry[] = [];
  private readonly maxLog = 500;

  record(dir: LogEntry['dir'], chan: LogEntry['chan'], text: string): void {
    const entry: LogEntry = { ts: Date.now(), dir, chan, text };
    this.log.push(entry);
    if (this.log.length > this.maxLog) this.log.shift();
    const arrow = dir === 'in' ? '←' : dir === 'out' ? '→' : '·';
    // eslint-disable-next-line no-console
    console.log(`[${chan}] ${arrow} ${text}`);
  }

  recentLog(limit = 200): LogEntry[] {
    return this.log.slice(-limit);
  }
}

export const state = new AppState();
