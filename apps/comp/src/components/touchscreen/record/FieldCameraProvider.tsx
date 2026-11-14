"use client";

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { getRecorderBridge } from "./types";
import {
  useFieldCamera,
  type FieldCameraControls,
  type FieldCameraState,
} from "./useFieldCamera";

export type FieldCameraContextValue = FieldCameraState & FieldCameraControls;

const FieldCameraContext = createContext<FieldCameraContextValue | null>(null);

/**
 * Lifetime owner of field-camera capture.
 *
 * Mounted once around the entire touchscreen dashboard (see TouchscreenDashboard)
 * so that switching apps never unmounts an in-flight capture — the Record tab is
 * only a viewer that attaches the preview element and toggles settings. Capture
 * follows the recorder's real state via its own status subscription, so video
 * keeps riding alongside the log even when no Record UI is on screen.
 */
export function FieldCameraProvider({ children }: { children: ReactNode }) {
  const [isRecording, setIsRecording] = useState(false);

  useEffect(() => {
    const bridge = getRecorderBridge();
    if (!bridge) return;

    let disposed = false;
    const apply = (status: { isRecording: boolean }) => {
      if (!disposed) setIsRecording(status.isRecording);
    };
    const callbackId = bridge.subscribeStatus(apply);
    void bridge.getStatus().then(apply).catch(() => {});

    return () => {
      disposed = true;
      bridge.unsubscribeStatus(callbackId);
    };
  }, []);

  const camera = useFieldCamera({ isRecording });

  return <FieldCameraContext.Provider value={camera}>{children}</FieldCameraContext.Provider>;
}

/** Camera state + controls owned by the dashboard-lifetime provider. */
export function useFieldCameraContext(): FieldCameraContextValue {
  const value = useContext(FieldCameraContext);
  if (!value) {
    throw new Error(
      "useFieldCameraContext must be used inside <FieldCameraProvider> (mounted by TouchscreenDashboard).",
    );
  }
  return value;
}
