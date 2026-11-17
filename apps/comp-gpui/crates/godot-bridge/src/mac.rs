use std::ptr::NonNull;

use block2::RcBlock;
use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_app_kit::{
    NSApplication, NSApplicationActivationOptions, NSApplicationActivationPolicy,
    NSRunningApplication,
};
use objc2_core_foundation::{CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType};
use objc2_io_surface::{
    IOSurfaceRef, kIOSurfaceBytesPerElement, kIOSurfaceHeight, kIOSurfacePixelFormat,
    kIOSurfaceWidth,
};
use objc2_metal::{
    MTLCommandBuffer, MTLCommandQueue, MTLDevice, MTLPixelFormat, MTLStorageMode,
    MTLTextureDescriptor, MTLTextureUsage,
};

const FOURCC_BGRA: u32 = u32::from_be_bytes(*b"BGRA");

pub struct SharedSlot {
    pub surface: CFRetained<IOSurfaceRef>,
    pub native_handle: u64,
}

impl SharedSlot {
    pub fn id(&self) -> u32 {
        self.surface.id()
    }
}

// Safety: the caller passes Godot's DRIVER_RESOURCE_LOGICAL_DEVICE handle, an id<MTLDevice>
// that outlives the bridge.
pub unsafe fn device_from_handle(handle: u64) -> Option<Retained<ProtocolObject<dyn MTLDevice>>> {
    unsafe { Retained::retain(handle as *mut ProtocolObject<dyn MTLDevice>) }
}

// Safety: as above, for DRIVER_RESOURCE_COMMAND_QUEUE.
pub unsafe fn queue_from_handle(
    handle: u64,
) -> Option<Retained<ProtocolObject<dyn MTLCommandQueue>>> {
    unsafe { Retained::retain(handle as *mut ProtocolObject<dyn MTLCommandQueue>) }
}

// Godot's viewport textures are RGBA8, but CoreVideo refuses 'RGBA' IOSurfaces, so the surface
// is tagged 'BGRA' and the host marks its CVPixelBuffer as holding RGBA bytes. kIOSurfaceIsGlobal
// is deprecated, yet it is what lets the host resolve the id with IOSurfaceLookup.
#[allow(deprecated)]
pub fn create_slot(
    device: &ProtocolObject<dyn MTLDevice>,
    width: usize,
    height: usize,
) -> Option<SharedSlot> {
    let w = CFNumber::new_i32(width as i32);
    let h = CFNumber::new_i32(height as i32);
    let bpe = CFNumber::new_i32(4);
    let format = CFNumber::new_i32(FOURCC_BGRA as i32);
    let keys: [&CFString; 5] = unsafe {
        [
            kIOSurfaceWidth,
            kIOSurfaceHeight,
            kIOSurfaceBytesPerElement,
            kIOSurfacePixelFormat,
            objc2_io_surface::kIOSurfaceIsGlobal,
        ]
    };
    let values: [&CFType; 5] = [&w, &h, &bpe, &format, CFBoolean::new(true)];
    let properties = CFDictionary::from_slices(&keys, &values);
    let surface = unsafe { IOSurfaceRef::new(properties.as_opaque()) }?;

    let desc = MTLTextureDescriptor::new();
    unsafe {
        desc.setWidth(width);
        desc.setHeight(height);
    }
    desc.setPixelFormat(MTLPixelFormat::RGBA8Unorm);
    desc.setStorageMode(MTLStorageMode::Shared);
    desc.setUsage(MTLTextureUsage::ShaderRead | MTLTextureUsage::RenderTarget);
    let texture = device.newTextureWithDescriptor_iosurface_plane(&desc, &surface, 0)?;
    // Godot's texture_create_from_extension adopts this reference without retaining it and
    // releases it in texture_free, so the +1 is handed over rather than kept here.
    let native_handle = Retained::into_raw(texture) as *const () as u64;
    Some(SharedSlot {
        surface,
        native_handle,
    })
}

pub fn notify_when_queue_drains(
    queue: &ProtocolObject<dyn MTLCommandQueue>,
    on_complete: impl Fn() + 'static,
) -> bool {
    let Some(command_buffer) = queue.commandBuffer() else {
        return false;
    };
    let block = RcBlock::new(move |_: NonNull<ProtocolObject<dyn MTLCommandBuffer>>| on_complete());
    unsafe { command_buffer.addCompletedHandler(RcBlock::as_ptr(&block)) };
    command_buffer.commit();
    true
}

pub fn hide_app_windows() {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let app = NSApplication::sharedApplication(mtm);
    // macOS activates the freshly launched Godot after its first frames. Under cooperative
    // activation the host cannot take focus back on its own, so while Godot is still the active
    // app it hands activation to the host, before dropping to a background policy.
    if app.isActive() {
        let host = NSRunningApplication::runningApplicationWithProcessIdentifier(unsafe {
            libc::getppid()
        });
        if let Some(host) = host {
            host.activateFromApplication_options(
                &NSRunningApplication::currentApplication(),
                NSApplicationActivationOptions::empty(),
            );
        }
    }
    if app.activationPolicy() != NSApplicationActivationPolicy::Accessory {
        app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
    }
    for window in app.windows().iter() {
        if window.isVisible() {
            window.orderOut(None);
        }
    }
}
