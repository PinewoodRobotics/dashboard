"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { pickEndedSession, recordingJustEnded } from "./logic";
import {
  getRecorderBridge,
  type RecorderBridge,
  type RecorderStatus,
  type SessionSummary,
} from "./types";

export interface UseRecorderResult {
  /** False until the Electron bridge (with the recorder API) is confirmed present. */
  bridgeReady: boolean;
  status: RecorderStatus | null;
  sessions: SessionSummary[];
  /** True while a start/stop request is in flight — debounces the big button. */
  busy: boolean;
  /** Last error thrown by a UI-initiated action (start/stop/delete/...). */
  actionError: string | null;
  /**
   * The session most recently finished — by the STOP button, an auto-stop, or a
   * disk error — so the UI can say "this take saved, here" even when the
   * operator never touched anything. Cleared when a new recording starts.
   */
  lastEndedSession: SessionSummary | null;
  start: () => Promise<void>;
  stop: () => Promise<void>;
  setAutoRecord: (enabled: boolean) => Promise<void>;
  changeRecordingsDir: () => Promise<void>;
  deleteSession: (id: string) => Promise<void>;
  revealSession: (id: string) => Promise<void>;
  refreshSessions: () => Promise<SessionSummary[] | null>;
}

/** Subscribes to recorder status over the Electron bridge and exposes actions. */
export function useRecorder(): UseRecorderResult {
  const bridgeRef = useRef<RecorderBridge | null>(null);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [status, setStatus] = useState<RecorderStatus | null>(null);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [lastEndedSession, setLastEndedSession] = useState<SessionSummary | null>(null);
  const lastStatusRef = useRef<RecorderStatus | null>(null);

  const refreshSessions = useCallback(async (): Promise<SessionSummary[] | null> => {
    const bridge = bridgeRef.current;
    if (!bridge) return null;
    try {
      const list = await bridge.listSessions();
      setSessions(list);
      return list;
    } catch {
      // Directory may be mid-change; keep the previous list.
      return null;
    }
  }, []);

  /** A recording ended (any cause): refresh the list and surface the saved take. */
  const onRecordingEnded = useCallback(
    async (endedSessionId: string | null) => {
      const list = await refreshSessions();
      if (list) {
        setLastEndedSession(pickEndedSession(list, endedSessionId));
      }
    },
    [refreshSessions],
  );

  useEffect(() => {
    const bridge = getRecorderBridge();
    bridgeRef.current = bridge;
    if (!bridge) return;
    setBridgeReady(true);

    let disposed = false;
    const applyStatus = (s: RecorderStatus) => {
      if (disposed) return;
      const prev = lastStatusRef.current;
      lastStatusRef.current = s;
      setStatus(s);
      if (s.isRecording) {
        setLastEndedSession(null);
      } else if (recordingJustEnded(prev?.isRecording ?? null, s.isRecording)) {
        // Sessions can end without any UI action (auto-stop after disable, disk
        // error). The status stream is the only signal that covers them all.
        void onRecordingEnded(prev?.sessionId ?? null);
      }
    };

    const callbackId = bridge.subscribeStatus(applyStatus);
    void bridge.getStatus().then(applyStatus).catch(() => {});
    void refreshSessions();

    return () => {
      disposed = true;
      bridge.unsubscribeStatus(callbackId);
    };
  }, [refreshSessions, onRecordingEnded]);

  const runAction = useCallback(
    async (action: (bridge: RecorderBridge) => Promise<void>, gate: boolean) => {
      const bridge = bridgeRef.current;
      if (!bridge || (gate && busy)) return;
      if (gate) setBusy(true);
      try {
        await action(bridge);
        setActionError(null);
      } catch (error) {
        setActionError(error instanceof Error ? error.message : String(error));
      } finally {
        if (gate) setBusy(false);
      }
    },
    [busy],
  );

  const start = useCallback(
    () =>
      runAction(async (bridge) => {
        setLastEndedSession(null);
        await bridge.start();
      }, true),
    [runAction],
  );

  const stop = useCallback(
    () =>
      runAction(async (bridge) => {
        // Null when there was nothing to stop (double-tap, or an auto-stop won
        // the race) — the status subscription already handled that end.
        const summary = await bridge.stop();
        if (summary) setLastEndedSession(summary);
        await refreshSessions();
      }, true),
    [runAction, refreshSessions],
  );

  const setAutoRecord = useCallback(
    (enabled: boolean) =>
      runAction(async (bridge) => {
        setStatus(await bridge.setAutoRecord(enabled));
      }, false),
    [runAction],
  );

  const changeRecordingsDir = useCallback(
    () =>
      runAction(async (bridge) => {
        const dir = await bridge.chooseRecordingsDir();
        if (dir === null) return; // dialog cancelled
        setStatus(await bridge.setRecordingsDir(dir));
        await refreshSessions();
      }, false),
    [runAction, refreshSessions],
  );

  const deleteSession = useCallback(
    (id: string) =>
      runAction(async (bridge) => {
        await bridge.deleteSession(id);
        setLastEndedSession((current) => (current?.id === id ? null : current));
        await refreshSessions();
      }, false),
    [runAction, refreshSessions],
  );

  const revealSession = useCallback(
    (id: string) => runAction((bridge) => bridge.revealSession(id), false),
    [runAction],
  );

  return {
    bridgeReady,
    status,
    sessions,
    busy,
    actionError,
    lastEndedSession,
    start,
    stop,
    setAutoRecord,
    changeRecordingsDir,
    deleteSession,
    revealSession,
    refreshSessions,
  };
}
