/**
 * Pure decision helpers for the Record app, kept free of React and DOM types
 * so `__checks__/record-ui.check.mjs` can exercise them directly under Node.
 */

/**
 * True exactly when a status transition means "a recording just finished" —
 * regardless of what ended it (STOP button, auto-stop, disk error). The status
 * stream is the only signal that covers ends the operator never initiated.
 */
export function recordingJustEnded(
  prevIsRecording: boolean | null,
  nextIsRecording: boolean,
): boolean {
  return prevIsRecording === true && !nextIsRecording;
}

/**
 * Locate the session a just-finished recording produced in a newest-first
 * list: by the ended session's id when known, else the newest entry.
 */
export function pickEndedSession<T extends { id: string }>(
  sessions: readonly T[],
  endedSessionId: string | null,
): T | null {
  if (endedSessionId) {
    const match = sessions.find((session) => session.id === endedSessionId);
    if (match) return match;
  }
  return sessions[0] ?? null;
}

/** Structural subset of HTMLVideoElement, so this stays testable without a DOM. */
export interface PreviewElementLike {
  srcObject: unknown;
  muted: boolean;
  play?: () => unknown;
}

/**
 * Point a preview element at the live capture stream, or clear it. Idempotent,
 * and safe when the element mounts after capture has already started — the
 * Record tab can unmount and remount freely around a persistent capture.
 */
export function syncPreviewElement(
  el: PreviewElementLike | null,
  stream: object | null,
): void {
  if (!el) return;

  if (!stream) {
    if (el.srcObject !== null) {
      try {
        el.srcObject = null;
      } catch {
        // Element may already be detached during unmount.
      }
    }
    return;
  }

  if (el.srcObject === stream) return;

  el.srcObject = stream;
  el.muted = true;
  try {
    const played = el.play?.();
    if (
      played &&
      typeof (played as Promise<void>).catch === "function"
    ) {
      void (played as Promise<void>).catch(() => {
        // Autoplay rejection only costs the preview, not the recording.
      });
    }
  } catch {
    // Same: preview is best-effort.
  }
}
