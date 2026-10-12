"use client";

import { useIntakeSpeedNetworkTable } from "@/lib/hooks/useIntakeSpeedNetworkTable";
import { AimTrimSection } from "./AimTrimSection";
import { CustomSlider } from "./CustomSlider";
import { colScroll } from "../../settings/constants";

const FALLBACK_SPEED = 0.15;

export function IntakeSpeedPanel() {
  const { isConnected, requestedSpeed, robotSpeed, setIntakeSpeed, resetIntakeSpeed, publishError } =
    useIntakeSpeedNetworkTable();

  const sliderValue = requestedSpeed ?? robotSpeed ?? FALLBACK_SPEED;

  const status = !isConnected
    ? "Robot not connected — value is sent when it reconnects"
    : requestedSpeed === null
      ? "Using the robot's compiled constant"
      : robotSpeed !== null && Math.abs(robotSpeed - requestedSpeed) < 0.005
        ? "Robot confirmed this speed"
        : "Waiting for the robot to confirm";

  return (
    <div className="flex flex-col h-full items-start p-[16px] shrink-0 w-[426px]">
      <p className="font-['Inter',sans-serif] font-medium text-[36px] text-white leading-[normal]">
        Intake Speed
      </p>

      <div className={`flex flex-col gap-[20px] mt-[16px] w-full flex-1 pr-[10px] ${colScroll}`}>
        <CustomSlider
          label="Speed"
          value={sliderValue}
          onChange={setIntakeSpeed}
          min={0}
          max={1}
          step={0.01}
          decimals={2}
          valueLabel="{{v}} — duty cycle sent to the intake motor"
        />

        <p className="text-sm text-zinc-400">{publishError ?? status}</p>

        <button
          type="button"
          onClick={resetIntakeSpeed}
          className="block w-full h-12 border-2 border-white/20 bg-transparent px-6 text-xl font-semibold text-zinc-400"
        >
          Reset
        </button>

        <AimTrimSection />
      </div>
    </div>
  );
}
