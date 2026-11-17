// UNTESTED: written on macOS and only type-checked for aarch64-pc-windows-msvc.

use std::ffi::c_void;
use std::sync::mpsc;

use godot::classes::DisplayServer;
use godot::classes::display_server::HandleType;
use godot::prelude::*;
use windows::Win32::Foundation::FILETIME;
use windows::Win32::Foundation::{CloseHandle, GENERIC_ALL, HANDLE, HWND};
use windows::Win32::Graphics::Direct3D12::{
    D3D12_FEATURE_D3D12_OPTIONS12, D3D12_FEATURE_DATA_D3D12_OPTIONS12, D3D12_FENCE_FLAG_NONE,
    D3D12_HEAP_FLAG_SHARED, D3D12_HEAP_PROPERTIES, D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_DESC,
    D3D12_RESOURCE_DIMENSION_TEXTURE2D, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
    D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS, D3D12_RESOURCE_STATE_COMMON,
    D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATES, D3D12_TEXTURE_LAYOUT_UNKNOWN,
    ID3D12CommandQueue, ID3D12Device, ID3D12Fence, ID3D12Resource,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::System::Threading::{
    CreateEventW, GetCurrentThread, GetThreadTimes, INFINITE, WaitForSingleObject,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GWL_EXSTYLE, GetWindowLongPtrW, IsWindowVisible, SW_HIDE, SetWindowLongPtrW, ShowWindow,
    WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
};
use windows::core::{HSTRING, Interface};

pub struct SharedSlot {
    resource: ID3D12Resource,
    handle: HANDLE,
}

impl SharedSlot {
    /// The ID3D12Resource pointer texture_create_from_extension imports.
    pub fn native_handle(&self) -> u64 {
        self.resource.as_raw() as u64
    }
}

impl Drop for SharedSlot {
    fn drop(&mut self) {
        let _ = unsafe { CloseHandle(self.handle) };
    }
}

type Job = Box<dyn FnOnce() + Send>;

struct FenceWaiter {
    fence: ID3D12Fence,
    value: u64,
    jobs: mpsc::Sender<(u64, Job)>,
}

struct SendFence(ID3D12Fence);

// Safety: ID3D12Fence is free-threaded.
unsafe impl Send for SendFence {}

impl FenceWaiter {
    fn new(device: &ID3D12Device) -> windows::core::Result<Self> {
        let fence: ID3D12Fence = unsafe { device.CreateFence(0, D3D12_FENCE_FLAG_NONE) }?;
        let (jobs, pending) = mpsc::channel::<(u64, Job)>();
        let waiter_fence = SendFence(fence.clone());
        std::thread::Builder::new()
            .name("bridge-fence".into())
            .spawn(move || {
                let waiter_fence = waiter_fence;
                let Ok(event) = (unsafe { CreateEventW(None, false, false, None) }) else {
                    return;
                };
                for (value, job) in pending {
                    unsafe {
                        if waiter_fence.0.GetCompletedValue() < value
                            && waiter_fence.0.SetEventOnCompletion(value, event).is_ok()
                        {
                            WaitForSingleObject(event, INFINITE);
                        }
                    }
                    job();
                }
                let _ = unsafe { CloseHandle(event) };
            })
            .ok();
        Ok(Self {
            fence,
            value: 0,
            jobs,
        })
    }

    fn signal(&mut self, queue: &ID3D12CommandQueue) -> Option<u64> {
        self.value += 1;
        unsafe { queue.Signal(&self.fence, self.value) }.ok()?;
        Some(self.value)
    }

    fn notify(&mut self, queue: &ID3D12CommandQueue, job: Job) -> bool {
        let Some(value) = self.signal(queue) else {
            return false;
        };
        self.jobs.send((value, job)).is_ok()
    }

    fn wait_idle(&mut self, queue: &ID3D12CommandQueue) {
        if let Some(value) = self.signal(queue) {
            // A null event makes SetEventOnCompletion block until the fence reaches the value.
            let _ = unsafe { self.fence.SetEventOnCompletion(value, HANDLE::default()) };
        }
    }
}

#[derive(Default)]
pub struct WinState {
    device: Option<ID3D12Device>,
    queue: Option<ID3D12CommandQueue>,
    fence: Option<FenceWaiter>,
    retired: Vec<SharedSlot>,
}

impl WinState {
    /// Allocates a ring of named shared textures on Godot's D3D12 device, or returns None after
    /// logging why it failed. The caller keeps the returned slots alive, and the generation they
    /// replace, until the next call for the same view.
    ///
    /// # Safety
    /// `device_handle` and `queue_handle` are Godot's DRIVER_RESOURCE_LOGICAL_DEVICE and
    /// DRIVER_RESOURCE_COMMAND_QUEUE, which outlive the bridge.
    #[allow(clippy::too_many_arguments)]
    pub unsafe fn create_slots(
        &mut self,
        device_handle: u64,
        queue_handle: u64,
        view: u32,
        generation: u32,
        width: u32,
        height: u32,
        count: u32,
    ) -> Option<Vec<SharedSlot>> {
        if self.device.is_none() {
            let device = unsafe { borrow_interface::<ID3D12Device>(device_handle) };
            let queue = unsafe { borrow_interface::<ID3D12CommandQueue>(queue_handle) };
            let (Some(device), Some(queue)) = (device, queue) else {
                godot_error!("bridge: RenderingDevice is not D3D12; the Vulkan path is not built");
                return None;
            };
            match FenceWaiter::new(&device) {
                Ok(fence) => self.fence = Some(fence),
                Err(error) => {
                    godot_error!("bridge: CreateFence failed: {error}");
                    return None;
                }
            }
            self.device = Some(device);
            self.queue = Some(queue);
        }
        let device = self.device.clone()?;
        let initial_state = initial_state_for_godot(&device);

        let pid = std::process::id();
        let mut slots = Vec::with_capacity(count as usize);
        for slot in 0..count {
            let name = protocol::shared_texture::windows_slot_name(pid, view, generation, slot);
            match create_slot(&device, width, height, initial_state, &name) {
                Ok(shared) => slots.push(shared),
                Err(error) => {
                    godot_error!("bridge: shared texture {name} failed: {error}");
                    return None;
                }
            }
        }

        // Godot's texture_free never releases an imported ID3D12Resource, so the bridge owns
        // them. A generation's RIDs are freed by script only after the next ring exists, so its
        // textures are kept until the ring after that one, once the queue has drained.
        if let (Some(fence), Some(queue)) = (self.fence.as_mut(), self.queue.as_ref()) {
            fence.wait_idle(queue);
        }
        self.retired.clear();
        Some(slots)
    }

    /// Keeps a closed view's slots until the next ring is created, by which time the script has
    /// freed their RIDs and the queue has drained.
    pub fn retire(&mut self, slots: impl IntoIterator<Item = SharedSlot>) {
        self.retired.extend(slots);
    }

    /// Signals Godot's queue after everything submitted so far and runs `on_complete` on the
    /// fence thread once the GPU reaches it.
    pub fn notify_when_queue_drains(
        &mut self,
        on_complete: impl FnOnce() + Send + 'static,
    ) -> bool {
        let (Some(fence), Some(queue)) = (self.fence.as_mut(), self.queue.as_ref()) else {
            return false;
        };
        fence.notify(queue, Box::new(on_complete))
    }
}

impl Drop for WinState {
    fn drop(&mut self) {
        if let (Some(fence), Some(queue)) = (self.fence.as_mut(), self.queue.as_ref()) {
            fence.wait_idle(queue);
        }
    }
}

// Godot 4.7.2's D3D12 driver (texture_create_from_extension) records an imported texture as
// being in RENDER_TARGET state and, with legacy barriers, transitions it from there before the
// first copy. With enhanced barriers it skips barriers on ALLOW_SIMULTANEOUS_ACCESS textures
// altogether, so the texture has to start in COMMON and rely on implicit promotion.
fn initial_state_for_godot(device: &ID3D12Device) -> D3D12_RESOURCE_STATES {
    let mut options = D3D12_FEATURE_DATA_D3D12_OPTIONS12::default();
    let enhanced = unsafe {
        device.CheckFeatureSupport(
            D3D12_FEATURE_D3D12_OPTIONS12,
            (&mut options as *mut D3D12_FEATURE_DATA_D3D12_OPTIONS12).cast(),
            size_of::<D3D12_FEATURE_DATA_D3D12_OPTIONS12>() as u32,
        )
    }
    .is_ok()
        && options.EnhancedBarriersSupported.as_bool();
    let state = if enhanced {
        D3D12_RESOURCE_STATE_COMMON
    } else {
        D3D12_RESOURCE_STATE_RENDER_TARGET
    };
    godot_print!(
        "bridge: d3d12 enhanced_barriers={enhanced} slots start in {}",
        if enhanced { "COMMON" } else { "RENDER_TARGET" }
    );
    state
}

fn create_slot(
    device: &ID3D12Device,
    width: u32,
    height: u32,
    initial_state: D3D12_RESOURCE_STATES,
    name: &str,
) -> windows::core::Result<SharedSlot> {
    let mut resource: Option<ID3D12Resource> = None;
    unsafe {
        device.CreateCommittedResource(
            &D3D12_HEAP_PROPERTIES {
                Type: D3D12_HEAP_TYPE_DEFAULT,
                ..Default::default()
            },
            D3D12_HEAP_FLAG_SHARED,
            &D3D12_RESOURCE_DESC {
                Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D,
                Width: width as u64,
                Height: height,
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
            initial_state,
            None,
            &mut resource,
        )?;
    }
    let resource = resource.ok_or_else(windows::core::Error::empty)?;
    let handle =
        unsafe { device.CreateSharedHandle(&resource, None, GENERIC_ALL.0, &HSTRING::from(name)) }?;
    Ok(SharedSlot { resource, handle })
}

unsafe fn borrow_interface<T: Interface + Clone>(handle: u64) -> Option<T> {
    let raw = handle as *mut c_void;
    unsafe { T::from_raw_borrowed(&raw) }.cloned()
}

/// Hides Godot's window and keeps it off the taskbar. Rendering does not depend on it: the
/// render loop is off and the script calls force_draw.
pub fn hide_window() {
    let handle = DisplayServer::singleton().window_get_native_handle(HandleType::WINDOW_HANDLE);
    let hwnd = HWND(handle as *mut c_void);
    if hwnd.is_invalid() {
        return;
    }
    unsafe {
        let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let wanted = (style | WS_EX_TOOLWINDOW.0 as isize) & !(WS_EX_APPWINDOW.0 as isize);
        if style != wanted {
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, wanted);
        }
        if IsWindowVisible(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
    }
}

/// User plus kernel CPU time of the calling thread.
pub fn thread_cpu_us() -> i64 {
    let mut times = [FILETIME::default(); 4];
    let [creation, exit, kernel, user] = &mut times;
    if unsafe { GetThreadTimes(GetCurrentThread(), creation, exit, kernel, user) }.is_err() {
        return 0;
    }
    let ticks = |t: &FILETIME| (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime);
    ((ticks(kernel) + ticks(user)) / 10) as i64
}
