use gpui_kit::*;

use crate::theme::u;

mod glyphs;

/// SF Symbols code points, the same ones the web types into `.sf-symbol`
/// spans (touchscreen/model/defs.ts, HubStatusIcon.tsx, MatchHUD.tsx).
/// tools/sf-symbols/export.py exports every constant here as an SVG.
pub mod sf {
    pub const AUTO: u32 = 0x1008F1;
    pub const AUTO_FILL: u32 = 0x100B31;
    pub const SETTINGS: u32 = 0x100DD6;
    pub const SETTINGS_FILL: u32 = 0x100DD7;
    pub const EFFECTS: u32 = 0x10114B;
    pub const EFFECTS_FILL: u32 = 0x10114C;
    pub const HOWARD: u32 = 0x1003B8;
    pub const HOWARD_FILL: u32 = 0x10064C;
    pub const ROBOT3D: u32 = 0x100B28;
    pub const ROBOT3D_FILL: u32 = 0x100CF4;
    pub const VISUAL: u32 = 0x1010AE;
    pub const VISUAL_FILL: u32 = 0x1010AF;
    pub const MAP: u32 = 0x10064A;
    pub const MAP_FILL: u32 = 0x10064B;
    pub const INTAKE: u32 = 0x10094E;
    pub const INTAKE_FILL: u32 = 0x10094F;
    pub const HOME: u32 = 0x101FE2;
    pub const HOME_FILL: u32 = 0x101FE3;
    pub const DOCK: u32 = 0x1003DE;
    pub const MODE_DRIVER: u32 = 0x1002D3;
    pub const MODE_DRIVER_FILL: u32 = 0x1002D4;
    pub const MODE_FOLLOW: u32 = 0x1003AC;
    pub const MODE_FOLLOW_FILL: u32 = 0x1003AD;
    pub const TOGGLE_OFF: u32 = 0x100184;
    pub const TOGGLE_ON: u32 = 0x100185;
    pub const AIM_DISABLED: u32 = 0x10004E;
    pub const AIM_GPS: u32 = 0x1003BC;
    pub const AIM_MANUAL: u32 = 0x10037A;
    pub const LANE_ALIGNMENT: u32 = 0x100A15;
}

/// One exported symbol, in font units with y up from the baseline.
pub struct Glyph {
    pub code: u32,
    pub advance: f32,
    /// x min, y min, x max, y max.
    pub ink: [f32; 4],
    /// viewBox `0 0 advance ascent+descent`, baseline at y = ascent.
    pub svg: &'static str,
}

/// SF Pro's hhea ascender and descender per em.
pub const SF_ASCENT: f32 = glyphs::ASCENT / glyphs::UNITS_PER_EM;
pub const SF_DESCENT: f32 = glyphs::DESCENT / glyphs::UNITS_PER_EM;
pub const SF_SPACE: f32 = glyphs::SPACE_ADVANCE / glyphs::UNITS_PER_EM;

const ASSET_PREFIX: &str = "sf/";

fn glyph(code: u32) -> Option<&'static Glyph> {
    glyphs::GLYPHS.iter().find(|g| g.code == code)
}

/// The symbol's advance per em, the width of its `.sf-symbol` span.
pub fn sf_advance(code: u32) -> f32 {
    glyph(code).map_or(0.0, |g| g.advance / glyphs::UNITS_PER_EM)
}

/// A `.sf-symbol` span: an advance-wide inline box with `line-height: 1`,
/// drawn from the exported outline rather than the font so it rasterizes the
/// same on every platform.
#[derive(IntoElement)]
pub struct SfSymbol {
    code: u32,
    size: f32,
    line: f32,
    color: Hsla,
    align: Align,
}

#[derive(Clone, Copy)]
enum Align {
    Inline,
    Center(Option<Bounds<f32>>),
}

pub fn sf_symbol(code: u32, size: f32, color: impl Into<Hsla>) -> SfSymbol {
    SfSymbol {
        code,
        size,
        line: size,
        color: color.into(),
        align: Align::Inline,
    }
}

impl SfSymbol {
    pub fn line_height(mut self, line: f32) -> Self {
        self.line = line;
        self
    }

    /// Fills the parent and centers the span in it, as the web's flex
    /// centering does, at Chrome's fractional position: GPUI's own layout
    /// would round the advance and the centering offset to whole pixels.
    pub fn centered(mut self) -> Self {
        self.align = Align::Center(None);
        self
    }

    /// `centered` in a parent placed at `rect` (design units) inside a
    /// whole-pixel-aligned box, centered in that unrounded rect: GPUI snaps
    /// the parent's edges, Chrome keeps their fractions.
    pub fn centered_in(mut self, rect: Bounds<f32>) -> Self {
        self.align = Align::Center(Some(rect));
        self
    }
}

impl RenderOnce for SfSymbol {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let Self {
            code,
            size,
            line,
            color,
            align,
        } = self;
        let el = canvas(
            |_, _, _| {},
            move |bounds, _, window, cx| {
                paint_symbol(code, size, line, color, align, bounds, window, cx)
            },
        );
        match align {
            Align::Center(_) => el.absolute().inset_0(),
            Align::Inline => el.flex_none().w(u(sf_advance(code) * size)).h(u(line)),
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn paint_symbol(
    code: u32,
    font_px: f32,
    line: f32,
    color: Hsla,
    align: Align,
    bounds: Bounds<Pixels>,
    window: &mut Window,
    cx: &mut App,
) {
    let Some(g) = glyph(code) else { return };
    let rem = f32::from(window.rem_size());
    let sf = window.scale_factor();
    let em = font_px * rem * sf;
    let line = line * rem * sf;
    let span_w = g.advance / glyphs::UNITS_PER_EM * em;
    let mut b = Bounds::new(
        point(f32::from(bounds.left()) * sf, f32::from(bounds.top()) * sf),
        size(
            f32::from(bounds.size.width) * sf,
            f32::from(bounds.size.height) * sf,
        ),
    );
    let (left, top) = match align {
        Align::Inline => (b.origin.x, b.origin.y),
        Align::Center(rect) => {
            if let Some(rect) = rect {
                let k = rem * sf;
                let (x, y) = (rect.origin.x * k, rect.origin.y * k);
                b = Bounds::new(
                    point(b.origin.x - snap(x) + x, b.origin.y - snap(y) + y),
                    size(rect.size.width * k, rect.size.height * k),
                );
            }
            (
                b.origin.x + (b.size.width - span_w) * 0.5,
                b.origin.y + (b.size.height - line) * 0.5,
            )
        }
    };
    let origin = symbol_origin(left, top, line, em);
    let n = origin.x.floor();
    let fx = origin.x - n;
    let r = raster_box(g, em, fx);
    let path = format!("{ASSET_PREFIX}{code:X}/{em}/{fx}.svg");
    let raster = Bounds::new(
        point(px((n + r.x) / sf), px((origin.y + r.y) / sf)),
        size(px(r.w / sf), px(r.h / sf)),
    );
    let _ = window.paint_svg(
        raster,
        path.into(),
        None,
        TransformationMatrix::unit(),
        color,
        cx,
    );
}

/// GPUI's layout rounding: to the nearest device pixel, halves toward zero.
fn snap(v: f32) -> f32 {
    if v >= 0.0 {
        (v - 0.5).ceil()
    } else {
        (v + 0.5).floor()
    }
}

/// Where Chrome draws the glyph origin of a span whose line box starts at
/// (`left`, `top`), in device pixels: Blink rounds the font's ascent and
/// descent, puts the floored half-leading above them, and Skia then snaps
/// the baseline to a whole pixel and the pen x to a quarter pixel.
fn symbol_origin(left: f32, top: f32, line: f32, em: f32) -> Point<f32> {
    let ascent = (SF_ASCENT * em).round();
    let descent = (SF_DESCENT * em).round();
    let half_leading = ((line - ascent - descent) * 0.5).floor();
    point(
        (left * 4.0).round() / 4.0,
        (top + half_leading + ascent).round(),
    )
}

#[derive(Debug, PartialEq)]
struct RasterBox {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

/// The whole-pixel box covering the ink of a glyph whose origin sits `fx`
/// right of a pixel edge and on one, relative to that pixel corner.
fn raster_box(g: &Glyph, em: f32, fx: f32) -> RasterBox {
    let s = em / glyphs::UNITS_PER_EM;
    let [x_min, y_min, x_max, y_max] = g.ink;
    let x = (fx + x_min * s).floor();
    let y = (-y_max * s).floor();
    RasterBox {
        x,
        y,
        w: ((fx + x_max * s).ceil() - x).max(1.0),
        h: ((-y_min * s).ceil() - y).max(1.0),
    }
}

/// The SVG for `sf/<code>/<em px>/<pen x fraction>.svg`: the glyph's outline
/// framed to its `raster_box`, so it rasterizes at a fractional pen position.
pub fn load(path: &str) -> Option<String> {
    let mut parts = path
        .strip_prefix(ASSET_PREFIX)?
        .strip_suffix(".svg")?
        .split('/');
    let code = u32::from_str_radix(parts.next()?, 16).ok()?;
    let em: f32 = parts.next()?.parse().ok()?;
    let fx: f32 = parts.next()?.parse().ok()?;
    let g = glyph(code)?;
    let r = raster_box(g, em, fx);
    let s = em / glyphs::UNITS_PER_EM;
    let body = &g.svg[g.svg.find("<path")?..g.svg.rfind("</svg>")?];
    Some(format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}" viewBox="{} {} {} {}">{body}</svg>"#,
        r.w,
        r.h,
        (r.x - fx) / s,
        r.y / s + glyphs::ASCENT,
        r.w / s,
        r.h / s,
    ))
}

pub fn lucide(name: &str, size: f32, color: impl Into<Hsla>) -> Svg {
    svg()
        .path(crate::assets::lucide_path(name))
        .flex_none()
        .size(u(size))
        .text_color(color)
}

#[cfg(test)]
mod tests {
    use super::{glyph, glyphs, load, raster_box, sf, symbol_origin};

    #[test]
    fn every_symbol_is_exported() {
        let src =
            std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/icons.rs")).unwrap();
        let consts = src
            .lines()
            .filter_map(|l| l.trim().strip_prefix("pub const "))
            .filter_map(|l| l.split_once(": u32 = 0x"))
            .map(|(_, v)| u32::from_str_radix(v.trim_end_matches(';'), 16).unwrap());
        for code in consts {
            assert!(glyph(code).is_some(), "U+{code:X} has no exported SVG");
        }
    }

    #[test]
    fn raster_box_covers_the_ink() {
        let g = glyph(sf::AUTO).unwrap();
        let em = 48.0;
        let s = em / glyphs::UNITS_PER_EM;
        for fx in [0.0, 0.25, 0.5, 0.75] {
            let r = raster_box(g, em, fx);
            assert!(r.x <= fx + g.ink[0] * s && r.x + r.w >= fx + g.ink[2] * s);
            assert!(r.y <= -g.ink[3] * s && r.y + r.h >= -g.ink[1] * s);
            assert!(r.x + r.w - (fx + g.ink[2] * s) < 1.0);
        }
    }

    #[test]
    fn centered_span_baseline_matches_blink() {
        let em = 48.0;
        let o = symbol_origin(10.3, 100.0, 48.0, em);
        assert_eq!(o.x, 10.25);
        assert_eq!(o.y, 141.0);
    }

    #[test]
    fn variant_svg_frames_the_glyph() {
        let svg = load("sf/1008F1/48/0.25.svg").unwrap();
        let r = raster_box(glyph(sf::AUTO).unwrap(), 48.0, 0.25);
        assert!(svg.starts_with(&format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}""#,
            r.w, r.h
        )));
        assert!(svg.contains("<path d=\"M"));
        assert!(load("sf/FFFFFF/48/0.svg").is_none());
    }
}
