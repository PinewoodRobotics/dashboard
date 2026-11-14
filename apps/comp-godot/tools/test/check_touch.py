#!/usr/bin/env python3
"""Cross-run checks for tools/test/run_touch_screenshots.sh.

Usage: check_touch.py OUT SETTINGS_DIR fixture...
Every report must exist with no failures and at most 2 SubViewports rendering
3D; touchscreen geometry must match touchscreen.md section 1; the saved
settings files must hold what the scripted runs left behind."""
import json
import sys
from pathlib import Path

out, settings_dir, fixtures = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
errors = []


def report(name):
    p = out / f"{name}.json"
    if not p.exists():
        errors.append(f"{name}: no report")
        return None
    r = json.loads(p.read_text())
    for f in r.get("failures", []):
        errors.append(f"{name}: {f}")
    if r.get("max_rendering_views", 0) > 2:
        errors.append(f"{name}: {r['max_rendering_views']} SubViewports rendered 3D in one frame")
    return r


def near(a, b, tol=0.5):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


names = list(fixtures) + [f"both_{f}" for f in ("touch_driver", "touch_tab_robot3d", "touch_panel_map", "touch_dock")]
scripts = ["touch_script_nav", "touch_script_restart", "touch_script_map", "touch_script_map_restart", "touch_script_visual",
           "touch_script_visual_restart", "touch_script_widgets", "touch_script_widgets_both", "touch_script_robot3d",
           "touch_script_robot3d_live", "touch_script_driver", "touch_script_howard", "touch_live_fake",
           "touch_script_controls_offline", "touch_script_controls_live"]
reports = {n: report(n) for n in names + scripts}

for name, r in reports.items():
    if not r or "touch" not in r:
        continue
    t = r["touch"]
    if not near(t["rail"]["rect"], [0, 0, 84, 515]):
        errors.append(f"{name}: rail rect {t['rail']['rect']}")
    expanded = t["state"]["open_panel"] != ""
    want_drawer = [1380, 0, 540, 515] if expanded else [1836, 0, 84, 515]
    if not near(t["drawer"]["rect"], want_drawer):
        errors.append(f"{name}: drawer rect {t['drawer']['rect']}, want {want_drawer}")
    if t["drawer"]["edge_px"] != (4 if expanded else 0):
        errors.append(f"{name}: drawer accent edge {t['drawer']['edge_px']}")
    want_overlay = [84, 0, 1920 - 84 - want_drawer[2], 515]
    if not near(t["overlay"]["rect"], want_overlay):
        errors.append(f"{name}: overlay rect {t['overlay']['rect']}, want {want_overlay}")
    if t["dock"]["visible"]:
        d = t["dock"]["rect"]
        if not (near([d[2]], [860]) and near([d[0] + d[2] / 2], [960]) and near([d[1] + d[3]], [515])):
            errors.append(f"{name}: dock rect {d}")
    if t["rail"]["icon_px"] != 48:
        errors.append(f"{name}: rail icons {t['rail']['icon_px']} px")
    rendering_touch = sum(1 for v in t["views"] if v["rendering"])
    if rendering_touch > 1:
        errors.append(f"{name}: {rendering_touch} touch views rendering")

layout = json.loads((settings_dir / "layout.json").read_text())["layout"]
if layout != {"rail": ["settings", "auto"], "dock": ["robot3d", "visual", "auto", "settings", "effects", "howard"]}:
    errors.append(f"layout.json after the restart run: {layout}")
m = json.loads((settings_dir / "map.json").read_text())["map"]
if m["mode"] != "driver" or m["zoom"] < 0.9:
    errors.append(f"map.json: {m}")
v = json.loads((settings_dir / "visual.json").read_text())["visual"]
if v != {"render_scale": 0.75, "msaa": 4, "fps_cap": 30}:
    errors.append(f"visual.json: {v}")
c = json.loads((settings_dir / "controls.json").read_text())["controls"]
if c != {"selected_auto": "Move Forward And Shoot Left", "intake_speed": None}:
    errors.append(f"controls.json after the live controls run: {c}")
conn = json.loads((settings_dir / "connection-settings.json").read_text()) if (settings_dir / "connection-settings.json").exists() else None
if conn is not None:
    errors.append("the live controls run wrote the shared connection file without a Save")

for e in errors:
    print("CHECK FAIL:", e)
print(f"check_touch: {len(reports)} reports, {len(errors)} problem(s)")
sys.exit(1 if errors else 0)
