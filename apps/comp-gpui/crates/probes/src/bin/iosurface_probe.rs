#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("iosurface_probe is macOS only");
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    mac::run()
}

#[cfg(target_os = "macos")]
mod mac {
    use std::ptr::{self, NonNull};

    use anyhow::{Context, Result, bail};
    use objc2::rc::Retained;
    use objc2::runtime::ProtocolObject;
    use objc2_core_foundation::{CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType};
    use objc2_core_video::{
        CVPixelBuffer, CVPixelBufferCreateWithIOSurface, CVPixelBufferGetBaseAddress,
        CVPixelBufferGetPixelFormatType, CVPixelBufferLockBaseAddress, CVPixelBufferLockFlags,
        CVPixelBufferUnlockBaseAddress, kCVReturnSuccess,
    };
    use objc2_io_surface::{
        IOSurfaceLockOptions, IOSurfaceRef, kIOSurfaceBytesPerElement, kIOSurfaceHeight,
        kIOSurfacePixelFormat, kIOSurfaceWidth,
    };
    use objc2_metal::{
        MTLBlitCommandEncoder, MTLClearColor, MTLCommandBuffer, MTLCommandBufferStatus,
        MTLCommandEncoder, MTLCommandQueue, MTLCreateSystemDefaultDevice, MTLDevice, MTLLoadAction,
        MTLPixelFormat, MTLRenderPassDescriptor, MTLStorageMode, MTLStoreAction, MTLTexture,
        MTLTextureDescriptor, MTLTextureUsage,
    };

    const SIZE: usize = 64;
    const FOURCC_BGRA: u32 = u32::from_be_bytes(*b"BGRA");
    const FOURCC_RGBA: u32 = u32::from_be_bytes(*b"RGBA");

    pub fn run() -> Result<()> {
        let args: Vec<String> = std::env::args().collect();
        if args.get(1).map(String::as_str) == Some("--child") {
            let ids: Vec<u32> = args[2..]
                .iter()
                .map(|a| a.parse())
                .collect::<Result<_, _>>()?;
            return child(ids[0], ids[1], ids[2]);
        }
        parent()
    }

    #[allow(deprecated)]
    fn create_global_surface(fourcc: u32) -> Result<CFRetained<IOSurfaceRef>> {
        let width = CFNumber::new_i32(SIZE as i32);
        let height = CFNumber::new_i32(SIZE as i32);
        let bpe = CFNumber::new_i32(4);
        let format = CFNumber::new_i32(fourcc as i32);
        // kIOSurfaceIsGlobal is deprecated but still the only way to make IOSurfaceLookup(id) work cross-process.
        let global = unsafe { objc2_io_surface::kIOSurfaceIsGlobal };
        let keys: [&CFString; 5] = unsafe {
            [
                kIOSurfaceWidth,
                kIOSurfaceHeight,
                kIOSurfaceBytesPerElement,
                kIOSurfacePixelFormat,
                global,
            ]
        };
        let values: [&CFType; 5] = [&width, &height, &bpe, &format, CFBoolean::new(true)];
        let props = CFDictionary::from_slices(&keys, &values);
        unsafe { IOSurfaceRef::new(props.as_opaque()) }.context("IOSurfaceCreate failed")
    }

    fn parent() -> Result<()> {
        let rgba = create_global_surface(FOURCC_RGBA)?;
        let bgra = create_global_surface(FOURCC_BGRA)?;
        let tagged = create_global_surface(FOURCC_BGRA)?;
        let exe = std::env::current_exe()?;
        let ids = [&rgba, &bgra, &tagged].map(|s| s.id().to_string());
        let status = std::process::Command::new(exe)
            .arg("--child")
            .args(ids)
            .status()?;
        if !status.success() {
            bail!("child failed: {status}");
        }
        for (name, surface) in [
            ("rgba8", &rgba),
            ("bgra8", &bgra),
            ("rgba8-in-bgra-tagged", &tagged),
        ] {
            match read_via_pixel_buffer(surface) {
                Ok((format, pixel)) => println!(
                    "parent {name}: cvpixelbuffer=ok format={format:#x} pixel={pixel:02x?}"
                ),
                Err(error) => println!("parent {name}: cvpixelbuffer=err ({error})"),
            }
            println!(
                "parent {name}: iosurface pixel={:02x?}",
                read_via_lock(surface)
            );
        }
        Ok(())
    }

    fn read_via_pixel_buffer(surface: &IOSurfaceRef) -> Result<(u32, [u8; 4])> {
        let mut buffer: *mut CVPixelBuffer = ptr::null_mut();
        let status = unsafe {
            CVPixelBufferCreateWithIOSurface(None, surface, None, NonNull::from(&mut buffer))
        };
        if status != kCVReturnSuccess {
            bail!("CVPixelBufferCreateWithIOSurface status {status}");
        }
        let buffer = unsafe { CFRetained::from_raw(NonNull::new(buffer).context("null buffer")?) };
        let format = CVPixelBufferGetPixelFormatType(&buffer);
        unsafe {
            CVPixelBufferLockBaseAddress(&buffer, CVPixelBufferLockFlags::ReadOnly);
            let base = CVPixelBufferGetBaseAddress(&buffer).cast::<u8>();
            let mut pixel = [0u8; 4];
            ptr::copy_nonoverlapping(base, pixel.as_mut_ptr(), 4);
            CVPixelBufferUnlockBaseAddress(&buffer, CVPixelBufferLockFlags::ReadOnly);
            Ok((format, pixel))
        }
    }

    fn read_via_lock(surface: &IOSurfaceRef) -> [u8; 4] {
        let mut pixel = [0u8; 4];
        unsafe {
            surface.lock(IOSurfaceLockOptions::ReadOnly, ptr::null_mut());
            ptr::copy_nonoverlapping(
                surface.base_address().as_ptr().cast::<u8>(),
                pixel.as_mut_ptr(),
                4,
            );
            surface.unlock(IOSurfaceLockOptions::ReadOnly, ptr::null_mut());
        }
        pixel
    }

    fn surface_texture(
        device: &ProtocolObject<dyn MTLDevice>,
        surface: &IOSurfaceRef,
        format: MTLPixelFormat,
    ) -> Option<Retained<ProtocolObject<dyn MTLTexture>>> {
        let desc = MTLTextureDescriptor::new();
        unsafe {
            desc.setWidth(SIZE);
            desc.setHeight(SIZE);
        }
        desc.setPixelFormat(format);
        desc.setStorageMode(MTLStorageMode::Shared);
        desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
        device.newTextureWithDescriptor_iosurface_plane(&desc, surface, 0)
    }

    fn child(rgba_id: u32, bgra_id: u32, tagged_id: u32) -> Result<()> {
        let rgba = IOSurfaceRef::lookup(rgba_id);
        let bgra = IOSurfaceRef::lookup(bgra_id);
        let tagged = IOSurfaceRef::lookup(tagged_id);
        let ok = rgba.is_some() && bgra.is_some() && tagged.is_some();
        println!("child lookup={}", if ok { "ok" } else { "err" });
        let (Some(rgba), Some(bgra), Some(tagged)) = (rgba, bgra, tagged) else {
            bail!("IOSurfaceLookup failed");
        };
        let device = MTLCreateSystemDefaultDevice().context("no Metal device")?;
        let queue = device.newCommandQueue().context("no queue")?;

        let rgba_tex = surface_texture(&device, &rgba, MTLPixelFormat::RGBA8Unorm);
        println!(
            "child rgba8 wrap={}",
            if rgba_tex.is_some() { "ok" } else { "err" }
        );
        let bgra_tex = surface_texture(&device, &bgra, MTLPixelFormat::BGRA8Unorm);
        println!(
            "child bgra8 wrap={}",
            if bgra_tex.is_some() { "ok" } else { "err" }
        );

        let tagged_tex = surface_texture(&device, &tagged, MTLPixelFormat::RGBA8Unorm);
        println!(
            "child rgba8-in-bgra-tagged wrap={}",
            if tagged_tex.is_some() { "ok" } else { "err" }
        );

        let cmd = queue.commandBuffer().context("no command buffer")?;
        for rgba_tex in rgba_tex.iter().chain(tagged_tex.iter()) {
            let desc = MTLTextureDescriptor::new();
            unsafe {
                desc.setWidth(SIZE);
                desc.setHeight(SIZE);
            }
            desc.setPixelFormat(MTLPixelFormat::RGBA8Unorm);
            desc.setStorageMode(MTLStorageMode::Private);
            desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
            let source = device
                .newTextureWithDescriptor(&desc)
                .context("source tex")?;
            clear(&cmd, &source)?;
            let blit = cmd.blitCommandEncoder().context("blit")?;
            unsafe { blit.copyFromTexture_toTexture(&source, rgba_tex) };
            blit.endEncoding();
        }
        if let Some(bgra_tex) = &bgra_tex {
            clear(&cmd, bgra_tex)?;
        }
        cmd.commit();
        cmd.waitUntilCompleted();
        println!(
            "child commands={}",
            if cmd.status() == MTLCommandBufferStatus::Completed {
                "ok"
            } else {
                "err"
            }
        );
        Ok(())
    }

    fn clear(
        cmd: &ProtocolObject<dyn MTLCommandBuffer>,
        texture: &ProtocolObject<dyn MTLTexture>,
    ) -> Result<()> {
        let pass = MTLRenderPassDescriptor::new();
        let attachment = unsafe { pass.colorAttachments().objectAtIndexedSubscript(0) };
        attachment.setTexture(Some(texture));
        attachment.setLoadAction(MTLLoadAction::Clear);
        attachment.setStoreAction(MTLStoreAction::Store);
        attachment.setClearColor(MTLClearColor {
            red: 1.0,
            green: 0.0,
            blue: 0.0,
            alpha: 1.0,
        });
        let encoder = cmd
            .renderCommandEncoderWithDescriptor(&pass)
            .context("encoder")?;
        encoder.endEncoding();
        Ok(())
    }
}
