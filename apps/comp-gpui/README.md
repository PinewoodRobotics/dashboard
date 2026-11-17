# comp-gpui

GPUI port of the competition dashboard. `crates/app` and `crates/dash-core` hold the dashboard
UI port; the crates below are the 3D bridge, which shows views rendered by a hidden Godot
process inside GPUI through shared GPU textures: IOSurfaces on macOS, named D3D12 textures on
Windows (untested, see [Windows](#windows-untested)). Integrating the 3D element into
`crates/app` is a later step.

## 3D bridge

| Path | What it is |
|---|---|
| `crates/protocol` | Host <-> Godot messages: newline-delimited JSON over loopback TCP |
| `crates/host` | Library (`Bridge3d`, `View3d`) plus the spike shell binary `host` |
| `crates/godot-bridge` | GDExtension: IOSurface / D3D12 rings, `texture_create_from_extension`, queue fence, socket |
| `crates/godot-launch-hook` | Dylib injected into Godot: no Dock icon, no focus stealing, dies with the host (macOS) |
| `crates/probes` | Phase 1 IOSurface probe, `win_share_probe` for D3D12 to D3D11 sharing |
| `godot/` | Godot 4.7 project: producer loop, views, copies of comp-godot's orbit, CAD lighting and material scripts |
| `tools/models` | Decodes the Draco-compressed `Robot-Full.glb` for Godot |
| `vendor/gpui-pre-apple` | gpui-pre-apple 0.3.12 with `vendor/patches/gpui-pre-apple.diff` applied |
| `vendor/gpui-pre`, `vendor/gpui-pre-windows` | 0.3.12 with `vendor/patches/gpui-pre.diff` and `gpui-pre-windows.diff`: `surface()` draws named shared textures on Windows |

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
`/opt/homebrew/bin/godot`, `PWRUP_GODOT_ARGS` passes extra producer flags such as
`--max-ahead N`, and `GODOT_ARGS` passes engine flags such as `--gpu-validation`.

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
1920x515 device px, MSAA 2x, driver robot view camera), HUD minimap view 716x436 px at 30 fps
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
- Windows (plan step 9) is written but has never run; see below.

## Windows (UNTESTED)

Everything below was written on macOS and only type-checked with
`cargo check --target aarch64-pc-windows-msvc` (and `x86_64-pc-windows-msvc`). None of it has
run. Work through the checklist in order: each step isolates one layer.

### How it fits together

- `godot-bridge/src/win.rs`: each ring slot is a committed `R8G8B8A8_UNORM` texture created on
  Godot's own `ID3D12Device` with `D3D12_HEAP_FLAG_SHARED` and
  `ALLOW_RENDER_TARGET | ALLOW_SIMULTANEOUS_ACCESS`, given a named NT handle
  `Local\pwrup-p{godot pid}-v{view}-g{generation}-s{slot}` and imported with
  `RenderingDevice.texture_create_from_extension`. Each tick Godot `texture_copy`s its viewport
  into a free slot; the bridge signals an `ID3D12Fence` on Godot's main queue and a waiter
  thread sends the `Frame` message after `SetEventOnCompletion` fires.
- Godot 4.7.2's D3D12 driver records an imported texture as being in `RENDER_TARGET` state. With
  legacy barriers it transitions from there, so the slot is created in `RENDER_TARGET`. With
  enhanced barriers (`D3D12_OPTIONS12.EnhancedBarriersSupported`) it skips barriers on
  simultaneous-access textures entirely, so the slot is created in `COMMON` and relies on
  implicit promotion. Which path ran is the first thing to check if the debug layer complains.
- The name carries Godot's pid (not just view/generation/slot as first planned) because a
  respawned Godot restarts generations at 1 and GPUI caches opened textures by name.
- `vendor/gpui-pre` + `vendor/gpui-pre-windows` (`vendor/patches/gpui-pre*.diff`):
  `surface(SharedTexture { name, size, opaque })` paints a `PaintSurface` carrying the name.
  `draw_surfaces` opens it once with `ID3D11Device1::OpenSharedResourceByName` on GPUI's D3D11
  device, caches texture + SRV by name (evicted after 60 frames unused), and draws it through the
  polychrome sprite pipeline. `opaque` forces alpha to 1 in the shader because Godot leaves alpha 0
  on background pixels.
- `host`: `View3d` is shared with macOS; on Windows its slots are `SharedTexture`s named from
  the connected Godot's pid, painted with `Window::paint_shared_texture`. `host/src/win/` holds
  the test pattern (a host-owned D3D11 texture shared by name, so `--test-pattern` goes through
  the same GPUI path) and a logger that routes GPUI's `log` output to stderr.
- Godot's window is hidden with `ShowWindow(SW_HIDE)` and marked `WS_EX_TOOLWINDOW`, so it has no
  taskbar button. Rendering does not depend on it: the render loop is off and the script calls
  `RenderingServer.force_draw`.
- Vulkan fallback: not built. If Godot's D3D12 driver turns out unusable on the laptop, the
  equivalent is a `VkImage` with `VK_KHR_external_memory_win32` exported as an NT handle,
  imported by GPUI's D3D11 with `OpenSharedResource1`, plus a `VK_KHR_external_semaphore_win32`
  or a CPU wait on `vkWaitForFences` before sending `Frame`. `project.godot` currently pins
  `rendering_device/driver.windows="d3d12"` with fallbacks off, and the bridge reports
  "RenderingDevice is not D3D12" if that changes.

### Prerequisites

- Rust with the MSVC toolchain (`rustup default stable-msvc`), plus Visual Studio 2022 Build
  Tools with "Desktop development with C++" and a Windows 11 SDK. The SDK provides `rc.exe` (GPUI
  embeds a manifest) and `fxc.exe` (a release build of GPUI compiles its HLSL with it; debug
  builds compile the shaders at runtime instead).
- Godot 4.7.2 for Windows on ARM64 (or x86_64 on an Intel/AMD machine). Put `godot.exe` on
  `PATH` or set `$env:GODOT_BIN = "C:\path\to\Godot_v4.7.2-stable_windows_arm64.exe"`.
  Use the console build (`*_console.exe`) if you want Godot's output in the terminal.
- For the debug layers: the "Graphics Tools" optional feature
  (`dism /online /add-capability /capabilityname:Tools.Graphics.DirectX~~~~0.0.1.0`, admin).
- Optional: Sysinternals DebugView, to see D3D11 debug-layer output from GPUI debug builds
  (GPUI enables the D3D11 debug device in debug builds when Graphics Tools is installed, and that
  output goes to `OutputDebugString`).

All commands run in PowerShell from `apps\comp-gpui`.

### Checklist

1. **Cross-process sharing on this GPU.**

   ```powershell
   cargo run -p probes --bin win_share_probe
   ```

   Expected (names, pid and LUID vary):

   ```text
   producer adapter=Qualcomm(R) Adreno(TM) ... luid=00000000:0000abcd
   producer fence=1 completed=1
   producer shared name=Local\pwrup-p1234-v0-g1-s0
   consumer adapter=Qualcomm(R) Adreno(TM) ... luid=00000000:0000abcd
   consumer opened 64x64 format=28 misc=0x...
   pixel=ff0000ff
   ```

   Exit code 0. Look for: the two LUIDs match (D3D12 picks the default adapter, GPUI the first
   `EnumAdapters` entry; a mismatch means sharing will fail or be slow); `format=28` is
   `DXGI_FORMAT_R8G8B8A8_UNORM`. `pixel=00000000` means the clear never reached the texture;
   an `OpenSharedResourceByName` error means the driver cannot share D3D12 textures with D3D11.

   Then with both debug layers:

   ```powershell
   cargo run -p probes --bin win_share_probe -- --debug-layer
   ```

   Expect `producer d3d12 debug messages=0` and `consumer d3d11 debug messages=0`, or only
   `[D3D12_MESSAGE_SEVERITY_INFO]` lines. Any `CORRUPTION`, `ERROR` or `WARNING` about resource
   state, `ALLOW_SIMULTANEOUS_ACCESS` or shared handles must be fixed before going further: the
   probe creates the texture exactly like the bridge's legacy-barrier path.

2. **Build.**

   ```powershell
   cargo build --release -p godot-bridge -p host
   ```

   Expect `target\release\godot_bridge.dll` and `target\release\host.exe`. If the host build
   fails in `gpui-pre-windows`'s build script, `fxc.exe` was not found: install the Windows SDK
   (a debug `cargo build -p host` skips fxc). The host copies `godot_bridge.dll` from its own
   profile directory into `godot\bin\`, which `bridge.gdextension` loads for both arm64 and
   x86_64. Godot locks that copy while it runs, so close the host before starting a rebuilt one.
   The launch hook is macOS only and is not needed here.

3. **GPUI side alone.**

   ```powershell
   cargo run --release -p host -- --test-pattern
   ```

   Expect a window with a red/green gradient and a moving white bar, rounded corners, the
   drawer sliding over it when toggled, and the overlay reading
   `source test pattern (host D3D11 shared texture)` with host fps near the display refresh.
   A blank viewport means GPUI could not open the texture: errors go to stderr as
   `[ERROR ...] opening shared texture Local\pwrup-host-test-<pid>: ...` (set
   `$env:RUST_LOG="debug"` for more).

4. **Godot views.**

   ```powershell
   cd tools\models; npm ci; node decode.mjs; cd ..\..
   cargo run --release -p host
   ```

   The models are the same as on macOS (see [Running](#running)). The first run does a
   `godot --headless --import` pass (it writes `godot\.godot`; delete that directory if the import
   ran before `godot_bridge.dll` existed). Expect "waiting for Godot..." until the models load,
   then the robot under the drawer and the field minimap inset, overlay `producer fps` near 120,
   `godot cpu ms` (from `GetThreadTimes`) and `gpu ms (submit to fence)`, and
   `frame age at paint ms` (there is no present observer on Windows). Drag and scroll on the
   robot view should orbit and zoom it. Look for: no Godot window and no
   Godot taskbar button at any point (a brief flash at launch is a known risk), the host keeps
   focus, `Get-Process godot*` shows one process, and it exits when the host closes.

5. **D3D12 debug layer on the imported textures.**

   ```powershell
   $env:GODOT_ARGS = "--gpu-validation --verbose"
   cargo run --release -p host
   Remove-Item Env:GODOT_ARGS
   ```

   `--gpu-validation` turns on Godot's D3D12 debug layer; with the console Godot build its
   messages print in this terminal. The bridge prints
   `bridge: d3d12 enhanced_barriers=<true|false> slots start in <COMMON|RENDER_TARGET>` once per
   ring. Look for errors naming a `RESOURCE_STATE`, `BARRIER_LAYOUT`, `CopyTextureRegion` or
   `ResourceBarrier` on the shared slots: those mean the bridge's initial state does not match
   what Godot's driver assumed (see "How it fits together"), and switching the slot between
   `RENDER_TARGET` and `COMMON` in `initial_state_for_godot` is the first thing to try.
   Also run the debug host (`cargo run -p host`) with DebugView open to catch D3D11 messages
   from GPUI sampling the textures.

6. **Real load and displays.** Move the window between the laptop panel and the external
   display, resize it, and note fps and frame age at 1920x1080 and at 1920x515 (the driver
   station strip; `--kiosk` sizes the window to exactly 1920x515 device px). Then end Godot from
   Task Manager: the host should keep showing the last frame (GPUI keeps the opened texture while
   it is painted), the overlay should count a restart, and the views should resume once the new
   Godot has loaded its models. The new process names its textures with its own pid, so GPUI
   opens fresh ones. Also try `--second-window`.

### Known gaps

- Only `cargo check` was run for Windows targets. A cross `cargo check --release` stops in
  `gpui-pre-windows` because its build script only compiles the HLSL with `fxc.exe` when the
  build machine is Windows (`couldn't find file .../out/shaders_bytes.rs`); that is expected
  and works on the laptop. The cross check also needed a stand-in for `llvm-rc`, since
  `gpui-pre`'s build script embeds a Windows manifest; on Windows it uses the SDK's `rc.exe`.
- No present observer: frame age and input latency are measured at paint, not at present.
- No launch hook: Godot quits when the host's socket closes, but one whose script failed to
  load, or that is still loading models, does not notice and can outlive a crashed host. A Job
  object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` would close that gap.
- The test pattern is written from the host's own D3D11 device with no keyed mutex, so it can
  tear. Godot frames are fenced before the host sees them and need no cross-device sync.
