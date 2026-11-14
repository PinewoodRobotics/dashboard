"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { NetworkTablesTypeInfos } from "ntcore-ts-client";
import { ntSelectedPathTopics, useSettings } from "@/lib/settings";
import { getBridge, hasBridge, subscribeNtTopic } from "@/lib/blitzRenderer";

const INTAKE_SPEED_TOPIC = "Intake/Speed";
const INTAKE_SPEED_KEY = "pwrup-intake-speed";

/** Sentinel the robot treats as "no override, use the compiled constant". */
const USE_ROBOT_DEFAULT = -1;

export interface IntakeSpeedNetworkTableState {
  isConnected: boolean;
  /** Speed the dashboard has requested, or null when the robot constant is in effect. */
  requestedSpeed: number | null;
  /** Speed the robot reports it is actually using, or null when disconnected. */
  robotSpeed: number | null;
  setIntakeSpeed: (speed: number) => void;
  resetIntakeSpeed: () => void;
  publishError: string | null;
}

function roundToHundredths(v: number): number {
  return Math.round(Math.max(0, Math.min(1, v)) * 100) / 100;
}

function loadRequestedSpeed(): number | null {
  try {
    const raw = typeof window !== "undefined" ? localStorage.getItem(INTAKE_SPEED_KEY) : null;
    if (raw === null) return null;
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? roundToHundredths(parsed) : null;
  } catch {
    return null;
  }
}

function saveRequestedSpeed(speed: number | null) {
  try {
    if (speed === null) localStorage.removeItem(INTAKE_SPEED_KEY);
    else localStorage.setItem(INTAKE_SPEED_KEY, String(speed));
  } catch {
    // Storage unavailable — ignore
  }
}

export function useIntakeSpeedNetworkTable(): IntakeSpeedNetworkTableState {
  const { settings } = useSettings();
  const [isConnected, setIsConnected] = useState(false);
  const [requestedSpeed, setRequestedSpeedState] = useState<number | null>(null);
  const [robotSpeed, setRobotSpeed] = useState<number | null>(null);
  const [publishError, setPublishError] = useState<string | null>(null);
  const queuedRequestRef = useRef<number | null>(null);

  useEffect(() => {
    const stored = loadRequestedSpeed();
    setRequestedSpeedState(stored);
    if (stored !== null) queuedRequestRef.current = stored;
  }, []);

  const robotIp = useMemo(() => settings.networkTables.host.trim(), [settings.networkTables.host]);

  const { requestTopic: requestTopicPath, stateTopic: stateTopicPath } = useMemo(
    () => ntSelectedPathTopics(settings.networkTables.sharedTable, INTAKE_SPEED_TOPIC),
    [settings.networkTables.sharedTable],
  );

  const flushQueuedRequest = useCallback(async () => {
    if (queuedRequestRef.current === null || !hasBridge() || !isConnected) return;

    const nextValue = queuedRequestRef.current;
    await getBridge().nt.publish({
      topicPath: requestTopicPath,
      typeInfo: NetworkTablesTypeInfos.kDouble,
      defaultValue: USE_ROBOT_DEFAULT,
      value: nextValue,
    });
    setPublishError(null);

    if (queuedRequestRef.current === nextValue) {
      queuedRequestRef.current = null;
    }
  }, [isConnected, requestTopicPath]);

  useEffect(() => {
    if (!robotIp || !hasBridge()) {
      setIsConnected(false);
      setRobotSpeed(null);
      return;
    }

    let disposed = false;
    let unsubscribe = () => {};

    void subscribeNtTopic<number>(
      {
        topicPath: stateTopicPath,
        typeInfo: NetworkTablesTypeInfos.kDouble,
        defaultValue: USE_ROBOT_DEFAULT,
      },
      (update) => {
        if (disposed) return;
        setIsConnected(update.isConnected);
        if (!update.isConnected || !update.hasValue || !Number.isFinite(update.value)) {
          setRobotSpeed(null);
          return;
        }
        setRobotSpeed(update.value);
      },
    ).then((cleanup) => {
      if (disposed) {
        cleanup();
        return;
      }
      unsubscribe = cleanup;
    });

    return () => {
      disposed = true;
      unsubscribe();
    };
  }, [robotIp, stateTopicPath]);

  const queueAndFlush = useCallback(
    (value: number) => {
      queuedRequestRef.current = value;
      void flushQueuedRequest().catch((error) => {
        setPublishError(error instanceof Error ? error.message : String(error));
      });
    },
    [flushQueuedRequest],
  );

  const setIntakeSpeed = useCallback(
    (speed: number) => {
      const rounded = roundToHundredths(speed);
      setRequestedSpeedState(rounded);
      saveRequestedSpeed(rounded);
      queueAndFlush(rounded);
    },
    [queueAndFlush],
  );

  const resetIntakeSpeed = useCallback(() => {
    setRequestedSpeedState(null);
    saveRequestedSpeed(null);
    queueAndFlush(USE_ROBOT_DEFAULT);
  }, [queueAndFlush]);

  // Re-send the stored override whenever the robot (re)connects so a reboot
  // does not silently fall back to the compiled constant.
  useEffect(() => {
    if (!isConnected) return;
    if (queuedRequestRef.current === null && requestedSpeed !== null) {
      queuedRequestRef.current = requestedSpeed;
    }
    void flushQueuedRequest().catch((error) => {
      setPublishError(error instanceof Error ? error.message : String(error));
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flushQueuedRequest, isConnected]);

  return { isConnected, requestedSpeed, robotSpeed, setIntakeSpeed, resetIntakeSpeed, publishError };
}
