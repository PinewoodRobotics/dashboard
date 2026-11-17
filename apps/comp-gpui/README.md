# comp-gpui

GPUI driver-station UI. 3D views are rendered by a hidden Godot 4.7.2 child process and shown
through shared GPU textures: IOSurfaces on macOS, named D3D12 textures on Windows.

Crates: `protocol` (host/Godot messages over loopback TCP), `host` (GPUI test app with the 3D
viewport), `godot-bridge` (GDExtension: shared-texture ring, import, copy fence, window hiding),
`probes` (standalone sharing probes). `godot/` is the Godot project. GPUI crates patched for
shared surfaces are vendored in `vendor/`, with their diffs in `vendor/patches/`.

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
- `host/src/win/`: the Windows `viewport.rs` (names from the child pid) and `test_pattern.rs` (a
  host-owned D3D11 texture shared by name, so the test pattern goes through the same GPUI path).
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
   cargo build --release -p godot-bridge
   cargo build --release -p host
   ```

   Expect `target\release\godot_bridge.dll` and `target\release\host.exe`. If the host build
   fails in `gpui-pre-windows`'s build script, `fxc.exe` was not found: install the Windows SDK
   (a debug `cargo build -p host` skips fxc). `bridge.gdextension` loads
   `target\release\godot_bridge.dll` for both arm64 and x86_64. Godot locks the DLL while it
   runs, so close the host before rebuilding the bridge.

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

4. **Godot cube.**

   ```powershell
   cargo run --release -p host
   ```

   The first run does a `godot --headless --import` pass (it writes `godot\.godot`; delete that
   directory if the import ran before `godot_bridge.dll` existed). Expect the spinning orange cube
   under the drawer within a second or two, overlay `producer fps` near 120, `godot cpu ms` and
   `gpu ms (submit to fence)` a few ms, `frame age` a few ms. Look for: no Godot window and no
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
   station strip). Then end Godot from Task Manager: the host should keep showing the last frame
   (GPUI keeps the opened texture while it is painted). Respawn is not implemented yet on either
   platform.

### Known gaps

- Only `cargo check` was run for Windows targets. A cross `cargo check --release` stops in
  `gpui-pre-windows` because its build script only compiles the HLSL with `fxc.exe` when the
  build machine is Windows (`couldn't find file .../out/shaders_bytes.rs`); that is expected
  and works on the laptop. The cross check also needed a stand-in for `llvm-rc`, since
  `gpui-pre`'s build script embeds a Windows manifest; on Windows it uses the SDK's `rc.exe`.
- `host/src/win/viewport.rs` mirrors `host/src/viewport.rs` and will need the same changes as
  the macOS side gains pointer input, resize and multiple views.
- The test pattern is written from the host's own D3D11 device with no keyed mutex, so it can
  tear. Godot frames are fenced before the host sees them and need no cross-device sync.
