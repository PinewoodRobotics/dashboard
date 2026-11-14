"use client";

import { TouchscreenDashboard } from "@/components/touchscreen/TouchscreenDashboard";
import { FieldCameraProvider } from "@/components/touchscreen/record/FieldCameraProvider";

export default function TouchscreenPage() {
  // The field camera is owned at window level, not by the Record app. Switching apps
  // unmounts the tab, and capture must survive that — the whole point is to arm a
  // recording and leave it running while the drive team uses the rest of the dashboard.
  return (
    <FieldCameraProvider>
      <TouchscreenDashboard />
    </FieldCameraProvider>
  );
}
