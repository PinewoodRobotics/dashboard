# comp-gpui

GPUI port of the competition dashboard. `crates/app` and `crates/dash-core` hold the dashboard
UI port; the crates below are the 3D bridge, which shows views rendered by a hidden Godot
process inside GPUI through shared GPU textures. Integrating the 3D element into `crates/app`
is a later step.

## 3D bridge

| Path | What it is |
|---|---|
| `crates/protocol` | Host <-> Godot messages: newline-delimited JSON over loopback TCP |
| `crates/host` | Library (`Bridge3d`, `View3d`) plus the spike shell binary `host` |
| `crates/godot-bridge` | GDExtension: IOSurface rings, `texture_create_from_extension`, queue fence, socket |
| `crates/godot-launch-hook` | Dylib injected into Godot: no Dock icon, no focus stealing, dies with the host |
| `crates/probes` | Phase 1 IOSurface probe |
| `godot/` | Godot 4.7 project: producer loop, views, copies of comp-godot's orbit, CAD lighting and material scripts |
| `tools/models` | Decodes the Draco-compressed `Robot-Full.glb` for Godot |
| `vendor/gpui-pre-apple` | gpui-pre-apple 0.3.12 with `vendor/patches/gpui-pre-apple.diff` applied |

### Running

```sh
export PATH=$HOME/.cargo/bin:$PATH
# Robot-Full.glb requires KHR_draco_mesh_compression, which Godot's GLTFDocument cannot read.
(cd tools/models && npm ci && node decode.mjs)        # -> models/Robot-Full.glb (156 MiB, not in git)
cargo build --release -p host -p godot-bridge -p godot-launch-hook
target/release/host                                    # spike layout: robot view, minimap inset, drawer
target/release/host --kiosk                            # robot view at exactly 1920x515 device px
target/release/host --help                             # all flags
```

The host copies `libgodot_bridge.dylib` and `libgodot_launch_hook.dylib` from its own target
directory (`target/debug` for a debug host, `target/release` for a release one) into
`godot/bin/` before launching Godot, so build them with the same profile as the host. It runs
Godot's import pass when the project's scripts are newer than its class cache.

Models default to `models/Robot-Full.glb` and `../comp/cad-assets/field-2026.glb`, loaded at
runtime with GLTFDocument (the field's staged Fuel nodes are dropped, as in the web minimap).
`PWRUP_ROBOT_GLB` and `PWRUP_FIELD_GLB` point elsewhere, for example at comp-godot's merged
build (`apps/comp-godot/tools/assets/build_models.mjs`, which writes
`apps/comp-godot/assets/models/{robot,field}.glb`). `GODOT_BIN` overrides
`/opt/homebrew/bin/godot`, and `PWRUP_GODOT_ARGS` passes extra producer flags such as
`--max-ahead N`.

### How it works

- **One Godot process** renders every view of every window. `Bridge3d` supervises it: spawns
  it with the launch hook, forwards its messages to views, and respawns it when it exits. Each
  `View3d` keeps the CVPixelBuffer it is showing, so after a crash the last frame stays up, and
  views reopen at their current size when the new process connects. Godot sends no frames for a
  view until its models are loaded, so the old frame stays through the reload.
- **Views** (`OpenView`, `Resize`, `SetActive`, `CloseView`) each own a SubViewport and a ring
  of four global IOSurfaces. A Godot tick renders only the active views whose next frame is due,
  so the robot view and the HUD minimap run at independent rates. One `force_draw` renders them,
  each view's `texture_copy` into its ring slot is recorded, a second `force_draw` submits the
  copies, and an empty command buffer's completion sends `Frame`. The host acks the frame it
  paints; the producer never reuses the displayed or previously displayed slot.
- **Resize**: `View3d` measures its element in device pixels every frame. A change is
  debounced 150 ms, then Godot builds a new surface generation at that size. Meanwhile the
  previous generation is drawn cropped to cover the element (aspect kept). Once settled the
  frame is exactly the element's size.
- **Input**: a press on the view element (hit-tested, so GPUI content over it, such as the
  drawer, takes the press) captures the pointer until release. Mouse down/move/up, wheel (as
  Chromium WheelEvent deltaY) and trackpad pinch become `Pointer` messages, which Godot turns
  into InputEvents for the copied `OrbitInput.handle`, driving the copied `OrbitCamera` with its
  OrbitControls damping, presets and idle return. `Pointer` carries `kind` (Mouse/Touch), `id`
  and `phase`, and Godot already maps touches to InputEventScreenTouch/Drag; the host does not
  produce touches yet. Each Pointer carries a host stamp that `Frame` echoes back.
- **Timing at present**: the vendored renderer adds `set_surface_present_observer`, called from
  each drawable's presented handler with the surfaces it drew and `presentedTime`. Frame age is
  measured from Godot's fence to that present, and input latency from the host stamp to it.

### Measurements

MacBook Pro M1 Pro (Metal, Apple7 GPU), Godot 4.7.2, release build, `--kiosk` (robot view
1920x515 device px, MSAA 2x, driver robot view camera), HUD minimap view 720x440 px at 30 fps
when on, scripted drag and wheel input during the run (`--demo-input`). Values are medians of
the overlay over the last two thirds of 34 s runs.

| Models | Views | Robot fps produced / shown | Godot CPU ms | Tick wall ms | GPU ms | Frame age at present ms | Input to present ms | Host fps |
|---|---|---|---|---|---|---|---|---|
| none (empty scene) | robot @120 | 120 / 95 | 0.4 | 1.8 | 1.7 | 19 | 26 | 120 |
| raw GLTFDocument | robot @120 | 77 / 73 | 2.2 | 12.6 | 10.8 | 46 | 65 | 78 |
| raw GLTFDocument | robot @120 + minimap @30 | 40 / 40 | 5.6 | 24.1 | 18.7 | 46 | 80 | 41 |
| merged | robot @120 | 82 / 50 | 1.0 | 11.4 | 10.8 | 26 | 58 | 83 |
| merged | robot @120 + minimap @30 | 51 / 51 | 1.7 | 19.1 | 17.8 | 46 | 75 | 51 |
| merged | robot @60 | 60 / 48 | 1.1 | 11.7 | 10.8 | 43 | 58 | 60 |
| merged | robot @60 + minimap @30 | 52 / 51 | 1.1 | 16.9 | 16.2 | 46 | 72 | 59 |

With the minimap on it held 30 / 30 fps in every run, at 46 ms frame age; its GPU ms read
20 to 23 because a tick that draws both views fences both.

- *raw*: `Robot-Full.glb` decoded by `tools/models` (2929 mesh instances, 3221 surfaces,
  13.0 M triangles) and `field-2026.glb` (2473 instances, 2511 surfaces, 4.0 M triangles after
  dropping Fuel). *merged*: the same triangles joined per rig node and material by comp-godot's
  `build_models.mjs` (robot 7 instances / 127 surfaces, field 1 / 27).
- **Godot CPU ms** is the CPU time of Godot's main thread during the tick
  (`CLOCK_THREAD_CPUTIME_ID`). **Tick wall ms** is the same tick in wall time; the difference
  is RenderingDevice waiting for the previous frame's GPU work. **GPU ms** is from the tick's
  submit to the fence after the copies. Godot's own viewport GPU timestamps read 0 on Metal.
- The scene is GPU bound on triangles: 13 M robot triangles cost about 10.8 ms at this size,
  and the minimap draws the robot again. Merging meshes only saves CPU (draw calls), not GPU.
  Robot LODs, or a decimated robot in the minimap, are the lever.
- Frame age has a floor of about 19 ms even for an empty scene (the frame waits for GPUI's next
  display-link frame, then for the present after it, at 120 Hz). When Godot keeps the GPU busy,
  GPUI's frame queues behind Godot's work and age rises to about 45 ms.
- Shown fps is below produced fps when Godot and GPUI run at similar unsynchronized rates and
  two frames land between GPUI frames. Capping frames ahead (`--max-ahead 1`, Godot waits for
  each ack) made it worse in a merged robot @120 run: 46 to 55 fps at 43 to 46 ms frame age,
  against 86 to 88 fps at 9 ms ring-limited, so the default stays ring-limited.
- Models load in about 3 s (merged robot) and 0.8 s (merged field), 3 to 7 s each raw. After
  `kill -9` of Godot the host kept showing the last frames (overlay: `godot pid -`,
  `restarts 1 (last exit: signal: 9 (SIGKILL))`), a new Godot started at once and resumed the
  views after its models loaded, about 4 s later. `kill -9` of the host makes Godot exit
  within 0.6 s.

### Phase 1 issues, resolved

- **Respawn**: see above.
- **Fixed 1280x720 view stretched to fill**: views render at their element's device-pixel size.
  A scripted resize from 2136x1274 to 2616x1464 showed generation 1 cropped while the window
  moved, then one new generation (2) at exactly 2616x1464.
- **Bridge path hardcoded to the release build**: the host copies the bridge from its own
  profile directory. A debug host ran with the debug bridge (same md5 in `godot/bin`).
- **30 fps when inactive**: GPUI throttles it. `WindowOptions::inactive_frame_interval` defaults
  to 33.3 ms in gpui-pre's platform-independent `window.rs`, so Windows has it too. A host
  started from a terminal is also never activated (macOS cooperative activation), so it ran at
  30 fps from the start. It matters on the kiosk: the FRC Driver Station keeps focus through a
  match, leaving the dashboard inactive. The host sets `inactive_frame_interval` and
  `low_power_frame_interval` to `None`. Measured at a 60 fps robot view: 30 host fps with
  GPUI's default whether or not Finder was in front, 58 to 60 with the fix in both cases.
  `PWRUP_GPUI_INACTIVE_THROTTLE=1` restores the default.
- **Frame age measured at frame build**: now measured at present (above); the overlay falls
  back to paint time only when the renderer has reported no present.
- **Dock icon flash**: Godot's OS constructor sets the Regular activation policy before any
  GDExtension loads, and showing its main window runs an activation hack that makes the process
  a foreground app again. `godot-launch-hook`, loaded with `DYLD_INSERT_LIBRARIES` (Godot.app
  allows DYLD variables), turns Regular into Accessory and makes
  `-[GodotApplication activateApplication]` a no-op before Godot's `main` runs. `lsappinfo`
  sampled every 50 ms reads `Foreground` for the whole run without it and `UIElement` for the
  whole run with it.

### Known limits

- A window entirely covered by another gets no display-link frames, so it stops acking and
  Godot stops rendering its views until it is uncovered. The second window opens offset from the
  first for that reason.
- The host does not send touches yet: gpui-pre's touch dispatch is still pending.
- Windows (plan step 9) is not implemented: the bridge, launch hook and vendored renderer patch
  are macOS only.
