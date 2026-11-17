use gpui_kit::*;

pub const fn hex(rgb: u32) -> Rgba {
    Rgba {
        r: ((rgb >> 16) & 0xff) as f32 / 255.0,
        g: ((rgb >> 8) & 0xff) as f32 / 255.0,
        b: (rgb & 0xff) as f32 / 255.0,
        a: 1.0,
    }
}

pub const fn alpha(c: Rgba, a: f32) -> Rgba {
    Rgba { a, ..c }
}

pub const ACCENT: Rgba = hex(0x70cd35);
pub const YELLOW: Rgba = hex(0xffd900);
pub const PURPLE: Rgba = hex(0xa600ff);
pub const ORANGE: Rgba = hex(0xff9d00);
pub const BLUE: Rgba = hex(0x3b82f6);
pub const ERROR: Rgba = hex(0xef4444);
pub const PANEL: Rgba = hex(0x272727);
pub const CARD: Rgba = hex(0x3c3c3c);
pub const SELECTED_FILL: Rgba = hex(0x192515);
pub const FOCUS_FILL: Rgba = hex(0x1a2410);
pub const TOAST_BG: Rgba = hex(0x0a0a0a);
pub const TOAST_BORDER: Rgba = hex(0x2a2a2a);
pub const BLACK: Rgba = hex(0x000000);
pub const WHITE: Rgba = hex(0xffffff);
pub const ZINC_100: Rgba = hex(0xf4f4f5);
pub const ZINC_300: Rgba = hex(0xd4d4d8);
pub const ZINC_400: Rgba = hex(0x9f9fa9);
pub const ZINC_500: Rgba = hex(0x71717b);
pub const ZINC_600: Rgba = hex(0x52525c);
pub const ZINC_800: Rgba = hex(0x27272a);
// Tailwind 4 palette classes (red-500, red-400), which differ from the #ef4444 hard-coded elsewhere.
pub const RED_500: Rgba = hex(0xfb2c36);
pub const RED_400: Rgba = hex(0xff6467);
pub const SCRIM: Rgba = alpha(BLACK, 0.9);
pub const HAIRLINE: Rgba = alpha(WHITE, 0.1);
pub const OUTLINE: Rgba = alpha(WHITE, 0.2);
pub const TRANSPARENT: Rgba = alpha(BLACK, 0.0);

pub const RAIL_W: f32 = 84.0;
pub const DRAWER_W: f32 = 540.0;
pub const DOCK_W: f32 = 860.0;
pub const ICON: f32 = 48.0;
pub const BORDER: f32 = 4.0;
pub const DRAWER_PAD: f32 = 20.0;
pub const DRAWER_ICON_COL: f32 = 44.0;
pub const DRAWER_GAP: f32 = 30.0;
pub const DOCK_PAD: f32 = 10.0;
pub const DOCK_GAP: f32 = 12.0;

pub const HUD_DESIGN: Size<f32> = Size {
    width: 1920.0,
    height: 1080.0,
};
pub const TOUCH_DESIGN: Size<f32> = Size {
    width: 1920.0,
    height: 515.0,
};

pub const MOTION_OVERLAY_S: f32 = 0.2;
pub const MOTION_DOCK_S: f32 = 0.1;
pub const MOTION_SLIDER_FILL_S: f32 = 0.15;
pub const MOTION_PRESS_S: f32 = 0.1;
pub const MOTION_TAILWIND_S: f32 = 0.15;

pub const INTER: &str = "Inter";
pub const MONO: &str = "Roboto Mono";
pub const SF: &str = "SF Pro";

/// Design pixels. Each window sets its rem size to one design pixel in its
/// physical scale, so the whole UI scales with the window.
pub fn u(x: f32) -> Rems {
    rems(x)
}

/// Electron declares Inter as a single 400 `@font-face`, so Chromium draws CSS
/// weights below 600 as Regular and 600 and up as Regular with synthetic bold.
/// GPUI has no synthetic bold; the real Bold cut stands in for it, matching its
/// ink within about 1.5% now that glyphs are not dilated (SemiBold is 10% light).
pub fn touch_weight(css_weight: u16) -> FontWeight {
    if css_weight >= 600 {
        FontWeight::BOLD
    } else {
        FontWeight::NORMAL
    }
}

pub fn weight(css_weight: u16) -> FontWeight {
    FontWeight(css_weight as f32)
}

pub fn tabular() -> FontFeatures {
    FontFeatures(std::sync::Arc::new(vec![("tnum".into(), 1)]))
}

pub fn ease_css(t: f32) -> f32 {
    cubic_bezier(0.25, 0.1, 0.25, 1.0, t)
}

pub fn ease_out_css(t: f32) -> f32 {
    cubic_bezier(0.0, 0.0, 0.58, 1.0, t)
}

pub fn ease_tailwind(t: f32) -> f32 {
    cubic_bezier(0.4, 0.0, 0.2, 1.0, t)
}

pub fn cubic_bezier(x1: f32, y1: f32, x2: f32, y2: f32, t: f32) -> f32 {
    if t <= 0.0 {
        return 0.0;
    }
    if t >= 1.0 {
        return 1.0;
    }
    let bez = |a: f32, b: f32, s: f32| {
        let inv = 1.0 - s;
        3.0 * inv * inv * s * a + 3.0 * inv * s * s * b + s * s * s
    };
    let mut lo = 0.0f32;
    let mut hi = 1.0f32;
    let mut s = t;
    for _ in 0..24 {
        let x = bez(x1, x2, s);
        if (x - t).abs() < 1e-5 {
            break;
        }
        if x < t {
            lo = s;
        } else {
            hi = s;
        }
        s = (lo + hi) * 0.5;
    }
    bez(y1, y2, s)
}

pub fn lerp_rgba(a: Rgba, b: Rgba, t: f32) -> Rgba {
    Rgba {
        r: a.r + (b.r - a.r) * t,
        g: a.g + (b.g - a.g) * t,
        b: a.b + (b.b - a.b) * t,
        a: a.a + (b.a - a.a) * t,
    }
}
