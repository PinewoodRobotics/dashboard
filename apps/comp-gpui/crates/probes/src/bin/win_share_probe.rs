// UNTESTED: written on macOS and only type-checked for aarch64-pc-windows-msvc.

#[cfg(not(windows))]
fn main() {
    eprintln!("win_share_probe is Windows only");
}

#[cfg(windows)]
fn main() -> anyhow::Result<()> {
    win::run()
}

#[cfg(windows)]
mod win {
    use std::process::Command;

    use anyhow::{Context, Result, bail};
    use windows::Win32::Foundation::{CloseHandle, GENERIC_ALL, HANDLE, HMODULE, LUID};
    use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_11_0};
    use windows::Win32::Graphics::Direct3D11::{
        D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_CREATE_DEVICE_DEBUG,
        D3D11_MAP_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_MESSAGE, D3D11_SDK_VERSION,
        D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING, D3D11CreateDevice, ID3D11Device,
        ID3D11Device1, ID3D11DeviceContext, ID3D11InfoQueue, ID3D11Texture2D,
    };
    use windows::Win32::Graphics::Direct3D12::{
        D3D12_COMMAND_LIST_TYPE_DIRECT, D3D12_COMMAND_QUEUE_DESC, D3D12_DESCRIPTOR_HEAP_DESC,
        D3D12_DESCRIPTOR_HEAP_TYPE_RTV, D3D12_FENCE_FLAG_NONE, D3D12_HEAP_FLAG_SHARED,
        D3D12_HEAP_PROPERTIES, D3D12_HEAP_TYPE_DEFAULT, D3D12_MESSAGE,
        D3D12_RESOURCE_DESC, D3D12_RESOURCE_DIMENSION_TEXTURE2D,
        D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS,
        D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12CreateDevice,
        D3D12GetDebugInterface, ID3D12CommandAllocator, ID3D12CommandList, ID3D12CommandQueue,
        ID3D12Debug, ID3D12DescriptorHeap, ID3D12Device, ID3D12Fence, ID3D12GraphicsCommandList,
        ID3D12InfoQueue, ID3D12PipelineState, ID3D12Resource,
    };
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC};
    use windows::Win32::Graphics::Dxgi::{
        CreateDXGIFactory2, DXGI_CREATE_FACTORY_FLAGS, DXGI_SHARED_RESOURCE_READ, IDXGIAdapter1,
        IDXGIFactory4,
    };
    use windows::Win32::System::Threading::{CreateEventW, INFINITE, WaitForSingleObject};
    use windows::core::{HSTRING, Interface};

    const SIZE: u32 = 64;

    pub fn run() -> Result<()> {
        let args: Vec<String> = std::env::args().skip(1).collect();
        let debug_layer = args.iter().any(|a| a == "--debug-layer");
        match args.iter().position(|a| a == "--consumer") {
            Some(index) => consume(args.get(index + 1).context("--consumer <name>")?, debug_layer),
            None => produce(debug_layer),
        }
    }

    fn produce(debug_layer: bool) -> Result<()> {
        unsafe {
            if debug_layer {
                let mut debug: Option<ID3D12Debug> = None;
                D3D12GetDebugInterface(&mut debug).context("D3D12 debug layer unavailable")?;
                debug.context("no ID3D12Debug")?.EnableDebugLayer();
            }
            let mut device: Option<ID3D12Device> = None;
            D3D12CreateDevice(None, D3D_FEATURE_LEVEL_11_0, &mut device)
                .context("D3D12CreateDevice")?;
            let device = device.context("no D3D12 device")?;
            println!(
                "producer adapter={} luid={}",
                adapter_name(device.GetAdapterLuid()),
                luid_string(device.GetAdapterLuid())
            );

            let queue: ID3D12CommandQueue = device.CreateCommandQueue(&D3D12_COMMAND_QUEUE_DESC {
                Type: D3D12_COMMAND_LIST_TYPE_DIRECT,
                ..Default::default()
            })?;
            let allocator: ID3D12CommandAllocator =
                device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT)?;
            let list: ID3D12GraphicsCommandList = device.CreateCommandList(
                0,
                D3D12_COMMAND_LIST_TYPE_DIRECT,
                &allocator,
                None::<&ID3D12PipelineState>,
            )?;

            // Same flags and initial state as the bridge's legacy-barrier path, which matches what
            // Godot's D3D12 driver assumes for an imported texture.
            let mut texture: Option<ID3D12Resource> = None;
            device
                .CreateCommittedResource(
                    &D3D12_HEAP_PROPERTIES {
                        Type: D3D12_HEAP_TYPE_DEFAULT,
                        ..Default::default()
                    },
                    D3D12_HEAP_FLAG_SHARED,
                    &D3D12_RESOURCE_DESC {
                        Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D,
                        Width: SIZE as u64,
                        Height: SIZE,
                        DepthOrArraySize: 1,
                        MipLevels: 1,
                        Format: DXGI_FORMAT_R8G8B8A8_UNORM,
                        SampleDesc: DXGI_SAMPLE_DESC {
                            Count: 1,
                            Quality: 0,
                        },
                        Layout: D3D12_TEXTURE_LAYOUT_UNKNOWN,
                        Flags: D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET
                            | D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS,
                        ..Default::default()
                    },
                    D3D12_RESOURCE_STATE_RENDER_TARGET,
                    None,
                    &mut texture,
                )
                .context("CreateCommittedResource (shared)")?;
            let texture = texture.context("no texture")?;

            let rtv_heap: ID3D12DescriptorHeap =
                device.CreateDescriptorHeap(&D3D12_DESCRIPTOR_HEAP_DESC {
                    Type: D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
                    NumDescriptors: 1,
                    ..Default::default()
                })?;
            let rtv = rtv_heap.GetCPUDescriptorHandleForHeapStart();
            device.CreateRenderTargetView(&texture, None, rtv);
            list.ClearRenderTargetView(rtv, &[1.0, 0.0, 0.0, 1.0], None);
            list.Close()?;
            queue.ExecuteCommandLists(&[Some(list.cast::<ID3D12CommandList>()?)]);

            let fence: ID3D12Fence = device.CreateFence(0, D3D12_FENCE_FLAG_NONE)?;
            queue.Signal(&fence, 1)?;
            let event = CreateEventW(None, false, false, None)?;
            fence.SetEventOnCompletion(1, event)?;
            WaitForSingleObject(event, INFINITE);
            CloseHandle(event)?;
            println!("producer fence=1 completed={}", fence.GetCompletedValue());

            let name = protocol::shared_texture::windows_slot_name(std::process::id(), 0, 1, 0);
            let handle: HANDLE = device
                .CreateSharedHandle(&texture, None, GENERIC_ALL.0, &HSTRING::from(&name))
                .context("CreateSharedHandle")?;
            println!("producer shared name={name}");

            let mut child = Command::new(std::env::current_exe()?);
            child.args(["--consumer", &name]);
            if debug_layer {
                child.arg("--debug-layer");
            }
            let status = child.status().context("spawning consumer")?;
            CloseHandle(handle)?;
            if debug_layer {
                print_d3d12_messages(&device);
            }
            if !status.success() {
                bail!("consumer failed: {status}");
            }
        }
        Ok(())
    }

    fn consume(name: &str, debug_layer: bool) -> Result<()> {
        unsafe {
            // GPUI renders on the first adapter EnumAdapters returns, so the probe does too.
            let factory: IDXGIFactory4 = CreateDXGIFactory2(DXGI_CREATE_FACTORY_FLAGS(0))?;
            let adapter: IDXGIAdapter1 = factory.EnumAdapters(0)?.cast()?;
            let desc = adapter.GetDesc1()?;
            println!(
                "consumer adapter={} luid={}",
                wide_to_string(&desc.Description),
                luid_string(desc.AdapterLuid)
            );
            let mut flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
            if debug_layer {
                flags |= D3D11_CREATE_DEVICE_DEBUG;
            }
            let mut device: Option<ID3D11Device> = None;
            let mut context: Option<ID3D11DeviceContext> = None;
            D3D11CreateDevice(
                &adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                flags,
                Some(&[D3D_FEATURE_LEVEL_11_0]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .context("D3D11CreateDevice")?;
            let device = device.context("no D3D11 device")?;
            let context = context.context("no D3D11 context")?;

            let device1: ID3D11Device1 = device.cast()?;
            let shared: ID3D11Texture2D = device1
                .OpenSharedResourceByName(&HSTRING::from(name), DXGI_SHARED_RESOURCE_READ.0)
                .with_context(|| format!("OpenSharedResourceByName({name})"))?;
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            shared.GetDesc(&mut desc);
            println!(
                "consumer opened {}x{} format={} misc=0x{:x}",
                desc.Width, desc.Height, desc.Format.0, desc.MiscFlags
            );

            let staging_desc = D3D11_TEXTURE2D_DESC {
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
                ..desc
            };
            let mut staging: Option<ID3D11Texture2D> = None;
            device.CreateTexture2D(&staging_desc, None, Some(&mut staging))?;
            let staging = staging.context("no staging texture")?;
            context.CopyResource(&staging, &shared);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
            let pixel = std::slice::from_raw_parts(mapped.pData as *const u8, 4).to_vec();
            context.Unmap(&staging, 0);

            let hex: String = pixel.iter().map(|b| format!("{b:02x}")).collect();
            println!("pixel={hex}");
            if debug_layer {
                print_d3d11_messages(&device);
            }
            if hex != "ff0000ff" {
                bail!("expected pixel=ff0000ff");
            }
        }
        Ok(())
    }

    fn adapter_name(luid: LUID) -> String {
        unsafe {
            let Ok(factory) = CreateDXGIFactory2::<IDXGIFactory4>(DXGI_CREATE_FACTORY_FLAGS(0))
            else {
                return "?".into();
            };
            factory
                .EnumAdapterByLuid::<IDXGIAdapter1>(luid)
                .and_then(|adapter| adapter.GetDesc1())
                .map(|desc| wide_to_string(&desc.Description))
                .unwrap_or_else(|_| "?".into())
        }
    }

    fn luid_string(luid: LUID) -> String {
        format!("{:08x}:{:08x}", luid.HighPart, luid.LowPart)
    }

    fn wide_to_string(wide: &[u16]) -> String {
        String::from_utf16_lossy(wide)
            .trim_end_matches('\0')
            .to_string()
    }

    unsafe fn message_text(text: *const u8, length: usize) -> String {
        let bytes = unsafe { std::slice::from_raw_parts(text, length) };
        String::from_utf8_lossy(bytes)
            .trim_end_matches('\0')
            .to_string()
    }

    fn print_d3d12_messages(device: &ID3D12Device) {
        let Ok(queue) = device.cast::<ID3D12InfoQueue>() else {
            println!("producer d3d12 debug messages unavailable");
            return;
        };
        unsafe {
            let count = queue.GetNumStoredMessages();
            println!("producer d3d12 debug messages={count}");
            for index in 0..count {
                let mut length = 0usize;
                if queue.GetMessage(index, None, &mut length).is_err() {
                    continue;
                }
                let mut storage = vec![0u64; length.div_ceil(8)];
                let message = storage.as_mut_ptr().cast::<D3D12_MESSAGE>();
                if queue.GetMessage(index, Some(message), &mut length).is_ok() {
                    let message = &*message;
                    println!(
                        "  [{:?}] {}",
                        message.Severity,
                        message_text(message.pDescription, message.DescriptionByteLength)
                    );
                }
            }
        }
    }

    fn print_d3d11_messages(device: &ID3D11Device) {
        let Ok(queue) = device.cast::<ID3D11InfoQueue>() else {
            println!("consumer d3d11 debug messages unavailable");
            return;
        };
        unsafe {
            let count = queue.GetNumStoredMessages();
            println!("consumer d3d11 debug messages={count}");
            for index in 0..count {
                let mut length = 0usize;
                if queue.GetMessage(index, None, &mut length).is_err() {
                    continue;
                }
                let mut storage = vec![0u64; length.div_ceil(8)];
                let message = storage.as_mut_ptr().cast::<D3D11_MESSAGE>();
                if queue.GetMessage(index, Some(message), &mut length).is_ok() {
                    let message = &*message;
                    println!(
                        "  [{:?}] {}",
                        message.Severity,
                        message_text(message.pDescription, message.DescriptionByteLength)
                    );
                }
            }
        }
    }
}
