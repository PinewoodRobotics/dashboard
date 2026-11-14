"use client";

import { formatBytes, formatClock } from "./format";
import type { RecorderStatus } from "./types";

const AMBER = "#ffb224";

function Stat({ label, value, warn }: { label: string; value: string; warn?: boolean }) {
  return (
    <div className="flex flex-col gap-1">
      <p className="text-[11px] font-semibold uppercase tracking-[0.15em] text-zinc-500">
        {label}
      </p>
      <p
        className="font-['Roboto_Mono'] text-[26px] leading-none"
        style={{ color: warn ? AMBER : "white" }}
      >
        {value}
      </p>
    </div>
  );
}

function WarningRow({ tone, text }: { tone: "amber" | "red"; text: string }) {
  const color = tone === "red" ? "#e5484d" : AMBER;
  return (
    <div
      className="flex items-start gap-3 border-2 px-4 py-3"
      style={{ borderColor: color, backgroundColor: `${color}1a` }}
    >
      <span className="mt-[3px] h-3 w-3 shrink-0 animate-hub-warning" style={{ backgroundColor: color }} aria-hidden />
      <p className="text-sm font-semibold leading-snug" style={{ color }}>
        {text}
      </p>
    </div>
  );
}

/**
 * Answers "is this actually working?" with zero interpretation: a loud NT
 * connection pill, live counters while recording, and unmissable warning rows
 * for connection loss and write errors.
 */
export function StatusReadout({ status }: { status: RecorderStatus | null }) {
  const isRecording = status?.isRecording ?? false;
  const isConnected = status?.isConnected ?? false;
  const endpoint = status ? `${status.host}:${status.port}` : "—";

  // Recording but nothing arriving: the log is silently empty. Give it a
  // moment after start before shouting, then shout.
  const stalled =
    isRecording && isConnected && (status?.elapsedMs ?? 0) > 4000 && (status?.samplesPerSecond ?? 0) === 0;

  return (
    <div className="flex flex-col gap-5">
      {/* NT connection pill — always full brightness, recording or not. */}
      <div
        className={[
          "flex h-14 items-center justify-between border-2 px-4",
          isConnected ? "border-[#70cd35]" : "border-[#e5484d] animate-nt-pulse",
        ].join(" ")}
      >
        <span
          className={[
            "text-sm font-semibold tracking-[0.15em]",
            isConnected ? "text-[#70cd35]" : "text-[#e5484d]",
          ].join(" ")}
        >
          {isConnected ? "NT CONNECTED" : "NT OFFLINE"}
        </span>
        <span className="font-['Roboto_Mono'] text-sm text-zinc-400">{endpoint}</span>
      </div>

      {status?.lastError ? <WarningRow tone="red" text={`Recorder error: ${status.lastError}`} /> : null}
      {isRecording && status?.hadConnectionLoss ? (
        <WarningRow tone="amber" text="NT connection dropped during this session — the log has a gap." />
      ) : null}
      {stalled ? (
        <WarningRow tone="amber" text="Connected but no samples arriving — check that the robot is publishing." />
      ) : null}

      {/* Counters — dimmed when idle so they cannot be mistaken for live capture. */}
      <div
        className={[
          "grid grid-cols-2 gap-x-6 gap-y-5 transition-opacity",
          isRecording ? "opacity-100" : "opacity-40",
        ].join(" ")}
      >
        <Stat label="Elapsed" value={isRecording ? formatClock(status?.elapsedMs ?? 0) : "—"} />
        <Stat label="File Size" value={isRecording ? formatBytes(status?.bytesWritten ?? 0) : "—"} />
        <Stat
          label="Samples"
          value={isRecording ? (status?.sampleCount ?? 0).toLocaleString() : "—"}
        />
        <Stat
          label="Samples / s"
          value={isRecording ? String(Math.round(status?.samplesPerSecond ?? 0)) : "—"}
          warn={stalled}
        />
        <Stat label="Topics" value={String(status?.topicCount ?? 0)} />
        <Stat
          label="Video"
          value={
            status?.video?.active ? formatBytes(status.video.bytesWritten) : isRecording ? "Off" : "—"
          }
        />
      </div>
    </div>
  );
}
