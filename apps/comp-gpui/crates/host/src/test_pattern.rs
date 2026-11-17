use anyhow::Result;
use objc2_core_foundation::CFRetained;
use objc2_core_video::CVPixelBuffer;
use objc2_io_surface::IOSurfaceRef;

use crate::iosurface;

pub struct TestPattern {
    surface: CFRetained<IOSurfaceRef>,
    buffer: CFRetained<CVPixelBuffer>,
}

impl TestPattern {
    pub fn new(width: usize, height: usize) -> Result<Self> {
        let surface = iosurface::create_bgra_surface(width, height)?;
        let buffer = iosurface::pixel_buffer(&surface, false)?;
        Ok(Self { surface, buffer })
    }

    pub fn buffer(&self) -> &CFRetained<CVPixelBuffer> {
        &self.buffer
    }

    pub fn draw(&self, t: f32) {
        let width = self.surface.width() as f32;
        let height = self.surface.height() as f32;
        let bar = ((t * 0.25).fract() * width) as usize;
        iosurface::write_bgra(&self.surface, |x, y| {
            if x.abs_diff(bar) < 6 {
                return [255, 255, 255, 255];
            }
            let r = (x as f32 / width * 255.0) as u8;
            let g = (y as f32 / height * 255.0) as u8;
            let b = 160;
            [b, g, r, 255]
        });
    }
}
