"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import {
  AIM_TRIM_LIMIT_DEG,
  useShooterTuningNetworkTable,
  type ShooterBooleans,
  type ShooterNumbers,
} from "@/lib/hooks/useShooterTuningNetworkTable";
import { CustomSlider } from "./CustomSlider";

const MISSING = "--";

function formatTrim(deg: number): string {
  const magnitude = Number(Math.abs(deg).toFixed(2));
  if (magnitude === 0) return "0°";
  return `${magnitude}° ${deg > 0 ? "L" : "R"}`;
}

function formatNumber(v: number | null, decimals: number, unit = ""): string {
  return v === null ? MISSING : `${v.toFixed(decimals)}${unit}`;
}

function formatBool(v: boolean | null, yes: string, no: string): string {
  return v === null ? MISSING : v ? yes : no;
}

function ShooterReadouts({ numbers, booleans }: { numbers: ShooterNumbers; booleans: ShooterBooleans }) {
  const turretCommandDeg =
    numbers.turretAngleRad === null ? null : (numbers.turretAngleRad * 180) / Math.PI;

  const rows: Array<[string, string]> = [
    ["Mode", formatBool(booleans.autoShooter, "Auto shooter", "Manual shooter")],
    ["Distance", formatNumber(numbers.distanceToTarget, 2, " m")],
    ["RPM target", formatNumber(numbers.requestedRpm, 0)],
    ["RPM actual", formatNumber(numbers.velocityRpm, 0)],
    ["Leader", formatNumber(numbers.leaderRpm, 0)],
    ["Follower", formatNumber(numbers.followerRpm, 0)],
    ["Spun up", formatBool(booleans.isSpunUp, "Yes", "No")],
    ["Shooting", formatBool(booleans.isShooting, "Yes", "No")],
    ["Turret", formatNumber(numbers.turretPositionDeg, 1, "°")],
    ["Turret cmd", formatNumber(turretCommandDeg, 1, "°")],
  ];

  return (
    <div className="grid grid-cols-2 gap-x-[16px] gap-y-[4px] text-sm">
      {rows.map(([label, value]) => (
        <div key={label} className="flex items-baseline justify-between gap-2 border-b border-white/10 py-[2px]">
          <span className="text-zinc-400">{label}</span>
          <span className="font-mono text-white tabular-nums">{value}</span>
        </div>
      ))}
    </div>
  );
}

export function AimTrimSection() {
  const {
    isConnected,
    requestedAimTrimDeg,
    robotAimTrimDeg,
    setAimTrim,
    resetAimTrim,
    publishError,
    numbers,
    booleans,
  } = useShooterTuningNetworkTable();

  const sliderValue = requestedAimTrimDeg ?? robotAimTrimDeg ?? 0;

  const status = !isConnected
    ? "Robot not connected"
    : requestedAimTrimDeg !== null
      ? "Waiting for the robot to confirm"
      : robotAimTrimDeg !== null
        ? "Robot confirmed this trim"
        : "No trim reported by the robot yet";

  return (
    <div className="flex flex-col gap-[16px] w-full border-t-2 border-white/20 pt-[20px]">
      <div className="flex flex-col gap-[4px]">
        <CustomSlider
          label="Aim Trim"
          value={sliderValue}
          onChange={setAimTrim}
          min={-AIM_TRIM_LIMIT_DEG}
          max={AIM_TRIM_LIMIT_DEG}
          step={0.25}
          reversed
          formatValue={formatTrim}
          valueLabel="{{v}}"
          disabled={!isConnected}
        />
        <div className="flex justify-between text-sm text-zinc-400">
          <span className="flex items-center gap-1">
            <ChevronLeft className="size-4" />
            Aim left
          </span>
          <span className="flex items-center gap-1">
            Aim right
            <ChevronRight className="size-4" />
          </span>
        </div>
      </div>

      <p className="text-sm text-zinc-400">{publishError ?? status}</p>

      <button
        type="button"
        onClick={resetAimTrim}
        disabled={!isConnected}
        className="block w-full h-12 border-2 border-white/20 bg-transparent px-6 text-xl font-semibold text-zinc-400 disabled:opacity-50"
      >
        Center (0°)
      </button>

      <ShooterReadouts numbers={numbers} booleans={booleans} />
    </div>
  );
}
