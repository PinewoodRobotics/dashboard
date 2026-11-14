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
| `--rendering-driver opengl3_angle` | Engine flag: render through ANGLE (Direct3D 11) instead of the native OpenGL driver. First thing to try on a Windows laptop with a broken or slow OpenGL driver. |

Test-only flags (`--fixture`, `--live`, `--screenshot`, `--perf-frames`,
`--run-s`, `--nt-trace`, ...) are documented at the top of
`services/dev_service.gd`.

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
   `PWRUP-Comp.pck` and `PWRUP-Comp.bat` must stay in one folder.
2. Copy the folder anywhere (not necessarily writable: logs and settings go to
   `%APPDATA%\PWRUP\CompDashboard`).
3. Start `PWRUP-Comp.bat`. It runs the dashboard with `--kiosk` and restarts it
   2 s after any crash (non-zero exit). Closing a window quits for real. After
   3 crashes within 30 s of starting, it switches the rest of the session to
   ANGLE. Arguments are passed through (`PWRUP-Comp.bat --nt-host=10.47.65.2`);
   `set PWRUP_ENGINE_ARGS=--rendering-driver opengl3_angle` forces ANGLE from
   the start. The launcher log is `%APPDATA%\PWRUP\CompDashboard\launcher.log`.
4. Run the checklist below once per laptop.

### Driver-station checklist

These cannot be verified on the macOS development machine; check them on the
real laptop with both displays attached.

- [ ] Placement: the HUD fills the 1920x1080 display and the touchscreen fills
      the 1920x515 one with no title bar or taskbar on top. Unplug and replug
      the touchscreen: within 2 s it gets its window back (`--kiosk`).
      Ctrl+Shift+F re-tiles. If a display reports a slightly different size,
      set it in Visual > Displays.
- [ ] Touch on the second window: taps, drags and swipes land on the
      touchscreen window (not the HUD, not offset), including hold-to-drag of
      rail icons and the auto preview scrub bar. If touch input goes to the
      wrong window or is offset, run two processes instead:
      `PWRUP-Comp.exe -- --kiosk --screen=hud` and
      `PWRUP-Comp.exe -- --kiosk --screen=touch` (edit the launcher or make two
      shortcuts), and re-check.
- [ ] Vsync across both displays: Visual > Diagnostics shows FPS at the cap
      (60) with the Auto tab preview playing. If it drops to 30 or stutters,
      try `--vsync=off`; `--vsync=both` only if tearing is visible on the
      touchscreen.
- [ ] Renderer: Diagnostics shows the adapter. If the app crashes at start,
      shows black 3D views or runs far below 60 fps, try
      `--rendering-driver opengl3_angle` (or `set PWRUP_ENGINE_ARGS=...` for the
      launcher) and compare.
- [ ] Frame rate per render scale: with the preview playing and a robot (or the
      sim) connected, note the Diagnostics FPS at render scale 1.0, 0.75, 0.5
      and 0.25 (Visual tab, applies live). Keep the highest scale that holds
      60 fps, or set the frame cap to 30.
- [ ] Robot link: on the field network the HUD shows live match data within a
      few seconds of the robot booting; the auto selected on the touchscreen
      shows "Selected" once the robot confirms it.
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
| `run_touch_screenshots.sh` | every touchscreen tab, panel and widget, scripted touch input, restart persistence | 2 min |
| `run_preview_checks.sh` | auto preview real-time playback, scrubbing, HUD mirroring | 2 min |
| `run_perf.sh` | perf budget over a whole 8x fake match with both windows and the preview playing (45 draw calls per frame, 2D and 3D); render scale 0.5 halves the 3D resolution | 2 min |
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
together, then re-export the app (the files ship inside the pck).

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
