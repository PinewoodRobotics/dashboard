import { useCallback, useEffect, useRef, useState } from "react";
import type { RefObject } from "react";
import { syncPreviewElement } from "./logic";
import { getMediaBridge, type CameraAccessStatus } from "./types";

export const FIELD_CAMERA_STORAGE_KEY = "pwrup.touchscreen.record.camera.v1";

/** Chunk cadence: a crash costs at most one second of video. */
const CHUNK_TIMESLICE_MS = 1000;

/** Hard ceiling on how long we wait for MediaRecorder to flush before releasing tracks. */
const STOP_FLUSH_TIMEOUT_MS = 2000;

const PREFERRED_MIME_TYPES = [
  "video/webm;codecs=vp9",
  "video/webm;codecs=vp8",
  "video/webm",
];

const DEVICE_MISSING_ERROR = "Selected camera is not connected.";

export const CAMERA_BLOCKED_ERROR =
  "The system is blocking camera access for this app. Grant it under Privacy & Security › Camera.";

export interface FieldCameraDevice {
  deviceId: string;
  label: string;
}

export interface FieldCameraState {
  supported: boolean;
  devices: FieldCameraDevice[];
  selectedDeviceId: string | null;
  /** User wants video recorded alongside the log. */
  enabled: boolean;
  /** MediaRecorder currently running. */
  active: boolean;
  error: string | null;
  previewRef: RefObject<HTMLVideoElement | null>;
}

export interface FieldCameraControls {
  setEnabled(v: boolean): void;
  selectDevice(deviceId: string): void;
  refreshDevices(): Promise<void>;
  /**
   * Callback ref for the preview <video>. Unlike a plain ref, this attaches
   * the element to an already-running stream, so a tab that mounts mid-capture
   * shows live video immediately.
   */
  attachPreview(el: HTMLVideoElement | null): void;
  /** Opens the OS privacy pane; only meaningful while `error` is CAMERA_BLOCKED_ERROR. */
  openCameraSettings(): void;
}

/**
 * The slice of the recorder bridge this hook needs. Declared locally rather than
 * imported so the hook typechecks before the preload bridge types are widened.
 */
interface RecorderVideoBridge {
  beginVideo: (info: { deviceLabel: string; mimeType: string }) => Promise<void>;
  appendVideoChunk: (chunk: Uint8Array) => Promise<void>;
  endVideo: () => Promise<void>;
}

interface PersistedCameraState {
  enabled: boolean;
  selectedDeviceId: string | null;
}

interface CaptureSession {
  stream: MediaStream;
  recorder: MediaRecorder | null;
  /** Serializes chunk appends so the sink receives them in order. */
  chain: Promise<void>;
  /** True once beginVideo resolved, so we know an endVideo is owed. */
  opened: boolean;
  /** Guards against two teardown paths racing on the same session. */
  torn: boolean;
}

function getRecorderBridge(): RecorderVideoBridge | null {
  if (typeof window === "undefined") {
    return null;
  }
  const bridge = (window as unknown as {
    blitzRenderer?: { recorder?: RecorderVideoBridge };
  }).blitzRenderer;
  return bridge?.recorder ?? null;
}

function detectSupport(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof navigator !== "undefined" &&
    typeof navigator.mediaDevices?.getUserMedia === "function" &&
    typeof navigator.mediaDevices?.enumerateDevices === "function" &&
    typeof window.MediaRecorder !== "undefined"
  );
}

function pickMimeType(): string | null {
  if (typeof window === "undefined" || typeof window.MediaRecorder === "undefined") {
    return null;
  }
  for (const mimeType of PREFERRED_MIME_TYPES) {
    if (window.MediaRecorder.isTypeSupported(mimeType)) {
      return mimeType;
    }
  }
  return null;
}

function loadPersistedState(): PersistedCameraState {
  const fallback: PersistedCameraState = { enabled: false, selectedDeviceId: null };

  if (typeof window === "undefined" || typeof window.localStorage?.getItem !== "function") {
    return fallback;
  }

  try {
    const raw = window.localStorage.getItem(FIELD_CAMERA_STORAGE_KEY);
    if (!raw) {
      return fallback;
    }

    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object") {
      return fallback;
    }

    const source = parsed as { enabled?: unknown; selectedDeviceId?: unknown };
    return {
      enabled: source.enabled === true,
      selectedDeviceId:
        typeof source.selectedDeviceId === "string" && source.selectedDeviceId.length > 0
          ? source.selectedDeviceId
          : null,
    };
  } catch {
    return fallback;
  }
}

function savePersistedState(state: PersistedCameraState) {
  if (typeof window === "undefined" || typeof window.localStorage?.setItem !== "function") {
    return;
  }
  try {
    window.localStorage.setItem(FIELD_CAMERA_STORAGE_KEY, JSON.stringify(state));
  } catch {
    // Storage is best-effort; a full or disabled store must not break recording.
  }
}

function errorName(error: unknown): string {
  return error && typeof error === "object" && typeof (error as DOMException).name === "string"
    ? (error as DOMException).name
    : "";
}

function isPermissionDenial(error: unknown): boolean {
  const name = errorName(error);
  return name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError";
}

function describeMediaError(error: unknown): string {
  switch (errorName(error)) {
    case "NotAllowedError":
    case "SecurityError":
    case "PermissionDeniedError":
      return "Camera permission denied. Allow camera access, then try again.";
    case "NotFoundError":
    case "DevicesNotFoundError":
    case "OverconstrainedError":
    case "ConstraintNotSatisfiedError":
      return "Selected camera is not connected. Pick another device.";
    case "NotReadableError":
    case "TrackStartError":
      return "Camera is in use by another application.";
    case "AbortError":
      return "Camera could not be started.";
    default:
      break;
  }
  if (error instanceof Error && error.message) {
    return error.message;
  }
  return "Camera failed to start.";
}

/**
 * macOS gates the camera behind TCC before Chromium ever sees the request, and an
 * undecided grant makes getUserMedia fail rather than prompt. Settling it here — driven
 * by an explicit user action, with a window on screen — is what puts the OS prompt in
 * front of the user instead of behind a launcher they weren't looking at.
 */
async function ensureCameraAccess(): Promise<CameraAccessStatus> {
  const media = getMediaBridge();
  if (!media) {
    return "granted";
  }
  try {
    return await media.requestCamera();
  } catch {
    return "unknown";
  }
}

function isAccessBlocked(status: CameraAccessStatus): boolean {
  return status === "denied" || status === "restricted";
}

function stopStream(stream: MediaStream | null) {
  if (!stream) {
    return;
  }
  for (const track of stream.getTracks()) {
    try {
      track.stop();
    } catch {
      // A track that is already ended throws on some platforms; nothing to do.
    }
  }
}

/**
 * Webcam capture for the field camera that rides alongside an NT recording.
 *
 * Renders nothing: the caller wires `attachPreview` as the ref of a <video> element. The
 * stream only exists while a recording is in flight, so the camera LED is off when idle.
 *
 * Lifetime: this hook is owned by <FieldCameraProvider>, which wraps the whole dashboard.
 * It must NOT be called from a tab — tabs unmount when the user switches apps, and tearing
 * down capture mid-session truncates the session's video file (endVideo + re-beginVideo
 * re-opens the same path). The tab only consumes the provider's context.
 */
export function useFieldCamera(opts: { isRecording: boolean }): FieldCameraState & FieldCameraControls {
  const { isRecording } = opts;

  const [supported, setSupported] = useState(false);
  const [devices, setDevices] = useState<FieldCameraDevice[]>([]);
  const [selectedDeviceId, setSelectedDeviceId] = useState<string | null>(null);
  const [enabled, setEnabledState] = useState(false);
  const [active, setActive] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const previewRef = useRef<HTMLVideoElement | null>(null);
  const mountedRef = useRef(true);
  const sessionRef = useRef<CaptureSession | null>(null);
  const selectedDeviceIdRef = useRef<string | null>(null);
  const devicesRef = useRef<FieldCameraDevice[]>([]);
  const labelsUnlockedRef = useRef(false);
  /** Serializes start/stop so a fast toggle cannot interleave two sessions. */
  const captureQueueRef = useRef<Promise<void>>(Promise.resolve());

  selectedDeviceIdRef.current = selectedDeviceId;
  devicesRef.current = devices;

  const safeSetState = useCallback(<T,>(setter: (value: T) => void, value: T) => {
    if (mountedRef.current) {
      setter(value);
    }
  }, []);

  // Support detection and persisted preferences load happen after mount so the
  // server-rendered markup and the first client render agree.
  useEffect(() => {
    mountedRef.current = true;
    setSupported(detectSupport());
    const persisted = loadPersistedState();
    setEnabledState(persisted.enabled);
    setSelectedDeviceId(persisted.selectedDeviceId);
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const persist = useCallback((next: Partial<PersistedCameraState>) => {
    savePersistedState({
      enabled: next.enabled ?? enabled,
      selectedDeviceId:
        next.selectedDeviceId !== undefined ? next.selectedDeviceId : selectedDeviceIdRef.current,
    });
  }, [enabled]);

  const applyDevices = useCallback((list: FieldCameraDevice[]) => {
    if (!mountedRef.current) {
      return;
    }
    setDevices(list);

    // A device that was selected and has since been unplugged is surfaced as an
    // error rather than silently falling back to some other camera.
    const selected = selectedDeviceIdRef.current;
    if (selected && labelsUnlockedRef.current && !list.some((d) => d.deviceId === selected)) {
      setError((current) => current ?? DEVICE_MISSING_ERROR);
    } else {
      setError((current) => (current === DEVICE_MISSING_ERROR ? null : current));
    }
  }, []);

  const enumerate = useCallback(async (): Promise<FieldCameraDevice[]> => {
    if (!detectSupport()) {
      return [];
    }
    try {
      const all = await navigator.mediaDevices.enumerateDevices();
      const list = all
        .filter((device) => device.kind === "videoinput")
        .map((device, index) => ({
          deviceId: device.deviceId,
          label: device.label || `Camera ${index + 1}`,
        }));
      if (list.length > 0 && all.some((d) => d.kind === "videoinput" && d.label)) {
        labelsUnlockedRef.current = true;
      }
      applyDevices(list);
      return list;
    } catch (err) {
      safeSetState(setError, describeMediaError(err));
      return [];
    }
  }, [applyDevices, safeSetState]);

  /**
   * Device labels are empty strings until camera permission is granted. Open a
   * throwaway stream once to unlock them, release it immediately, re-enumerate.
   */
  const unlockLabels = useCallback(async () => {
    if (labelsUnlockedRef.current || !detectSupport() || sessionRef.current) {
      return;
    }
    if (isAccessBlocked(await ensureCameraAccess())) {
      setEnabledState(false);
      persist({ enabled: false });
      safeSetState(setError, CAMERA_BLOCKED_ERROR);
      return;
    }

    let stream: MediaStream | null = null;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
      labelsUnlockedRef.current = true;
    } catch (err) {
      // Denial is a state, never a throw.
      if (isPermissionDenial(err)) {
        setEnabledState(false);
        persist({ enabled: false });
      }
      safeSetState(setError, describeMediaError(err));
      return;
    } finally {
      stopStream(stream);
    }
    await enumerate();
  }, [enumerate, persist, safeSetState]);

  const refreshDevices = useCallback(async () => {
    if (!detectSupport()) {
      return;
    }
    await enumerate();
    if (!labelsUnlockedRef.current) {
      await unlockLabels();
    }
  }, [enumerate, unlockLabels]);

  // Initial enumeration plus a live device list. enumerateDevices() alone never
  // prompts, so this is safe to run unattended on mount.
  useEffect(() => {
    if (!supported) {
      return;
    }
    void enumerate();

    const onDeviceChange = () => {
      void enumerate();
    };
    navigator.mediaDevices.addEventListener("devicechange", onDeviceChange);
    return () => {
      navigator.mediaDevices.removeEventListener("devicechange", onDeviceChange);
    };
  }, [supported, enumerate]);

  const detachPreview = useCallback(() => {
    syncPreviewElement(previewRef.current, null);
  }, []);

  /**
   * Callback ref for the preview element. The hook outlives the Record tab
   * (it is owned by FieldCameraProvider), so the tab can mount mid-capture;
   * attaching here adopts the already-running stream instead of resetting.
   */
  const attachPreview = useCallback((el: HTMLVideoElement | null) => {
    previewRef.current = el;
    syncPreviewElement(el, sessionRef.current?.stream ?? null);
  }, []);

  const teardownSession = useCallback(async (session: CaptureSession) => {
    if (session.torn) {
      return;
    }
    session.torn = true;
    const { recorder } = session;

    if (recorder && recorder.state !== "inactive") {
      await new Promise<void>((resolve) => {
        let settled = false;
        const finish = () => {
          if (!settled) {
            settled = true;
            window.clearTimeout(timer);
            resolve();
          }
        };
        // Never let a wedged recorder keep the camera LED on.
        const timer = window.setTimeout(finish, STOP_FLUSH_TIMEOUT_MS);
        recorder.addEventListener("stop", finish, { once: true });
        recorder.addEventListener("error", finish, { once: true });
        try {
          recorder.stop();
        } catch {
          finish();
        }
      });
    }

    // Tracks are released before we await anything else that can reject.
    stopStream(session.stream);
    detachPreview();

    try {
      await session.chain;
    } catch {
      // Chunk failures already surfaced through onError.
    }

    if (session.opened) {
      session.opened = false;
      try {
        await getRecorderBridge()?.endVideo();
      } catch (err) {
        safeSetState(setError, err instanceof Error ? err.message : "Failed to finalize video.");
      }
    }
  }, [detachPreview, safeSetState]);

  const stopCapture = useCallback(async () => {
    const session = sessionRef.current;
    sessionRef.current = null;
    if (!session) {
      return;
    }
    safeSetState(setActive, false);
    await teardownSession(session);
  }, [safeSetState, teardownSession]);

  const startCapture = useCallback(async () => {
    if (sessionRef.current || !detectSupport()) {
      return;
    }

    const bridge = getRecorderBridge();
    if (!bridge) {
      safeSetState(setError, "Recorder bridge unavailable; video not recorded.");
      return;
    }

    const mimeType = pickMimeType();
    if (!mimeType) {
      safeSetState(setError, "This build cannot record WebM video.");
      return;
    }

    const deviceId = selectedDeviceIdRef.current;
    const constraints: MediaStreamConstraints = {
      audio: false,
      video: deviceId
        ? {
            deviceId: { exact: deviceId },
            width: { ideal: 1280 },
            height: { ideal: 720 },
            frameRate: { ideal: 30 },
          }
        : { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } },
    };

    if (isAccessBlocked(await ensureCameraAccess())) {
      setEnabledState(false);
      persist({ enabled: false });
      safeSetState(setError, CAMERA_BLOCKED_ERROR);
      return;
    }

    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia(constraints);
      labelsUnlockedRef.current = true;
    } catch (err) {
      // Unplugged device or denied permission: a state, not an exception.
      if (isPermissionDenial(err)) {
        setEnabledState(false);
        persist({ enabled: false });
      }
      safeSetState(setError, describeMediaError(err));
      void enumerate();
      return;
    }

    // A toggle or unmount that landed while getUserMedia was in flight wins.
    if (!mountedRef.current) {
      stopStream(stream);
      return;
    }

    const session: CaptureSession = {
      stream,
      recorder: null,
      chain: Promise.resolve(),
      opened: false,
      torn: false,
    };
    sessionRef.current = session;

    const videoTrack = stream.getVideoTracks()[0] ?? null;
    const deviceLabel = videoTrack?.label || "Field camera";

    let recorder: MediaRecorder;
    try {
      recorder = new window.MediaRecorder(stream, { mimeType });
    } catch (err) {
      sessionRef.current = null;
      stopStream(stream);
      safeSetState(setError, describeMediaError(err));
      return;
    }
    session.recorder = recorder;

    const failSession = (message: string) => {
      safeSetState(setError, message);
      if (sessionRef.current === session) {
        void stopCapture();
      }
    };

    recorder.ondataavailable = (event: BlobEvent) => {
      const blob = event.data;
      if (!blob || blob.size === 0) {
        return;
      }
      session.chain = session.chain.then(async () => {
        if (!session.opened) {
          return;
        }
        const buffer = await blob.arrayBuffer();
        await bridge.appendVideoChunk(new Uint8Array(buffer));
      }).catch((err: unknown) => {
        failSession(err instanceof Error ? err.message : "Video chunk write failed.");
      });
    };

    recorder.onerror = () => {
      failSession("Camera recording failed.");
    };

    // Camera yanked mid-match: degrade to an error and release everything.
    if (videoTrack) {
      videoTrack.addEventListener("ended", () => {
        if (sessionRef.current === session) {
          failSession("Camera disconnected during recording.");
        }
      });
    }

    syncPreviewElement(previewRef.current, stream);

    try {
      await bridge.beginVideo({ deviceLabel, mimeType });
      session.opened = true;
    } catch (err) {
      sessionRef.current = null;
      stopStream(stream);
      detachPreview();
      safeSetState(setError, err instanceof Error ? err.message : "Failed to open video file.");
      return;
    }

    if (!mountedRef.current || sessionRef.current !== session) {
      await teardownSession(session);
      return;
    }

    try {
      recorder.start(CHUNK_TIMESLICE_MS);
    } catch (err) {
      sessionRef.current = null;
      await teardownSession(session);
      safeSetState(setError, describeMediaError(err));
      return;
    }

    safeSetState(setError, null);
    safeSetState(setActive, true);
  }, [detachPreview, enumerate, persist, safeSetState, stopCapture, teardownSession]);

  const queueCapture = useCallback((task: () => Promise<void>) => {
    captureQueueRef.current = captureQueueRef.current.then(task, task);
    return captureQueueRef.current;
  }, []);

  // The single driver of capture: recording state plus user intent.
  useEffect(() => {
    if (!supported) {
      return;
    }
    if (isRecording && enabled) {
      void queueCapture(startCapture);
    } else {
      void queueCapture(stopCapture);
    }
  }, [supported, isRecording, enabled, queueCapture, startCapture, stopCapture]);

  // Unmount: release tracks synchronously, then let the queue finalize the file.
  useEffect(() => {
    return () => {
      const session = sessionRef.current;
      if (session) {
        stopStream(session.stream);
      }
      void queueCapture(stopCapture);
    };
  }, [queueCapture, stopCapture]);

  const setEnabled = useCallback((value: boolean) => {
    setEnabledState(value);
    persist({ enabled: value });
    if (value) {
      void unlockLabels();
    }
  }, [persist, unlockLabels]);

  const openCameraSettings = useCallback(() => {
    void getMediaBridge()?.openCameraSettings().catch(() => {});
  }, []);

  const selectDevice = useCallback((deviceId: string) => {
    selectedDeviceIdRef.current = deviceId;
    setSelectedDeviceId(deviceId);
    persist({ selectedDeviceId: deviceId });
    setError((current) => (current === DEVICE_MISSING_ERROR ? null : current));
  }, [persist]);

  return {
    supported,
    devices,
    selectedDeviceId,
    enabled,
    active,
    error,
    previewRef,
    setEnabled,
    selectDevice,
    refreshDevices,
    attachPreview,
    openCameraSettings,
  };
}
