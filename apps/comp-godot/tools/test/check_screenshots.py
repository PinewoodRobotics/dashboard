"""Assertions over the reports written by tools/test/run_screenshots.sh.

Usage: python3 check_screenshots.py OUT_DIR GODOT APP
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

OUT, GODOT, APP = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)


def report(name: str) -> dict:
    return json.loads((OUT / f"{name}.json").read_text())


def region_diff(a: str, b: str, window: str, anchor: str, half_px: int = 60) -> float:
    x, y = report(a)["anchors"][window][anchor]
    args = [str(OUT / f"{a}_{window}.png"), str(OUT / f"{b}_{window}.png"), str(int(x - half_px)), str(int(y - half_px)), str(2 * half_px), str(2 * half_px)]
    return rect_diff(args)


def rect_diff(args: list[str]) -> float:
    out = subprocess.run([GODOT, "--headless", "--script", str(APP / "tools/test/png_diff.gd"), "--", *args], capture_output=True, text=True).stdout
    line = next((l for l in out.splitlines() if l.startswith("diff ")), "diff nan")
    return float(line.split()[1])


for name in ["m2_overview_blue", "m2_overview_red", "m2_close", "m2_close_turret_q", "m2_close_wrist", "m2_perf", "live_blue", "live_red"]:
    r = report(name)
    check(not r["failures"], f"{name}: no probe failures {r['failures']}")
    check(set(r["windows"]) == {"hud", "touch"}, f"{name}: both windows captured")

for name in ["live_blue", "live_red"]:
    r = report(name)
    check(r["nt"]["state"] == "READY" and not r["nt"]["fixture_mode"], f"{name}: pose and alliance came from the fake robot over NT")
    check(abs(r["anchors"]["hud"]["robot"][0] - report("m2_overview_blue")["anchors"]["hud"]["robot"][0]) < 2, f"{name}: robot drawn where the fixture puts pose (2.0, 4.03)")

blue = report("m2_overview_blue")
hud_w = blue["windows"]["hud"]["size"][0]
hud_anchor = blue["anchors"]["hud"]
check(hud_anchor["robot"][0] > hud_w / 2, f"robot at (2.0, 4.03) drawn on the +X (blue) half of a top-down view: x {hud_anchor['robot'][0]:.0f} > {hud_w / 2:.0f}")
check(hud_anchor["IndexWristRControl"][0] < hud_anchor["robot"][0], "intake (front) points toward -X, the red side")

for joint, fx, anchor in [("turret", "m2_close_turret_q", "TurretRControl"), ("wrist", "m2_close_wrist", "IndexWristRControl")]:
    for window in ["hud", "touch"]:
        d = region_diff("m2_close", fx, window, anchor)
        check(d > 0.003, f"{joint} motion changes the {window} image around {anchor}: diff {d:.4f}")
control = rect_diff([str(OUT / "m2_close_hud.png"), str(OUT / "m2_close_turret_q_hud.png"), "380", "330", "120", "60"])
check(control < 1e-4, f"pixels away from the robot are identical across joint fixtures: diff {control:.6f}")

perf = report("m2_perf")
wins = perf["windows"]
check(len(perf["os_windows"]) == 2 and wins["hud"]["window_id"] != wins["touch"]["window_id"], f"--screen=both opens two OS windows {perf['os_windows']}")
check(not wins["hud"]["embedded"] and not wins["touch"]["embedded"], "neither window is embedded")
for name in ["m2_overview_blue", "m2_perf"]:
    check(report(name)["nt"] == {"state": "IDLE", "fixture_mode": True}, f"{name}: fixture run never opened a socket")
meshes = perf["robot_meshes"]
check(len(meshes["instances"]) == 2 and meshes["shared"], "both robot instances use identical mesh RIDs")
p = perf["perf"]
check(p["max_draw_calls"] <= 40, f"draw calls {p['max_draw_calls']} <= 40")
check(p["max_primitives"] <= 600_000, f"primitives {p['max_primitives']} <= 600k")
check(p["fps"] >= 120, f"uncapped fps {p['fps']:.0f} >= 120")
check(all(v["scaling_3d_scale"] == 1.0 for v in p["per_view"].values()), "render scale 1.0")
t = perf["timings"]
launch = json.loads((OUT / "m2_perf.launch.json").read_text())["launch_unix"]
first_ms = (t["first_frame_unix"] - launch) * 1000
# The editor binary parses every GDScript from source at launch (about 150 ms
# more than the exported build); run_export.sh holds the shipped build to 1000 ms.
check(first_ms <= 1100, f"first frame {first_ms:.0f} ms after launch <= 1100 (editor binary)")
visible_ms = first_ms + (t["models_visible_msec"] - t["first_frame_msec"])
check(visible_ms <= 3000, f"models visible {visible_ms:.0f} ms after launch <= 3000")

print(f"\n{len(failures)} screenshot check(s) failed" if failures else "\nall screenshot checks passed")
sys.exit(1 if failures else 0)
