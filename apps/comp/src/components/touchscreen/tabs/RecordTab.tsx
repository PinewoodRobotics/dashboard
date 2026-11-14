"use client";

import { SettingsColumn } from "../settings/components/SettingsColumn";
import { useFieldCameraContext } from "../record/FieldCameraProvider";
import { CAMERA_BLOCKED_ERROR } from "../record/useFieldCamera";
import { RecordControls } from "../record/RecordControls";
import { SessionList } from "../record/SessionList";
import { StatusReadout } from "../record/StatusReadout";
import { formatBytes, formatClock, formatDuration } from "../record/format";
import type { SessionSummary } from "../record/types";
import { useRecorder } from "../record/useRecorder";

function ToggleRow({
  label,
  on,
  disabled,
  onToggle,
}: {
  label: string;
  on: boolean;
  disabled?: boolean;
  onToggle: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onToggle}
      disabled={disabled}
      className={[
        "flex h-14 w-full items-center justify-between border-2 px-4 transition-colors disabled:opacity-40",
        on ? "border-[#70cd35]" : "border-white/20 active:bg-white/5",
      ].join(" ")}
    >
      <span className={["text-sm font-semibold", on ? "text-white" : "text-zinc-400"].join(" ")}>
        {label}
      </span>
      <span
        aria-hidden
        className={["h-6 w-6 border-2", on ? "border-[#70cd35] bg-[#70cd35]" : "border-white/30"].join(" ")}
      />
    </button>
  );
}

/**
 * The moment a recording ends — even one the operator never touched, like an
 * auto-stop after the robot disables — this says the take saved and where.
 */
function SavedBanner({
  session,
  onReveal,
}: {
  session: SessionSummary;
  onReveal: (id: string) => void;
}) {
  return (
    <div className="flex flex-col gap-3 border-2 border-[#70cd35] bg-[#70cd35]/10 p-4">
      <div className="flex items-center justify-between gap-3">
        <span className="text-sm font-semibold tracking-[0.25em] text-[#70cd35]">SAVED</span>
        <span className="font-['Roboto_Mono'] text-sm text-zinc-400">
          {session.autoStarted ? "AUTO · " : ""}
          {formatDuration(session.durationMs)}
          {" · "}
          {formatBytes(session.logBytes)}
          {session.videoPath ? " · video" : ""}
        </span>
      </div>
      <p
        className="truncate font-['Roboto_Mono'] text-sm text-white"
        style={{ direction: "rtl", textAlign: "left" }}
        title={session.logPath}
      >
        {session.logPath}
      </p>
      <button
        type="button"
        onClick={() => onReveal(session.id)}
        className="h-12 border-2 border-[#70cd35]/60 bg-transparent px-6 text-sm font-semibold text-[#70cd35] transition-colors hover:bg-[#70cd35]/10 active:bg-[#70cd35]/20"
      >
        Reveal in Folder
      </button>
    </div>
  );
}

export function RecordTab() {
  const recorder = useRecorder();
  const { status } = recorder;
  const isRecording = status?.isRecording ?? false;
  // Capture is owned by <FieldCameraProvider> at the dashboard root, so it
  // survives app switches; this tab only views and configures it.
  const camera = useFieldCameraContext();

  return (
    <div className="flex h-full flex-col bg-[#272727]">
      <div className="shrink-0 border-b-2 border-white/10 px-8 py-5 flex items-center justify-between gap-6">
        <h1 className="text-[28px] font-semibold text-white leading-none">Record</h1>
        <div className="flex items-center gap-3 shrink-0">
          {/* Recording state stays visible in the header no matter where the
              columns are scrolled. */}
          {isRecording ? (
            <div className="flex h-12 items-center gap-3 border-2 border-[#e5484d] bg-[#e5484d]/10 px-4">
              <span className="h-3 w-3 bg-[#e5484d] animate-hub-warning" aria-hidden />
              <span className="text-sm font-semibold tracking-[0.25em] text-[#e5484d]">REC</span>
              <span className="font-['Roboto_Mono'] text-lg leading-none text-white">
                {formatClock(status?.elapsedMs ?? 0)}
              </span>
            </div>
          ) : recorder.bridgeReady && status && !status.isConnected ? (
            <div className="flex h-12 items-center gap-3 border-2 border-[#e5484d] px-4 animate-nt-pulse">
              <span className="text-sm font-semibold tracking-[0.15em] text-[#e5484d]">
                NT OFFLINE
              </span>
            </div>
          ) : null}
        </div>
      </div>

      {!recorder.bridgeReady ? (
        <div className="flex flex-1 items-center justify-center px-8">
          <p className="max-w-[560px] text-center text-lg text-zinc-500">
            The recorder runs in the Electron dashboard. Launch the comp app through
            Electron to record NetworkTables logs.
          </p>
        </div>
      ) : (
        <div className="min-h-0 flex-1 flex overflow-x-auto [&::-webkit-scrollbar]:h-[5px] [&::-webkit-scrollbar-track]:bg-[#272727] [&::-webkit-scrollbar-thumb]:bg-[#70cd35] [&::-webkit-scrollbar-thumb]:rounded-none [&::-webkit-scrollbar-thumb]:cursor-pointer">
          <SettingsColumn title="Recording" bordered>
            <RecordControls
              status={status}
              busy={recorder.busy}
              onStart={() => void recorder.start()}
              onStop={() => void recorder.stop()}
            />
            {recorder.actionError ? (
              <p className="border-2 border-[#e5484d] bg-[#e5484d]/10 px-4 py-3 text-sm font-semibold text-[#e5484d]">
                {recorder.actionError}
              </p>
            ) : null}
            {!isRecording && recorder.lastEndedSession ? (
              <SavedBanner
                session={recorder.lastEndedSession}
                onReveal={(id) => void recorder.revealSession(id)}
              />
            ) : null}
            <StatusReadout status={status} />
          </SettingsColumn>

          <SettingsColumn title="Automation" bordered>
            <div className="flex flex-col gap-2">
              <ToggleRow
                label="Auto Record"
                on={status?.autoRecord ?? false}
                onToggle={() => void recorder.setAutoRecord(!(status?.autoRecord ?? false))}
              />
              <p className="text-sm text-zinc-400">
                Starts when the robot is enabled, stops 5 s after disable.
              </p>
            </div>
            <div className="flex h-14 items-center justify-between border-2 border-white/10 px-4">
              <span className="text-sm font-semibold tracking-[0.15em] text-zinc-500">ROBOT</span>
              {status?.robotEnabled ? (
                <span className="bg-[#70cd35] px-3 py-1.5 text-sm font-semibold text-black">
                  ENABLED
                </span>
              ) : (
                <span className="border-2 border-white/20 px-3 py-1 text-sm font-semibold text-zinc-400">
                  DISABLED
                </span>
              )}
            </div>
          </SettingsColumn>

          <SettingsColumn title="Field Camera" bordered>
            {camera.supported ? (
              <>
                <div className="flex flex-col gap-2">
                  <ToggleRow
                    label="Record Video"
                    on={camera.enabled}
                    disabled={isRecording}
                    onToggle={() => camera.setEnabled(!camera.enabled)}
                  />
                  <p className="text-sm text-zinc-400">
                    Saves a field webcam .webm alongside the log for each session.
                  </p>
                </div>
                <div className="flex flex-col gap-2">
                  <video
                    ref={camera.attachPreview}
                    muted
                    playsInline
                    className="aspect-video w-full border-2 border-white/10 bg-black object-cover"
                  />
                  {camera.active ? (
                    <div className="flex items-center gap-2">
                      <span className="h-3 w-3 bg-[#e5484d] animate-hub-warning" aria-hidden />
                      <span className="text-xs font-semibold tracking-[0.2em] text-[#e5484d]">
                        CAPTURING
                      </span>
                    </div>
                  ) : null}
                </div>
                {camera.error ? (
                  <div className="flex flex-col gap-2 border-2 border-[#e5484d] bg-[#e5484d]/10 px-4 py-3">
                    <p className="text-sm font-semibold text-[#e5484d]">{camera.error}</p>
                    {camera.error === CAMERA_BLOCKED_ERROR ? (
                      <button
                        type="button"
                        onClick={camera.openCameraSettings}
                        className="self-start border-2 border-[#e5484d] px-3 py-1 text-xs font-semibold uppercase tracking-[0.15em] text-[#e5484d]"
                      >
                        Open Privacy Settings
                      </button>
                    ) : null}
                  </div>
                ) : null}
                <div className="flex flex-col gap-2">
                  <p className="text-[11px] font-semibold uppercase tracking-[0.15em] text-zinc-500">
                    Camera
                  </p>
                  {camera.devices.length === 0 ? (
                    <p className="text-sm text-zinc-400">No cameras found.</p>
                  ) : (
                    camera.devices.map((device, index) => {
                      const selected = device.deviceId === camera.selectedDeviceId;
                      return (
                        <button
                          key={device.deviceId}
                          type="button"
                          disabled={isRecording}
                          onClick={() => camera.selectDevice(device.deviceId)}
                          className={[
                            "h-12 w-full truncate border-2 px-4 text-left text-sm font-semibold transition-colors disabled:opacity-40",
                            selected
                              ? "border-[#70cd35] text-[#70cd35]"
                              : "border-white/20 text-zinc-400 hover:bg-white/5 active:bg-white/10",
                          ].join(" ")}
                        >
                          {device.label || `Camera ${index + 1}`}
                        </button>
                      );
                    })
                  )}
                  <button
                    type="button"
                    onClick={() => void camera.refreshDevices()}
                    className="h-12 border-2 border-white/20 bg-transparent px-6 text-sm font-semibold text-zinc-400 transition-colors hover:bg-white/5 active:bg-white/10"
                  >
                    Rescan Cameras
                  </button>
                </div>
              </>
            ) : (
              <p className="text-sm text-zinc-400">
                Camera capture is not supported in this runtime.
              </p>
            )}
          </SettingsColumn>

          <SettingsColumn title="Storage" bordered>
            <div className="flex flex-col gap-2">
              <p className="text-sm text-zinc-400">New recordings are written to:</p>
              <p
                className="truncate border-2 border-white/10 px-4 py-3 font-['Roboto_Mono'] text-sm text-white"
                style={{ direction: "rtl", textAlign: "left" }}
                title={status?.recordingsDir ?? ""}
              >
                {status?.recordingsDir ?? "—"}
              </p>
              <button
                type="button"
                onClick={() => void recorder.changeRecordingsDir()}
                disabled={isRecording}
                className="h-12 border-2 border-white/20 bg-transparent px-6 text-sm font-semibold text-zinc-400 transition-colors hover:bg-white/5 active:bg-white/10 disabled:opacity-40"
              >
                Change…
              </button>
              {isRecording ? (
                <p className="text-sm text-zinc-400">Stop recording to change the folder.</p>
              ) : null}
            </div>
          </SettingsColumn>

          <SettingsColumn title="Sessions">
            <SessionList
              sessions={recorder.sessions}
              onReveal={(id) => void recorder.revealSession(id)}
              onDelete={(id) => void recorder.deleteSession(id)}
            />
          </SettingsColumn>
        </div>
      )}
    </div>
  );
}
