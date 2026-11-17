// UNTESTED: Windows counterpart of test_pattern.rs, only type-checked for aarch64-pc-windows-msvc.

use std::cell::RefCell;

use anyhow::{Context, Result};
use gpui_kit::{DevicePixels, SharedTexture, size};
use windows::Win32::Foundation::{CloseHandle, HANDLE, HMODULE};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL_11_0};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_SHADER_RESOURCE, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_RESOURCE_MISC_SHARED,
    D3D11_RESOURCE_MISC_SHARED_NTHANDLE, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_DEFAULT, D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    DXGI_SHARED_RESOURCE_READ, DXGI_SHARED_RESOURCE_WRITE, IDXGIResource1,
};
use windows::core::{HSTRING, Interface};

/// A host-written texture shared by name, so --test-pattern exercises the same
/// OpenSharedResourceByName path in GPUI that Godot's frames take.
pub struct TestPattern {
    context: ID3D11DeviceContext,
    texture: ID3D11Texture2D,
    handle: HANDLE,
    shared: SharedTexture,
    width: usize,
    height: usize,
    pixels: RefCell<Vec<u8>>,
}

impl TestPattern {
    pub fn new(width: usize, height: usize) -> Result<Self> {
        let mut device: Option<ID3D11Device> = None;
        let mut context: Option<ID3D11DeviceContext> = None;
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&[D3D_FEATURE_LEVEL_11_0]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
        }
        .context("D3D11CreateDevice")?;
        let device = device.context("no D3D11 device")?;
        let context = context.context("no D3D11 context")?;

        let desc = D3D11_TEXTURE2D_DESC {
            Width: width as u32,
            Height: height as u32,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: (D3D11_RESOURCE_MISC_SHARED.0 | D3D11_RESOURCE_MISC_SHARED_NTHANDLE.0)
                as u32,
        };
        let mut texture: Option<ID3D11Texture2D> = None;
        unsafe { device.CreateTexture2D(&desc, None, Some(&mut texture)) }
            .context("CreateTexture2D (shared)")?;
        let texture = texture.context("no texture")?;

        let name = format!(r"Local\pwrup-host-test-{}", std::process::id());
        let resource: IDXGIResource1 = texture.cast()?;
        let handle = unsafe {
            resource.CreateSharedHandle(
                None,
                DXGI_SHARED_RESOURCE_READ.0 | DXGI_SHARED_RESOURCE_WRITE.0,
                &HSTRING::from(&name),
            )
        }
        .context("CreateSharedHandle")?;

        Ok(Self {
            context,
            texture,
            handle,
            shared: SharedTexture {
                name: name.into(),
                size: size(DevicePixels(width as i32), DevicePixels(height as i32)),
                opaque: true,
            },
            width,
            height,
            pixels: RefCell::new(vec![0; width * height * 4]),
        })
    }

    pub fn buffer(&self) -> &SharedTexture {
        &self.shared
    }

    pub fn draw(&self, t: f32) {
        let mut pixels = self.pixels.borrow_mut();
        let width = self.width as f32;
        let height = self.height as f32;
        let bar = ((t * 0.25).fract() * width) as usize;
        for (index, pixel) in pixels.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let (x, y) = (index % self.width, index / self.width);
            *pixel = if x.abs_diff(bar) < 6 {
                [255, 255, 255, 255]
            } else {
                [
                    (x as f32 / width * 255.0) as u8,
                    (y as f32 / height * 255.0) as u8,
                    160,
                    255,
                ]
            };
        }
        // GPUI samples this from its own device without a keyed mutex, so a frame can tear. That
        // is acceptable for a test pattern; Godot's frames are fenced before the host sees them.
        unsafe {
            self.context.UpdateSubresource(
                &self.texture,
                0,
                None,
                pixels.as_ptr().cast(),
                (self.width * 4) as u32,
                0,
            );
            self.context.Flush();
        }
    }
}

impl Drop for TestPattern {
    fn drop(&mut self) {
        let _ = unsafe { CloseHandle(self.handle) };
    }
}
