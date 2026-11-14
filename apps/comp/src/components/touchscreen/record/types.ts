"use client";

import { getBridge, hasBridge } from "@/lib/blitzRenderer";

/** Mirrors `RecorderStatus` from the recorder contract (electron/nt-recorder.cjs). */
export interface RecorderStatus {
  isRecording: boolean;
  isConnected: boolean;
  host: string;
  port: number;
  sessionId: string | null;
  startedAtIso: string | null;
  elapsedMs: number;
  bytesWritten: number;
  topicCount: number;
  sampleCount: number;
  samplesPerSecond: number;
  hadConnectionLoss: boolean;
  autoRecord: boolean;
  robotEnabled: boolean;
  recordingsDir: string;
  lastError: string | null;
  video: { active: boolean; deviceLabel: string | null; bytesWritten: number } | null;
}

/** Mirrors `SessionSummary` from the recorder contract (also the `<id>.json` sidecar). */
export interface SessionSummary {
  id: string;
  logPath: string;
  logBytes: number;
  videoPath: string | null;
  videoBytes: number | null;
  videoStartOffsetMs: number | null;
  startedAtIso: string;
  endedAtIso: string | null;
  durationMs: number;
  topicCount: number;
  sampleCount: number;
  host: string;
  port: number;
  hadConnectionLoss: boolean;
  autoStarted: boolean;
  note: string | null;
}

/**
 * Narrow local view of `window.blitzRenderer.recorder`. The orchestrator adds the
 * real typing to `@/lib/blitzRenderer` later; until then we cast through this.
 */
export interface RecorderBridge {
  getStatus: () => Promise<RecorderStatus>;
  subscribeStatus: (callback: (status: RecorderStatus) => void) => number;
  unsubscribeStatus: (callbackId: number) => void;
  start: (opts?: { note?: string }) => Promise<SessionSummary>;
  /** Null when there was nothing to stop: no session, or a stop already in flight. */
  stop: () => Promise<SessionSummary | null>;
  listSessions: () => Promise<SessionSummary[]>;
  deleteSession: (id: string) => Promise<void>;
  revealSession: (id: string) => Promise<void>;
  setAutoRecord: (enabled: boolean) => Promise<RecorderStatus>;
  chooseRecordingsDir: () => Promise<string | null>;
  setRecordingsDir: (dir: string) => Promise<RecorderStatus>;
  beginVideo: (info: { deviceLabel: string; mimeType: string }) => Promise<void>;
  appendVideoChunk: (chunk: Uint8Array) => Promise<void>;
  endVideo: () => Promise<void>;
}

/** Null when running outside Electron or before the orchestrator wires the bridge. */
export function getRecorderBridge(): RecorderBridge | null {
  if (!hasBridge()) return null;
  const bridge = getBridge() as unknown as { recorder?: RecorderBridge };
  return bridge.recorder ?? null;
}

/** macOS TCC state for the camera. Platforms without TCC always report "granted". */
export type CameraAccessStatus = "not-determined" | "granted" | "denied" | "restricted" | "unknown";

export interface MediaBridge {
  getCameraStatus: () => Promise<CameraAccessStatus>;
  /** Raises the OS prompt while the grant is undecided; resolves to the settled status. */
  requestCamera: () => Promise<CameraAccessStatus>;
  openCameraSettings: () => Promise<void>;
}

export function getMediaBridge(): MediaBridge | null {
  if (!hasBridge()) return null;
  const bridge = getBridge() as unknown as { media?: MediaBridge };
  return bridge.media ?? null;
}
