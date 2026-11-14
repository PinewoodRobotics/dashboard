"use client";

import { formatClock } from "./format";
import type { RecorderStatus } from "./types";

interface RecordControlsProps {
  status: RecorderStatus | null;
  busy: boolean;
  onStart: () => void;
  onStop: () => void;
}

/**
 * The one control that matters. Idle and recording are deliberately extreme
 * opposites — a solid green block vs. a solid pulsing red block with a large
 * mono timer — so the state reads instantly from across the driver station.
 */
export function RecordControls({ status, busy, onStart, onStop }: RecordControlsProps) {
  const isRecording = status?.isRecording ?? false;

  if (isRecording) {
    return (
      <button
        type="button"
        onClick={onStop}
        disabled={busy}
        className="flex h-[190px] w-full flex-col items-center justify-center gap-3 bg-[#e5484d] text-white transition-opacity active:opacity-70 disabled:opacity-50"
      >
        <span className="flex items-center gap-3">
          <span className="h-4 w-4 bg-white animate-hub-warning" aria-hidden />
          <span className="text-sm font-semibold tracking-[0.3em]">RECORDING</span>
        </span>
        <span className="font-['Roboto_Mono'] text-[60px] leading-none">
          {formatClock(status?.elapsedMs ?? 0)}
        </span>
        <span className="text-xs font-semibold tracking-[0.2em] text-white/70">
          TAP TO STOP
        </span>
      </button>
    );
  }

  return (
    <button
      type="button"
      onClick={onStart}
      disabled={busy}
      className="flex h-[190px] w-full flex-col items-center justify-center gap-3 bg-[#70cd35] text-black transition-opacity active:opacity-70 disabled:opacity-50"
    >
      <span className="h-4 w-4 border-4 border-black" aria-hidden />
      <span className="text-xl font-semibold tracking-wide">START RECORDING</span>
      <span className="text-xs font-semibold tracking-[0.2em] text-black/60">
        LOGS ALL NETWORKTABLES TRAFFIC
      </span>
    </button>
  );
}
