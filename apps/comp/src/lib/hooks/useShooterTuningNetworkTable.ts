"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { NetworkTablesTypeInfos, type NetworkTablesTypeInfo } from "ntcore-ts-client";
import { useSettings } from "@/lib/settings";
import { getBridge, hasBridge, subscribeNtTopic } from "@/lib/blitzRenderer";

const AIM_TRIM_TOPIC = "/Tuning/Turret/AimTrimDeg";

// Read back through AdvantageKit's NetworkInputs log rather than subscribing to
// AIM_TRIM_TOPIC itself: the ntcore server never re-announces a topic this connection
// already subscribes to, so a later publish of it would never be acknowledged.
const AIM_TRIM_READBACK_TOPIC = "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg";

const OUTPUTS = "/AdvantageKit/RealOutputs";

const NUMBER_TOPICS = {
  distanceToTarget: `${OUTPUTS}/Turret/DistanceToTarget`,
  requestedRpm: `${OUTPUTS}/Shooter/RequestedVelocityRPM`,
  velocityRpm: `${OUTPUTS}/Shooter/VelocityRPM`,
  leaderRpm: `${OUTPUTS}/Shooter/LeaderVelocityRPM`,
  followerRpm: `${OUTPUTS}/Shooter/FollowerVelocityRPM`,
  turretPositionDeg: `${OUTPUTS}/Turret/PositionDeg`,
  turretAngleRad: `${OUTPUTS}/Turret/Angle`,
} as const;

const BOOLEAN_TOPICS = {
  isSpunUp: `${OUTPUTS}/Shooter/IsSpunUp`,
  autoShooter: `${OUTPUTS}/ShooterSubsystem/GPSAssistFeaturesEnabled`,
  isShooting: `${OUTPUTS}/MatchStatus/isShooting`,
} as const;

export const AIM_TRIM_LIMIT_DEG = 10;

export type ShooterNumbers = Record<keyof typeof NUMBER_TOPICS, number | null>;
export type ShooterBooleans = Record<keyof typeof BOOLEAN_TOPICS, boolean | null>;

export interface ShooterTuningState {
  isConnected: boolean;
  requestedAimTrimDeg: number | null;
  robotAimTrimDeg: number | null;
  setAimTrim: (deg: number) => void;
  resetAimTrim: () => void;
  publishError: string | null;
  numbers: ShooterNumbers;
  booleans: ShooterBooleans;
}

function clampTrim(deg: number): number {
  const clamped = Math.max(-AIM_TRIM_LIMIT_DEG, Math.min(AIM_TRIM_LIMIT_DEG, deg));
  return Math.round(clamped * 100) / 100;
}

function nullRecord<K extends string>(keys: readonly K[]): Record<K, null> {
  return Object.fromEntries(keys.map((key) => [key, null])) as Record<K, null>;
}

function useNtValues<K extends string, T extends number | boolean>(
  topics: Record<K, string>,
  typeInfo: NetworkTablesTypeInfo,
  defaultValue: T,
  enabled: boolean,
  onConnection?: (isConnected: boolean) => void,
): Record<K, T | null> {
  const [values, setValues] = useState<Record<K, T | null>>(() =>
    nullRecord(Object.keys(topics) as K[]),
  );
  const onConnectionRef = useRef(onConnection);
  onConnectionRef.current = onConnection;

  useEffect(() => {
    const keys = Object.keys(topics) as K[];
    setValues(nullRecord(keys));
    if (!enabled) {
      onConnectionRef.current?.(false);
      return;
    }

    let disposed = false;
    const cleanups: Array<() => void> = [];

    keys.forEach((key) => {
      void subscribeNtTopic<T>({ topicPath: topics[key], typeInfo, defaultValue }, (update) => {
        if (disposed) return;
        onConnectionRef.current?.(update.isConnected);
        const usable =
          update.isConnected &&
          update.hasValue &&
          (typeof update.value === "boolean" || Number.isFinite(update.value));
        const next = usable ? update.value : null;
        setValues((prev) => (prev[key] === next ? prev : { ...prev, [key]: next }));
      }).then((cleanup) => {
        if (disposed) cleanup();
        else cleanups.push(cleanup);
      });
    });

    return () => {
      disposed = true;
      cleanups.forEach((cleanup) => cleanup());
    };
  }, [topics, typeInfo, defaultValue, enabled]);

  return values;
}

const READBACK_TOPICS = { aimTrim: AIM_TRIM_READBACK_TOPIC } as const;

export function useShooterTuningNetworkTable(): ShooterTuningState {
  const { settings } = useSettings();
  const enabled = settings.networkTables.host.trim() !== "" && hasBridge();

  const [isConnected, setIsConnected] = useState(false);
  const [requestedAimTrimDeg, setRequestedAimTrimDeg] = useState<number | null>(null);
  const [publishError, setPublishError] = useState<string | null>(null);
  const lastSentRef = useRef<number | null>(null);

  const readback = useNtValues(READBACK_TOPICS, NetworkTablesTypeInfos.kDouble, 0, enabled, setIsConnected);
  const numbers = useNtValues(NUMBER_TOPICS, NetworkTablesTypeInfos.kDouble, 0, enabled);
  const booleans = useNtValues(BOOLEAN_TOPICS, NetworkTablesTypeInfos.kBoolean, false, enabled);
  const robotAimTrimDeg = readback.aimTrim;
  const robotAimTrimRef = useRef(robotAimTrimDeg);
  robotAimTrimRef.current = robotAimTrimDeg;

  useEffect(() => {
    if (!isConnected) {
      setRequestedAimTrimDeg(null);
      lastSentRef.current = null;
    }
  }, [isConnected]);

  useEffect(() => {
    if (
      requestedAimTrimDeg !== null &&
      robotAimTrimDeg !== null &&
      Math.abs(robotAimTrimDeg - requestedAimTrimDeg) < 0.005
    ) {
      setRequestedAimTrimDeg(null);
      lastSentRef.current = null;
    }
  }, [requestedAimTrimDeg, robotAimTrimDeg]);

  const setAimTrim = useCallback(
    (deg: number) => {
      if (!isConnected || !hasBridge()) return;
      const value = clampTrim(deg);
      setRequestedAimTrimDeg(value);
      const target = lastSentRef.current ?? robotAimTrimRef.current;
      if (target !== null && Math.abs(target - value) < 0.005) return;
      lastSentRef.current = value;

      void getBridge()
        .nt.publish({
          topicPath: AIM_TRIM_TOPIC,
          typeInfo: NetworkTablesTypeInfos.kDouble,
          defaultValue: 0,
          value,
        })
        .then(() => setPublishError(null))
        .catch((error) => {
          lastSentRef.current = null;
          setPublishError(error instanceof Error ? error.message : String(error));
        });
    },
    [isConnected],
  );

  const resetAimTrim = useCallback(() => setAimTrim(0), [setAimTrim]);

  return {
    isConnected,
    requestedAimTrimDeg,
    robotAimTrimDeg,
    setAimTrim,
    resetAimTrim,
    publishError,
    numbers,
    booleans,
  };
}
