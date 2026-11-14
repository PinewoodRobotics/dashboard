import { RIGHT_PANELS } from "../../model";
import type { RightPanelId } from "../../model";
import { RightIconColumn } from "./RightIconColumn";
import { MapSettingsPanel } from "../panels/MapSettingsPanel";
import { IntakeSpeedPanel } from "../panels/IntakeSpeedPanel";

export function RightSideContent({
  openPanel,
  displayPanel,
  onToggle,
}: {
  openPanel: RightPanelId | null;
  displayPanel: RightPanelId | null;
  onToggle: (id: RightPanelId) => void;
}) {
  const definition = displayPanel ? RIGHT_PANELS.find((panel) => panel.id === displayPanel) : null;

  return (
    <div className="flex gap-[30px] items-start overflow-clip p-[20px] h-full w-[540px]">
      <RightIconColumn openPanel={openPanel} onToggle={onToggle} />
      {displayPanel === "showMap" ? (
        <MapSettingsPanel />
      ) : displayPanel === "intakeSpeed" ? (
        <IntakeSpeedPanel />
      ) : (
        <div className="flex flex-col h-full items-start p-[10px] shrink-0 w-[426px]">
          {definition && (
            <>
              <p className="font-['Inter',sans-serif] font-medium text-[36px] text-white leading-[normal]">
                {definition.label} Settings
              </p>
              <p className="mt-4 text-sm text-zinc-400">Controls coming soon.</p>
            </>
          )}
        </div>
      )}
    </div>
  );
}
