#!/usr/bin/env node
/**
 * Regression checks for the Record app UI (Modules D & E).
 *
 * Run: node src/components/touchscreen/record/__checks__/record-ui.check.mjs
 * (from apps/comp; requires Node >= 23.6 for native TypeScript type stripping)
 *
 * Behavioral cases run against logic.ts; structural cases guard wiring that
 * previously shipped broken:
 *   DEFECT 1: RecordTab owned useFieldCamera, so switching apps unmounted the
 *             hook, stopped capture, and endVideo + re-beginVideo truncated
 *             the session video. Capture must live in FieldCameraProvider.
 *   DEFECT 2: refreshSessions only ran from the STOP action, so auto-stopped
 *             sessions never appeared in the browser until remount.
 *   DEFECT 3: RecorderBridge.stop() was typed Promise<SessionSummary>, but the
 *             engine returns null on a double-tap or an in-flight auto-stop.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  pickEndedSession,
  recordingJustEnded,
  syncPreviewElement,
} from "../logic.ts";

const here = dirname(fileURLToPath(import.meta.url));
const recordDir = join(here, "..");
const tabsDir = join(recordDir, "..", "tabs");
const read = (path) => readFileSync(path, "utf8");

let passed = 0;
let failed = 0;
function check(name, ok) {
  if (ok) {
    passed += 1;
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${name}`);
  }
}

console.log("recordingJustEnded (DEFECT 2: any end must trigger a session refresh)");
check("recording -> idle is an end", recordingJustEnded(true, false) === true);
check("idle -> idle is not", recordingJustEnded(false, false) === false);
check("first status while idle is not", recordingJustEnded(null, false) === false);
check("first status mid-recording is not", recordingJustEnded(null, true) === false);
check("still recording is not", recordingJustEnded(true, true) === false);
check("idle -> recording is not", recordingJustEnded(false, true) === false);

console.log("pickEndedSession (saved-take banner targets the right session)");
const sessions = [{ id: "2026-08-05_15-00-00" }, { id: "2026-08-05_14-00-00" }];
check("finds the ended session by id", pickEndedSession(sessions, "2026-08-05_14-00-00")?.id === "2026-08-05_14-00-00");
check("falls back to newest for unknown id", pickEndedSession(sessions, "nope")?.id === "2026-08-05_15-00-00");
check("falls back to newest for null id", pickEndedSession(sessions, null)?.id === "2026-08-05_15-00-00");
check("empty list yields null", pickEndedSession([], "x") === null);

console.log("syncPreviewElement (DEFECT 1: preview must attach to a stream that started before the tab mounted)");
const stream = { fake: "MediaStream" };
let plays = 0;
const el = { srcObject: null, muted: false, play: () => { plays += 1; return Promise.resolve(); } };
syncPreviewElement(el, stream);
check("mid-capture mount adopts the live stream", el.srcObject === stream);
check("element is muted", el.muted === true);
check("playback started", plays === 1);
syncPreviewElement(el, stream);
check("re-sync with the same stream is a no-op", plays === 1 && el.srcObject === stream);
syncPreviewElement(el, null);
check("detach clears srcObject", el.srcObject === null);
check("null element does not throw", (() => {
  try { syncPreviewElement(null, stream); return true; } catch { return false; }
})());
const rejecting = { srcObject: null, muted: false, play: () => Promise.reject(new Error("autoplay")) };
syncPreviewElement(rejecting, stream); // an unhandled rejection would fail the process at exit
check("rejecting play() still attaches the stream", rejecting.srcObject === stream);
const throwing = { srcObject: null, muted: false, play: () => { throw new Error("detached"); } };
check("throwing play() is swallowed", (() => {
  try { syncPreviewElement(throwing, stream); return throwing.srcObject === stream; } catch { return false; }
})());

console.log("structural wiring");
const recordTab = read(join(tabsDir, "RecordTab.tsx"));
check("DEFECT 1: RecordTab does not call useFieldCamera(", !recordTab.includes("useFieldCamera("));
check("DEFECT 1: RecordTab consumes useFieldCameraContext()", recordTab.includes("useFieldCameraContext()"));
check("DEFECT 1: RecordTab does not mount the provider itself (it would unmount with the tab)", !/import\s*{[^}]*\bFieldCameraProvider\b[^}]*}/.test(recordTab));
check("DEFECT 1: preview uses the mid-capture-safe attachPreview ref", recordTab.includes("ref={camera.attachPreview}"));

const provider = read(join(recordDir, "FieldCameraProvider.tsx"));
check("DEFECT 1: provider owns useFieldCamera", provider.includes("useFieldCamera({ isRecording })"));
check("DEFECT 1: provider exported for the dashboard", /export function FieldCameraProvider\(/.test(provider));
check("DEFECT 1: context hook exported", /export function useFieldCameraContext\(/.test(provider));
check("DEFECT 1: provider tracks recording via its own status subscription", provider.includes("subscribeStatus"));

const useRecorderSrc = read(join(recordDir, "useRecorder.ts"));
check("DEFECT 2: useRecorder refreshes on status-driven ends", useRecorderSrc.includes("recordingJustEnded("));
check("DEFECT 2: end handler refreshes the session list", useRecorderSrc.includes("onRecordingEnded"));

const typesSrc = read(join(recordDir, "types.ts"));
check("DEFECT 3: bridge stop() typed nullable", /stop:\s*\(\)\s*=>\s*Promise<SessionSummary \| null>/.test(typesSrc));
check("DEFECT 3: useRecorder handles a null stop()", /const summary = await bridge\.stop\(\);/.test(useRecorderSrc) && /if \(summary\)/.test(useRecorderSrc));

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
