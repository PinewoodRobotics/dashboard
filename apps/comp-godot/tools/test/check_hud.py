"""Cross-fixture assertions over the reports written by run_hud_screenshots.sh.

Usage: python3 check_hud.py OUT_DIR FIXTURE...
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

OUT = Path(sys.argv[1])
FIXTURES = sys.argv[2:]
failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)


def report(name: str) -> dict:
    return json.loads((OUT / f"{name}.json").read_text())


def near(a: float, b: float, tol: float = 2.0) -> bool:
    return abs(a - b) <= tol


reports = {n: report(n) for n in FIXTURES}
for name, r in reports.items():
    check(not r["failures"], f"{name}: probes pass {r['failures']}")
    check(r["windows"]["hud"]["size"] == [1920, 1080], f"{name}: captured at 1920x1080")
    check(r["nt"]["fixture_mode"] and r["nt"]["state"] == "IDLE", f"{name}: offline fixture, no socket")
    log = (OUT / f"{name}.log").read_text()
    check(not re.search(r"SCRIPT ERROR|^ERROR", log, re.M), f"{name}: no errors in the log")

want = {
    "hud_pre_match": ("pre_match", "hidden", "NONE", False, "00:00.00"),
    "hud_autonomous": ("autonomous", "purple", "NONE", True, "02:27.53"),
    "hud_transition": ("transition", "green", "NONE", True, "02:14.81"),
    "hud_shift_active": ("shift1", "green", "NONE", True, "01:50.42"),
    "hud_shift_warning": ("shift2", "yellow", "NONE", True, "01:23.74"),
    "hud_shift_inactive": ("shift2", "hidden", "NONE", True, "01:12.05"),
    "hud_endgame": ("endgame", "green", "NONE", False, "00:21.37"),
    "hud_post_match": ("post_match", "hidden", "NONE", False, "00:00.00"),
    "hud_nt_disconnected": ("shift1", "green", "DISCONNECTED", True, "01:50.42"),
    "hud_no_data": ("pre_match", "hidden", "NO_DATA", False, "00:00.00"),
    "hud_pose_invalid": ("shift1", "green", "NONE", True, "01:50.42"),
    "hud_stale": ("shift1", "green", "STALE", True, "01:48.92"),
}
for name, (phase, header, banner, shift_visible, timer) in want.items():
    if name not in reports:
        continue
    r = reports[name]
    m, lay = r["match"], r["hud_layout"]
    check(m["phase"] == phase and m["header"] == header and m["banner"] == banner, f"{name}: phase {m['phase']}, header {m['header']}, banner {m['banner']}")
    check(lay["shift"]["visible"] == shift_visible, f"{name}: shift indicator visible = {shift_visible}")
    check(lay["timer"]["text"] == timer, f"{name}: timer shows {timer} (got {lay['timer']['text']})")
    check(lay["banner"]["visible"] == (banner != "NONE"), f"{name}: banner visible = {banner != 'NONE'}")

w = reports["hud_shift_warning"]["hud_layout"]
check(w["shift"]["text"] == "00.00", "shift warning: main number 00.00")
check(w["buffer"]["visible"] and w["buffer"]["text"] == "01.74 with buffer", f"shift warning: buffer line {w['buffer']['text']!r}")
for name in ["hud_shift_active", "hud_shift_inactive", "hud_autonomous", "hud_transition"]:
    check(not reports[name]["hud_layout"]["buffer"]["visible"], f"{name}: no buffer line without show_buffer")
check(reports["hud_autonomous"]["hud_layout"]["shift"]["text"] == "07.53", "autonomous: shift number is the period time")
check(reports["hud_shift_inactive"]["hud_layout"]["shift"]["text"] == "12.05", "shift inactive: shift number is the shift time")
check(reports["hud_stale"]["hud_layout"]["banner"]["text"] == "Robot Data Stale", "stale seq: banner while the socket is open")
check(reports["hud_nt_disconnected"]["hud_layout"]["banner"]["text"] == "NT Disconnected", "disconnected banner text")
for name in ["hud_nt_disconnected", "hud_stale", "hud_no_data"]:
    check(reports[name]["hud_layout"]["timer"]["color"] != "ffffffff", f"{name}: timers dimmed")

g = w
check(g["header"]["rect"] == [0.0, 0.0, 1920.0, 180.0], "geometry: header 0..180 full width")
box = g["timer"]["box"]
line = g["timer"]["line"]
check(near(box[0], 491) and near(box[2], 938), f"geometry: timer box {box}")
check(near(line[0] + line[2] / 2, 960) and near(line[1] + line[3] / 2, 90), f"geometry: timer line centered {line}")
check(g["timer"]["sizes"] == [128, 64] and g["shift"]["sizes"] == [128, 64], "geometry: 128 / 64 px mono digits")
blk, icon = g["shift"]["block"], g["shift"]["icon"]
check(near(blk[0] + blk[2] / 2, 960) and near(icon[1] + icon[3] / 2, 335.5), f"geometry: shift block centered at (960, 335.5): block {blk}, icon {icon}")
check(icon[2] == 200 and icon[3] == 200, "geometry: 200 px icon")
buf = g["buffer"]["line"]
check(near(buf[0], 975) and near(buf[1], 224), f"geometry: buffer line at x 975, top 224 ({buf[0]}, {buf[1]})")
check(g["minimap"]["rect"] == [540.0, 480.0, 840.0, 619.2], f"geometry: minimap {g['minimap']['rect']}")
b = reports["hud_nt_disconnected"]["hud_layout"]["banner"]["rect"]
check(near(b[0] + b[2] / 2, 960) and near(b[1] + b[3], 1056), f"geometry: banner bottom-center 24 px from the bottom {b}")

def probe(name: str, probe_name: str) -> dict:
    return next(p for p in reports[name]["probes"] if p["name"] == probe_name)


edge = probe("hud_shift_active", "minimap soft left edge")["mean_luma"]
inner = probe("hud_shift_active", "minimap interior lit")["mean_luma"]
check(edge < 0.2 * inner, f"minimap edge fades to black: edge luma {edge:.3f} < 20% of interior {inner:.3f}")

invalid = reports["hud_pose_invalid"]
lit = probe("hud_shift_active", "robot luma")["mean_luma"]
dim = probe("hud_pose_invalid", "robot luma")["mean_luma"]
check(dim < 0.7 * lit, f"robot drawn dimmed when the pose is invalid: luma {dim:.3f} vs {lit:.3f}")
check(invalid["match"]["robot_dimmed"] and not reports["hud_shift_active"]["match"]["robot_dimmed"], "robot dimmed only when robot_pose_valid is false")
check(reports["hud_nt_disconnected"]["match"]["robot_dimmed"], "robot dimmed while disconnected")

toast = reports["hud_lane_toast"]["hud_layout"]["toast"]
check(toast["visible"] and toast["text"] == "Lane Alignment ON", f"lane toast shown: {toast}")

ms = reports["hud_map_driver"]["map_settings"]
check(ms == {"mode": "driver", "angle": 1.0, "zoom": 1.0}, f"map settings from the fixture reach Settings {ms}")

for name in FIXTURES:
    launch = json.loads((OUT / f"{name}.launch.json").read_text())["launch_unix"]
    first = reports[name]["timings"]["first_frame_unix"]
    if name == "hud_shift_active":
        # The editor binary parses every GDScript from source at launch; the
        # exported build (PWRUP_EXPORTED_BIN, run_export.sh) is held to 1000 ms.
        limit = 1000 if os.environ.get("PWRUP_EXPORTED_BIN") else 1100
        check((first - launch) * 1000 <= limit, f"HUD drawn {(first - launch) * 1000:.0f} ms after launch <= {limit}")

if failures:
    print(f"\n{len(failures)} check(s) failed")
    sys.exit(1)
print("\nall HUD checks passed")
