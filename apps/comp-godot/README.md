# PWRUP Comp Dashboard (Godot)

Native port of the competition dashboard in `apps/comp`: the match HUD
(1920x1080) and the touchscreen (1920x515) in one Godot 4.7.2 process with two
OS windows, talking NetworkTables 4 to the robot through a GDScript client.
The Electron app in `apps/comp` stays the fallback; both read the same robot
address from the shared connection file.

## Requirements

| What | Needed for |
|---|---|
| Godot 4.7.2 (standard, not .NET) on `PATH` as `godot` | everything (`GODOT=/path/to/godot` overrides it in the scripts) |
| Godot 4.7.2 export templates | Windows and macOS exports |
| `uv` and Python 3.12 or 3.13 | fake robot, PathPlanner export, chaos and render-scale checks |
| Node 20+ | only to rebuild the 3D models or the icon set |
| FIR robot checkout and WPILib 2027 alpha 7 (`~/.wpilib/2027_alpha7/jdk`) | only the robot sim e2e and the Java PathPlanner parity dump |

## Run

```sh
godot --path apps/comp-godot                       # HUD + touchscreen, windowed on a dev machine
godot --path apps/comp-godot -- --screen=touch     # one screen only
godot --path apps/comp-godot -- --nt-host=127.0.0.1 --nt-port=5810   # against a local sim
```

The robot address normally comes from the shared connection file
(`~/.pwrup/shared-settings/connection-settings.json`, on Windows
`%USERPROFILE%\.pwrup\shared-settings\connection-settings.json`; override with
`PWRUP_SHARED_SETTINGS_PATH`). The touchscreen Settings tab edits it, and the
Electron app reads the same file. Everything else (map, visual, layout, selected
auto, intake override, display overrides) lives in `settings.json` in the user
data folder: `%APPDATA%\PWRUP\CompDashboard` on Windows,
`~/Library/Application Support/PWRUP/CompDashboard` on macOS. Godot writes its
log to `logs/godot.log` in the same folder.

F3 toggles the NetworkTables overlay (client state, RTT, every cached topic).

### Auto tab

- The list starts with which export is loaded (built-in or event update, with
  its export time) and a Reload Autos button.
- Autos the robot lists (`PathPlanner/ValidNames/Autos`) that the export lacks
  get their own cards marked "On the robot: no preview, not exported". They
  can be selected like any other auto, so a stale export never blocks a new
  auto.
- The detail pane compares the live robot pose with the viewed auto's start
  pose ("Start pose off by 1.37 m / 135°", green within 0.15 m and 8°). The HUD
  shows the same chip under the auto name before the match.
- The preview's expand button (top right) hides the list and the detail pane.
  Drag orbits, pinch or the mouse wheel zooms, two fingers (or a right drag)
  pan; the crosshair button or switching Path/Field returns to the framed view.

### Launch flags

Engine flags go before `--`, dashboard flags after it:

```sh
PWRUP-Comp.exe --rendering-driver opengl3_angle -- --kiosk --vsync=hud --render-scale=0.75
```

| Flag | Meaning |
|---|---|
| `--kiosk` | Tile the windows at start and again whenever the screen list changes (a display that wakes up late still gets its window). The launcher always passes it. |
| `--windowed` | Never tile at start. Without either flag the windows are tiled once at start, like the Electron app, unless a fixture or test run is active. |
| `--screen=both\|hud\|touch` | `both` (default): one process, two windows. `hud` and `touch` run one screen per process, the fallback if two windows misbehave on the driver station. Only the `touch` process publishes robot requests (auto, intake, aim trim). |
| `--hud-screen=N`, `--touch-screen=N` | Screen index for this run (0-based), beats the settings. |
| `--vsync=hud\|both\|off` | Which windows wait for vertical sync. Default `hud`: two vsynced GL windows on different displays can halve the frame rate. |
| `--render-scale=X` | 3D render scale for this run (0.25 to 1.0), not saved. The Visual tab sets the saved value. |
| `--max-fps=N` | Frame cap for this run (`0` = uncapped). The Visual tab sets the saved 30 or 60. |
| `--nt-host=H`, `--nt-port=P` | Robot address for this run, not saved. |
| `--debug-overlay` | Start with the F3 overlay open. |
| `--touch-test` | Open the touch test on both windows at start (also Visual > Diagnostics > Touch Test). |
| `--auto-quality=on\|off` | Force the automatic quality fallback on or off for this run (Visual > Auto Quality sets the saved value). |
| `--benchmark[=DIR]` | Run the driver-station benchmark and quit; see the checklist. |
| `--rendering-driver opengl3_angle` | Engine flag: render through ANGLE (Direct3D 11) instead of the native OpenGL driver. First thing to try on a Windows laptop with a broken or slow OpenGL driver. |

Test-only flags (`--fixture`, `--live`, `--screenshot`, `--perf-frames`,
`--run-s`, `--nt-trace`, `--autos-dir`, `--simulate-gpu-ms`, ...) are documented
at the top of `services/dev_service.gd` and `services/perf_governor.gd`.

### Frame rate and auto quality

With Visual > Auto Quality on (the default), the dashboard watches the frame
rate while a 3D view renders. When 3 s average below 92% of the frame cap, it
turns MSAA off, then lowers the render scale to 0.75 and 0.5, until the cap
holds. A step that does not raise the frame rate is undone and the fallback
stops, because then the GPU is not the limit (a CPU limit, or two vsynced
windows at half rate). The saved settings never change; Visual > Diagnostics
shows the effective scale and the fallback's state, and changing a Visual
setting starts it over. The log gets a frame rate line every minute.

### Window placement

The HUD goes fullscreen (borderless, not exclusive) on the display that is
exactly 1920x1080 and the touchscreen on the one that is exactly 1920x515.
Sizes are physical pixels, so Windows display scaling does not break the match.
A display with no match leaves that window windowed; two windows on a single
screen both stay windowed. The touchscreen Visual tab has a Displays section
(HUD and touchscreen display: Auto or 1 to 3) and a Re-tile button; those
overrides are saved and beat the size match. Ctrl+Shift+F (Cmd+Shift+F on
macOS) re-tiles from either window.

## Driver station install (Windows x64)

1. Export (below) or take `build/windows/` from a teammate: `PWRUP-Comp.exe`,
   `PWRUP-Comp.pck` and the `.bat` launchers must stay in one folder.
2. Copy the folder anywhere (not necessarily writable: logs and settings go to
   `%APPDATA%\PWRUP\CompDashboard`).
3. Start `PWRUP-Comp.bat`. It runs the dashboard with `--kiosk` and restarts it
   2 s after any crash (non-zero exit). Closing a window quits for real. After
   3 crashes within 30 s of starting, it switches the rest of the session to
   ANGLE. Arguments are passed through (`PWRUP-Comp.bat --nt-host=10.47.65.2`);
   `set PWRUP_ENGINE_ARGS=--rendering-driver opengl3_angle` forces ANGLE from
   the start. The launcher log is `%APPDATA%\PWRUP\CompDashboard\launcher.log`.
   `PWRUP-Comp-TwoProcess.bat` starts the HUD and the touchscreen as two
   processes instead (plan B below), each with the same restart loop.
4. Run the checklist below once per laptop.

### Driver-station checklist

Not run yet: none of these can be verified on the macOS development machine.
Check them on the real laptop with both displays attached, and keep the
benchmark files with the results. Until the touch item passes, keep the
Electron dashboard installed as the fallback.

- [ ] Placement: the HUD fills the 1920x1080 display and the touchscreen fills
      the 1920x515 one with no title bar or taskbar on top, with the laptop's
      Windows display scaling left as it is. Unplug and replug the
      touchscreen: within 2 s it gets its window back (`--kiosk`).
      Ctrl+Shift+F re-tiles. If a display reports a slightly different size,
      set it in Visual > Displays. Visual > Window Tiling shows which display
      each window took and why.
- [ ] Touch on the second window: Visual > Diagnostics > Touch Test (scroll the
      Visual tab right). Tap all four corners and the middle, drag across the
      screen, and pinch: every ring must sit under the fingertip, the press and
      drag counters must grow, and the HUD must not show the red "Touch reached
      the HUD window" box. Close it (bottom right), then check by hand: taps on
      the rail, hold-to-drag of a rail icon to the dock, a swipe down on an open
      tab, the auto preview scrub bar, and drag/pinch on the expanded preview.
      Every touch press is also in `logs/godot.log` (`touch-test:` lines). If
      touch goes to the wrong window or is offset, use
      `PWRUP-Comp-TwoProcess.bat` and repeat this item.
- [ ] Renderer and frame rate: close the dashboard and run
      `PWRUP-Comp-Benchmark.bat`. It runs the built-in benchmark (both windows
      on their displays, the longest auto previewing on a loop with the HUD
      mirroring it) with the native OpenGL driver and with ANGLE, about 40 s
      each, and opens `benchmark_native.txt` and `benchmark_angle.txt` from
      `%APPDATA%\PWRUP\CompDashboard`: frame rate and p95 frame time per render
      scale, the result at the 60 fps cap, and a recommended render scale. Use
      the faster renderer (for ANGLE, `set PWRUP_ENGINE_ARGS=--rendering-driver
      opengl3_angle` before the launcher, or edit it) and set Visual > Render
      Scale to the recommendation. If no scale holds 60 fps, set the frame cap
      to 30. If the app crashes at start or shows black 3D views, use ANGLE.
- [ ] Vsync across both displays: with the Auto tab preview playing, Visual >
      Diagnostics shows FPS at the cap (60) and "Auto qual" at full quality. If
      it drops to 30 or stutters, try `--vsync=off`; `--vsync=both` only if
      tearing is visible on the touchscreen.
- [ ] Robot link: on the field network the HUD shows live match data within a
      few seconds of the robot booting; the auto selected on the touchscreen
      shows "Selected" once the robot confirms it, and the start pose chip goes
      green once the robot sits on the start.
- [ ] Crash recovery: end `PWRUP-Comp.exe` in Task Manager; the launcher
      restarts it within about 5 s with the same auto and intake override.

## Tests

All scripts live in `tools/test/` and clean up the processes they start.

| Command | What it covers | Time |
|---|---|---|
| `run_unit.sh` | headless unit tests (`tests/unit`), runner self-test | 5 s |
| `run_integration.sh` | NT4 client, telemetry, HUD and controls against `tools/sim/fake_robot.py` (real ntcore) | 2 min |
| `run_screenshots.sh` | 3D views, joints, mesh sharing, startup timing (windowed) | 1 min |
| `run_hud_screenshots.sh` | every HUD state at 1920x1080 with pixel probes and geometry checks | 1 min |
| `run_touch_screenshots.sh` | every touchscreen tab, panel and widget, scripted touch input, restart persistence, the touch test | 2 min |
| `run_preview_checks.sh` | auto preview real-time playback, scrubbing, HUD mirroring, expand and touch orbit, start pose chips, robot-only autos, a user-folder export | 3 min |
| `run_perf.sh` | perf budget over a whole 8x fake match with both windows and the preview playing (45 draw calls per frame, 2D and 3D); render scale 0.5 halves the 3D resolution; the auto quality fallback under a simulated slow GPU; the driver-station benchmark end to end | 3 min |
| `run_two_process.sh` | `--screen=hud` and `--screen=touch` as two processes, only touch publishes | 20 s |
| `run_chaos.sh` | 10 random fake-robot restarts: READY within 6 s, auto and intake restored | 2 min |
| `run_export.sh` | Windows and macOS exports, pck contents, startup time of the shipped build (first frame within 1 s), HUD and touch suites from the exported macOS binary | 3 min |
| `run_soak.sh [--minutes=N]` | 10 minutes of looping 8x matches: clean log, memory, orphans | 10 min |
| `run_sim_e2e.sh` | the real robot code in the WPILib sim (scratch copy of FIR, never the repo): live HUD, auto and intake round trips from the UI | 4 min |
| `run_all.sh [--quick] [--no-sim]` | all of the above in order with a summary | 30 min |

Screenshots and reports land in `apps/comp-godot/.screenshots/` (gitignored).
A single fixture can be rendered by hand:

```sh
godot --path apps/comp-godot -- --screen=hud --design-size --fixture=hud_shift_warning --screenshot=/tmp/shot
```

## 3D models

`assets/models/{robot,field}.glb` are simplified from the raw CAD exports in
`apps/comp/cad-assets` (read in place). Rebuild after a CAD change:

```sh
cd apps/comp-godot/tools/assets && npm ci && node build_models.mjs
```

The script enforces the triangle, surface and size budgets and writes
`models.manifest.json`; a unit test fails when the manifest's source hashes no
longer match the raw files. Commit the GLBs, their `.import` files and the
manifest. The rig and camera metadata are in `data/rig/`.

## UI drawing and fonts

The GL Compatibility renderer spends one draw call per polygon and one per run
of rects that share a texture, so the UI never uses `StyleBoxFlat`,
`ColorRect` or `draw_circle`. `ui/theme/ui_draw.gd` cuts every shape and
lucide icon from one atlas (`PwBox` is the stylebox, `PwRect` the color rect),
and puts text on a z slot per font above the shapes; stacked layers (overlays,
dock, keyboard) step z by `UiDraw.LAYER_Z`. Custom `_draw()` code calls
`UiDraw.begin(self)` first and draws text with `UiDraw.text`. `run_perf.sh`
reports the 2D draw calls per window next to the 3D ones.

The fonts are static Inter (300 to 700) and Roboto Mono (400, 500) weights cut
from the upstream variable fonts with their overlaps removed, imported as MSDF
so every size of a weight shares one glyph texture. To rebuild them:

```sh
apps/comp-godot/tools/fonts/build_fonts.sh /path/to/InterVariable.ttf /path/to/RobotoMono-VariableFont_wght.ttf
```

## PathPlanner autos

The robot's PathPlanner files are copied raw into `data/pathplanner/` and every
auto is precomputed into `data/autos/` (sampled trajectories, event intervals,
mechanism timeline) with the official PathPlannerLib, so the dashboard never
generates trajectories itself.

```sh
./scripts/sync-pathplanner-from-fir.sh --godot-only            # dry run, writes nothing
./scripts/sync-pathplanner-from-fir.sh --godot-only --apply    # copy from FIR and export
```

The export uses the robot's own Java PathPlannerLib through
`tools/pathplanner/run_java_dump.sh` when the FIR scratch copy is available, and
the Python library otherwise (see `tools/pathplanner/export_autos.py`).
Command timing models live in `data/auto_commands.json`, display names and
descriptions in `data/auto_meta.json`. A unit test fails when the raw files
change without a re-export. Commit `data/pathplanner` and `data/autos`
together; the next app export ships them inside the pck.

New autos at an event do not need a new app export. The dashboard loads the
newest valid export from its user data folder (`autos/` next to
`settings.json`) when it is at least as new as the one in the pck:

```sh
# on the driver station laptop itself (Git Bash, with uv and the FIR checkout)
./scripts/sync-pathplanner-from-fir.sh --godot-only --apply --user-dir
# on another machine: export to a folder, then copy it into the laptop's
# %APPDATA%\PWRUP\CompDashboard\autos
./scripts/sync-pathplanner-from-fir.sh --godot-only --apply --user-dir=/Volumes/USB/CompDashboard
```

Then tap Reload Autos on the Auto tab (or restart the dashboard); the list
header says "event update" with the export time. Autos the robot has that
are not exported yet stay selectable without a preview in the meantime.

## Windows export

Install the export templates once (about 1.3 GB download; only the Windows and
macOS files are needed):

```sh
curl -LO https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
unzip Godot_v4.7.2-stable_export_templates.tpz 'templates/version.txt' 'templates/macos.zip' \
  'templates/windows_*_x86_64*' 'templates/icudt_godot.dat' -d tpl
mkdir -p ~/Library/Application\ Support/Godot/export_templates/4.7.2.stable
cp tpl/templates/* ~/Library/Application\ Support/Godot/export_templates/4.7.2.stable/
```

(Linux: `~/.local/share/godot/export_templates/4.7.2.stable`, Windows:
`%APPDATA%\Godot\export_templates\4.7.2.stable`, or the editor's Manage
Export Templates dialog.) Then:

```sh
apps/comp-godot/tools/test/run_export.sh   # exports, checks the pck, runs the fixture suites from the macOS build
# or just the export (from the repo root; the export path is relative to the project):
mkdir -p apps/comp-godot/build/windows && godot --headless --path apps/comp-godot --export-release "Windows Desktop" build/windows/PWRUP-Comp.exe
cp apps/comp-godot/tools/windows/PWRUP-Comp.bat apps/comp-godot/build/windows/
```

`export_presets.cfg` has the `Windows Desktop` (x86_64, separate pck,
unsigned) and `macOS` (universal, ad-hoc signed) presets. Both include `*.json`
so the raw data (`data/**`, `ui/icons/lucide.json`, the model manifest) ships
in the pck, and exclude `tests/`, `tools/` and scratch folders. The Windows
exe is not code-signed, so SmartScreen may ask once on a new laptop.
