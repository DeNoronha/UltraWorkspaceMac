/**
 * Well-known numbers and act codes for the CoreBar local protocol.
 *
 * Sourced from PROTOCOL.md, api/asyncapi.yaml, and Sources/UltraBarKit/Models.swift
 * in this repo. The mock emulates the IP Network bridge only.
 */

export const Ports = {
  /** UDP discovery — `{"act":"discover"}` probes. */
  discovery: 5319,
  /** TLS control socket, line-delimited JSON, SNI "ultrabar.local". */
  control: 7431,
  /** HTTP upload server (module .tgz + big-screen .zip). */
  upload: 8080,
  /** Web viewer (mock-only; not part of the real device). */
  viewer: 8081,
} as const;

/** SNI the CoreBar self-signed cert is issued for. */
export const TLS_HOST = 'ultrabar.local';

/** Control "act" codes (LineOS MessageAction). */
export const Act = {
  ERROR: 10,
  EXCEPTION: 11,
  HEARTBEAT: 20,
  AUTH: 100, // data = "<token>"
  REQ_AUTH_TOKEN: 101, // data = {id, clientType:"pc", name} → data.token after Approve
  GET_APP_LIST: 1000,
  GET_PROFILE_WIDGET: 1002,
  TRIGGER_PROFILE_CHANGE: 1103, // data = profile id string
  BATCH_SAVE_PROFILE: 1108, // data = [ProfileDTO] (full-replace)
  SCENE_ACTION_V2: 1205,
  GET_DEVICE: 1300,
  START_SCAN_WIFI: 1633,
  STOP_SCAN_WIFI: 1634,
  CUBE_SCAN_WIFI_LIST_RESULT: 1635, // pushed
  SYS_REBOOT: 20100,
  MODULE_START_DISCOVERY: 30100, // data "can" | "mesh"
  MODULE_STOP_DISCOVERY: 30101,
  MODULE_START_DISCOVERY_REPLAY: 30102, // pushed, one per module
  MODULE_PROPERTY_READ: 30200,
  MODULE_PROPERTY_WRITE: 30201,
  SET_GATEWAY_CONFIG: 30300, // body is CoreBarConfiguration directly
  BATCH_CREATE_SCENE: 30500, // data = [Scene] (full-replace)
  SCENE_DEPENDS_DEVICES: 30701,
  SCENE_DEPENDS_DEVICES_PROPERTY: 30702,
  SCENE_DEPENDS_DEVICES_PROPERTY_VALUE: 30703,
  QUERY_MODULE_STATE: 30730,
  GET_COREBAR_CONFIG: 30740, // data = {type:"BASE_SET"|...}
  SET_COREBAR_CONFIG: 30741, // data = {type, value}
  PREVIEW_SCREENSAVER: 30742, // data = {url, mediaType}
  PUSH_MESSAGE: 1000000, // pushed device→client
} as const;

/** QLinkProductId — physical module type ids (PROTOCOL.md). */
export const ProductId = {
  EXT_SCREEN: 268435456,
  DOT_KEY: 268435457,
  KNOB_KEY: 268435458,
  VIVO_CUBE: 268435459,
  SENSE_CUBE: 268435460,
  PC_BOOT_CARD: 268435461,
  GATEWAY: -1,
} as const;

/** Logical device id of a module's main device (VivoCube). */
export const DEVICE_MAIN = 256;

/** The inbound request envelope: {act, data, id}. */
export interface RequestFrame {
  act: number;
  id?: string;
  data?: unknown;
  code?: number;
}

/** The outbound reply envelope: {act, code, msg, data, id, timestamp}. */
export interface ReplyFrame {
  act: number;
  code: number;
  msg: string;
  data: unknown;
  id: string;
  timestamp: number;
}

/** Build a standard reply envelope. */
export function reply(
  act: number,
  id: string | undefined,
  data: unknown = null,
  code = 200,
  msg = 'ok',
): ReplyFrame {
  return {
    act,
    code,
    msg,
    data,
    id: id ?? '',
    timestamp: Date.now(),
  };
}
