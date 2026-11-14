export type OverlayTabId =
  | "auto"
  | "settings"
  | "effects"
  | "howard"
  | "robot3d"
  | "visual"
  | "record";

export type RightPanelId = "showMap" | "intakeSpeed" | "showTimers" | "showStatus" | "showCamera";

export interface TabDef {
  id: OverlayTabId;
  label: string;
  symbol: string;
  activeSymbol: string;
}

export interface RightPanelDef {
  id: RightPanelId;
  label: string;
  symbol: string;
  activeSymbol: string;
}

export interface DockIcon {
  id: OverlayTabId;
  symbol: string;
  activeSymbol: string;
}
