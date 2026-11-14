"use client";

import { useEffect, useRef, useState } from "react";
import { formatBytes, formatDuration, formatSessionDate } from "./format";
import type { SessionSummary } from "./types";

interface SessionListProps {
  sessions: SessionSummary[];
  onReveal: (id: string) => void;
  onDelete: (id: string) => void;
}

const CONFIRM_RESET_MS = 4000;

/**
 * Newest-first session browser. Delete is a two-tap inline confirm — never
 * `window.confirm`, which blocks the Electron renderer.
 */
export function SessionList({ sessions, onReveal, onDelete }: SessionListProps) {
  const [confirmingId, setConfirmingId] = useState<string | null>(null);
  const confirmTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (confirmTimerRef.current) clearTimeout(confirmTimerRef.current);
    };
  }, []);

  function onDeleteTap(id: string) {
    if (confirmTimerRef.current) clearTimeout(confirmTimerRef.current);
    if (confirmingId === id) {
      setConfirmingId(null);
      onDelete(id);
      return;
    }
    setConfirmingId(id);
    confirmTimerRef.current = setTimeout(() => setConfirmingId(null), CONFIRM_RESET_MS);
  }

  if (sessions.length === 0) {
    return (
      <p className="text-sm leading-relaxed text-zinc-400">
        No recordings yet. Sessions capture every NetworkTables value to a .wpilog
        file that calibrates the PWRDrive simulator against real robot behavior.
      </p>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {sessions.map((session) => {
        const confirming = confirmingId === session.id;
        return (
          <div
            key={session.id}
            className="flex flex-col gap-3 border-2 border-white/10 p-4"
          >
            <div className="flex items-start justify-between gap-3">
              <div className="flex min-w-0 flex-col gap-1">
                <p className="truncate font-['Roboto_Mono'] text-base text-white">
                  {session.id}
                </p>
                <p className="text-sm text-zinc-400">
                  {formatSessionDate(session.startedAtIso)}
                  {" · "}
                  {formatDuration(session.durationMs)}
                  {" · "}
                  {formatBytes(session.logBytes)}
                  {" · "}
                  {session.topicCount} topics
                </p>
              </div>
              {session.videoPath ? (
                <span
                  className="sf-symbol shrink-0 text-[22px] text-zinc-400"
                  title="Has field video"
                >
                  􀌞
                </span>
              ) : null}
            </div>
            {session.hadConnectionLoss ? (
              <p className="text-xs font-semibold tracking-wide text-[#ffb224]">
                NT DROPPED DURING THIS SESSION
              </p>
            ) : null}
            <div className="flex gap-3">
              <button
                type="button"
                onClick={() => onReveal(session.id)}
                className="h-12 flex-1 border-2 border-white/20 bg-transparent px-4 text-sm font-semibold text-zinc-400 transition-colors hover:bg-white/5 active:bg-white/10"
              >
                Reveal
              </button>
              <button
                type="button"
                onClick={() => onDeleteTap(session.id)}
                className={[
                  "h-12 flex-1 border-2 px-4 text-sm font-semibold transition-colors",
                  confirming
                    ? "border-[#e5484d] bg-[#e5484d] text-white active:opacity-70"
                    : "border-[#e5484d]/50 bg-transparent text-[#e5484d] hover:bg-[#e5484d]/10 active:bg-[#e5484d]/20",
                ].join(" ")}
              >
                {confirming ? "Confirm" : "Delete"}
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
}
