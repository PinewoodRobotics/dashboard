use std::ptr::{self, NonNull};

use anyhow::{Context, Result, bail};
use objc2_core_foundation::{CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType};
use objc2_core_video::{
    CVAttachmentMode, CVPixelBuffer, CVPixelBufferCreateWithIOSurface, kCVReturnSuccess,
};
use objc2_io_surface::{
    IOSurfaceLockOptions, IOSurfaceRef, kIOSurfaceBytesPerElement, kIOSurfaceHeight,
    kIOSurfacePixelFormat, kIOSurfaceWidth,
};

pub const FOURCC_BGRA: u32 = u32::from_be_bytes(*b"BGRA");

// Must match SURFACE_BYTES_ARE_RGBA_ATTACHMENT in vendor/gpui-pre-apple.
const BYTES_ARE_RGBA_ATTACHMENT: &str = "GPUISurfaceBytesAreRGBA";

pub(crate) fn create_bgra_surface(width: usize, height: usize) -> Result<CFRetained<IOSurfaceRef>> {
    let width = CFNumber::new_i32(width as i32);
    let height = CFNumber::new_i32(height as i32);
    let bytes_per_element = CFNumber::new_i32(4);
    let format = CFNumber::new_i32(FOURCC_BGRA as i32);
    let keys: [&CFString; 4] = unsafe {
        [
            kIOSurfaceWidth,
            kIOSurfaceHeight,
            kIOSurfaceBytesPerElement,
            kIOSurfacePixelFormat,
        ]
    };
    let values: [&CFType; 4] = [&width, &height, &bytes_per_element, &format];
    let properties = CFDictionary::from_slices(&keys, &values);
    unsafe { IOSurfaceRef::new(properties.as_opaque()) }.context("IOSurfaceCreate failed")
}

pub(crate) fn lookup_surface(id: u32) -> Result<CFRetained<IOSurfaceRef>> {
    IOSurfaceRef::lookup(id).with_context(|| format!("IOSurfaceLookup({id}) failed"))
}

pub(crate) fn pixel_buffer(
    surface: &IOSurfaceRef,
    bytes_are_rgba: bool,
) -> Result<CFRetained<CVPixelBuffer>> {
    let mut buffer: *mut CVPixelBuffer = ptr::null_mut();
    let status = unsafe {
        CVPixelBufferCreateWithIOSurface(None, surface, None, NonNull::from(&mut buffer))
    };
    if status != kCVReturnSuccess {
        bail!("CVPixelBufferCreateWithIOSurface status {status}");
    }
    let buffer =
        unsafe { CFRetained::from_raw(NonNull::new(buffer).context("null pixel buffer")?) };
    if bytes_are_rgba {
        let key = CFString::from_static_str(BYTES_ARE_RGBA_ATTACHMENT);
        unsafe {
            buffer.set_attachment(
                &key,
                CFBoolean::new(true),
                CVAttachmentMode::ShouldNotPropagate,
            )
        };
    }
    Ok(buffer)
}

pub(crate) fn write_bgra(surface: &IOSurfaceRef, mut fill: impl FnMut(usize, usize) -> [u8; 4]) {
    unsafe {
        surface.lock(IOSurfaceLockOptions::empty(), ptr::null_mut());
        let base = surface.base_address().as_ptr().cast::<u8>();
        let row = surface.bytes_per_row();
        for y in 0..surface.height() {
            let line = base.add(y * row);
            for x in 0..surface.width() {
                let pixel = fill(x, y);
                ptr::copy_nonoverlapping(pixel.as_ptr(), line.add(x * 4), 4);
            }
        }
        surface.unlock(IOSurfaceLockOptions::empty(), ptr::null_mut());
    }
}
