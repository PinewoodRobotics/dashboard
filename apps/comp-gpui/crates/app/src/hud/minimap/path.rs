//! The auto overlay of the 2D minimap: [`PathOverlay`] seen from straight
//! above, evaluated per output pixel in world meters. The ribbon keeps
//! auto_path.gdshader's travelled/remaining split and soft edges; markers and
//! pin heads are flat shapes. Shapes are binned into a world grid once per
//! path so a pixel only tests the few near it. Colors blend in linear light,
//! as overlay_color.gdshaderinc composites them.

use dash_core::autos::overlay::{self, PathOverlay, Rgba};

const CELL_M: f32 = 0.25;
/// Reach beyond a shape's own extent that still gets antialiasing.
const MARGIN_M: f32 = 0.1;

#[derive(Clone, Copy)]
enum Shape {
    Ring { c: [f32; 2], r0: f32, r1: f32 },
    Tri([[f32; 2]; 3]),
    Diamond { c: [f32; 2], h: f32 },
}

impl Shape {
    fn bounds(&self) -> [f32; 4] {
        match *self {
            Shape::Ring { c, r1, .. } => [c[0] - r1, c[1] - r1, c[0] + r1, c[1] + r1],
            Shape::Diamond { c, h } => [c[0] - h, c[1] - h, c[0] + h, c[1] + h],
            Shape::Tri(p) => [
                p[0][0].min(p[1][0]).min(p[2][0]),
                p[0][1].min(p[1][1]).min(p[2][1]),
                p[0][0].max(p[1][0]).max(p[2][0]),
                p[0][1].max(p[1][1]).max(p[2][1]),
            ],
        }
    }

    /// Signed distance in meters, negative inside.
    fn sd(&self, w: [f32; 2]) -> f32 {
        match *self {
            Shape::Ring { c, r0, r1 } => {
                let d = (w[0] - c[0]).hypot(w[1] - c[1]);
                (d - r1).max(r0 - d)
            }
            Shape::Diamond { c, h } => {
                ((w[0] - c[0]).abs() + (w[1] - c[1]).abs() - h) * std::f32::consts::FRAC_1_SQRT_2
            }
            Shape::Tri(p) => tri_sd(w, p),
        }
    }
}

fn tri_sd(w: [f32; 2], p: [[f32; 2]; 3]) -> f32 {
    let mut dist = f32::MAX;
    let mut inside = true;
    let area =
        (p[1][0] - p[0][0]) * (p[2][1] - p[0][1]) - (p[1][1] - p[0][1]) * (p[2][0] - p[0][0]);
    for i in 0..3 {
        let a = p[i];
        let b = p[(i + 1) % 3];
        dist = dist.min(seg_dist(w, a, b).0);
        let cross = (b[0] - a[0]) * (w[1] - a[1]) - (b[1] - a[1]) * (w[0] - a[0]);
        if cross * area < 0.0 {
            inside = false;
        }
    }
    if inside { -dist } else { dist }
}

/// Distance from `w` to segment a-b and the parameter of the nearest point.
fn seg_dist(w: [f32; 2], a: [f32; 2], b: [f32; 2]) -> (f32, f32) {
    let ab = [b[0] - a[0], b[1] - a[1]];
    let aw = [w[0] - a[0], w[1] - a[1]];
    let len2 = ab[0] * ab[0] + ab[1] * ab[1];
    let s = if len2 > 1e-12 {
        ((aw[0] * ab[0] + aw[1] * ab[1]) / len2).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let d = [aw[0] - ab[0] * s, aw[1] - ab[1] * s];
    (d[0].hypot(d[1]), s)
}

fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn srgb_to_linear(c: f32) -> f32 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn linear_to_srgb(c: f32) -> f32 {
    if c <= 0.003_130_8 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

/// Linear RGB and coverage.
#[derive(Clone, Copy)]
struct Paint([f32; 3], f32);

fn paint(c: Rgba) -> Paint {
    Paint(
        [
            srgb_to_linear(c[0]),
            srgb_to_linear(c[1]),
            srgb_to_linear(c[2]),
        ],
        c[3],
    )
}

struct Seg {
    a: [f32; 2],
    b: [f32; 2],
    t0: f32,
    t1: f32,
}

pub struct PathLayer {
    segs: Vec<Seg>,
    marks: Vec<(Shape, Paint)>,
    origin: [f32; 2],
    cols: usize,
    rows: usize,
    seg_cells: Vec<Vec<u32>>,
    mark_cells: Vec<Vec<u32>>,
}

fn xz(p: dash_core::autos::WorldPoint) -> [f32; 2] {
    [p.x as f32, p.z as f32]
}

impl PathLayer {
    /// Godot's draw order: the ribbon, then the markers mesh (start ring and
    /// arrow, end fill and ring, pins).
    pub fn new(o: &PathOverlay) -> PathLayer {
        let pts: Vec<[f32; 2]> = o.line.points.iter().map(|p| xz(*p)).collect();
        let segs: Vec<Seg> = (1..pts.len())
            .map(|i| Seg {
                a: pts[i - 1],
                b: pts[i],
                t0: o.line.times[i - 1] as f32,
                t1: o.line.times[i] as f32,
            })
            .collect();
        let mut marks = Vec::new();
        let s = xz(o.start);
        let (r0, r1) = overlay::START_RING;
        let start = paint(overlay::START_COLOR);
        marks.push((
            Shape::Ring {
                c: s,
                r0: r0 as f32,
                r1: r1 as f32,
            },
            start,
        ));
        let f = [o.start_forward.0 as f32, o.start_forward.1 as f32];
        let side = [-f[1], f[0]];
        let (back, tip, half) = overlay::START_ARROW;
        let at = |along: f64, across: f32| {
            [
                s[0] + f[0] * along as f32 + side[0] * across,
                s[1] + f[1] * along as f32 + side[1] * across,
            ]
        };
        marks.push((
            Shape::Tri([at(tip, 0.0), at(back, half as f32), at(back, -half as f32)]),
            start,
        ));
        if let Some(e) = o.end {
            let mut fill = overlay::END_COLOR;
            fill[3] = overlay::END_FILL_ALPHA;
            marks.push((
                Shape::Ring {
                    c: xz(e),
                    r0: -1.0,
                    r1: overlay::END_FILL_R as f32,
                },
                paint(fill),
            ));
            let (r0, r1) = overlay::END_RING;
            marks.push((
                Shape::Ring {
                    c: xz(e),
                    r0: r0 as f32,
                    r1: r1 as f32,
                },
                paint(overlay::END_COLOR),
            ));
        }
        for pin in &o.pins {
            marks.push((
                Shape::Diamond {
                    c: xz(pin.base),
                    h: overlay::PIN_HEAD as f32,
                },
                paint(pin.color()),
            ));
        }

        let half_w = overlay_half_width();
        let mut lo = [f32::MAX; 2];
        let mut hi = [f32::MIN; 2];
        let mut grow = |b: [f32; 4]| {
            lo = [lo[0].min(b[0]), lo[1].min(b[1])];
            hi = [hi[0].max(b[2]), hi[1].max(b[3])];
        };
        for s in &segs {
            grow(seg_bounds(s, half_w));
        }
        for (m, _) in &marks {
            grow(m.bounds());
        }
        let origin = [lo[0] - MARGIN_M, lo[1] - MARGIN_M];
        let cols = (((hi[0] - lo[0] + 2.0 * MARGIN_M) / CELL_M).ceil() as usize).max(1);
        let rows = (((hi[1] - lo[1] + 2.0 * MARGIN_M) / CELL_M).ceil() as usize).max(1);
        let mut layer = PathLayer {
            segs,
            marks,
            origin,
            cols,
            rows,
            seg_cells: vec![Vec::new(); cols * rows],
            mark_cells: vec![Vec::new(); cols * rows],
        };
        for i in 0..layer.segs.len() {
            let b = seg_bounds(&layer.segs[i], half_w);
            for c in layer.cells_in(b) {
                layer.seg_cells[c].push(i as u32);
            }
        }
        for i in 0..layer.marks.len() {
            let b = layer.marks[i].0.bounds();
            for c in layer.cells_in(b) {
                layer.mark_cells[c].push(i as u32);
            }
        }
        layer
    }

    fn cells_in(&self, b: [f32; 4]) -> Vec<usize> {
        let cell =
            |v: f32, o: f32, n: usize| (((v - o) / CELL_M).floor().max(0.0) as usize).min(n - 1);
        let (x0, x1) = (
            cell(b[0] - MARGIN_M, self.origin[0], self.cols),
            cell(b[2] + MARGIN_M, self.origin[0], self.cols),
        );
        let (y0, y1) = (
            cell(b[1] - MARGIN_M, self.origin[1], self.rows),
            cell(b[3] + MARGIN_M, self.origin[1], self.rows),
        );
        let mut out = Vec::new();
        for y in y0..=y1 {
            for x in x0..=x1 {
                out.push(y * self.cols + x);
            }
        }
        out
    }

    fn cell_at(&self, w: [f32; 2]) -> Option<usize> {
        let x = ((w[0] - self.origin[0]) / CELL_M).floor();
        let y = ((w[1] - self.origin[1]) / CELL_M).floor();
        if x < 0.0 || y < 0.0 || x >= self.cols as f32 || y >= self.rows as f32 {
            return None;
        }
        Some(y as usize * self.cols + x as usize)
    }

    /// Paints the layer at world point `w` over `rgb` (sRGB 0..255). `px` is
    /// one output pixel in meters.
    pub fn over(&self, w: [f32; 2], px: f32, progress: f32, rgb: &mut [f32; 3]) {
        let Some(cell) = self.cell_at(w) else { return };
        let mut lin: Option<[f32; 3]> = None;
        let mut blend = |p: Paint, a: f32| {
            let l = lin.get_or_insert_with(|| rgb.map(|c| srgb_to_linear(c / 255.0)));
            for k in 0..3 {
                l[k] += (p.0[k] - l[k]) * a;
            }
        };
        let half_w = overlay_half_width();
        let mut best: Option<(f32, f32)> = None;
        for &i in &self.seg_cells[cell] {
            let s = &self.segs[i as usize];
            let (d, f) = seg_dist(w, s.a, s.b);
            if best.is_none_or(|(bd, _)| d < bd) {
                best = Some((d, s.t0 + (s.t1 - s.t0) * f));
            }
        }
        if let Some((d, t)) = best {
            let cover = (0.5 - (d - half_w) / px).clamp(0.0, 1.0);
            if cover > 0.0 {
                let c = if t <= progress {
                    overlay::DONE_COLOR
                } else {
                    overlay::TODO_COLOR
                };
                let edge = 1.0 - smoothstep(0.7, 1.0, (d / half_w).min(1.0));
                blend(paint(c), c[3] * (0.35 + 0.65 * edge) * cover);
            }
        }
        for &i in &self.mark_cells[cell] {
            let (shape, p) = self.marks[i as usize];
            let cover = (0.5 - shape.sd(w) / px).clamp(0.0, 1.0);
            if cover > 0.0 {
                blend(p, p.1 * cover);
            }
        }
        if let Some(l) = lin {
            *rgb = l.map(|c| linear_to_srgb(c.clamp(0.0, 1.0)) * 255.0);
        }
    }
}

fn overlay_half_width() -> f32 {
    dash_core::autos::ribbon::WIDTH as f32 / 2.0
}

fn seg_bounds(s: &Seg, half_w: f32) -> [f32; 4] {
    [
        s.a[0].min(s.b[0]) - half_w,
        s.a[1].min(s.b[1]) - half_w,
        s.a[0].max(s.b[0]) + half_w,
        s.a[1].max(s.b[1]) + half_w,
    ]
}

/// The turret's aim line (world X, Z from and to) with its target ring.
pub fn aim_over(aim: [f32; 4], w: [f32; 2], px: f32, rgb: &mut [f32; 3]) {
    let (a, b) = ([aim[0], aim[1]], [aim[2], aim[3]]);
    let (r0, r1) = (overlay::AIM_RING.0 as f32, overlay::AIM_RING.1 as f32);
    let half = overlay::AIM_HALF_WIDTH as f32;
    let reach = r1 + MARGIN_M;
    let lo = [a[0].min(b[0]) - reach, a[1].min(b[1]) - reach];
    let hi = [a[0].max(b[0]) + reach, a[1].max(b[1]) + reach];
    if w[0] < lo[0] || w[1] < lo[1] || w[0] > hi[0] || w[1] > hi[1] {
        return;
    }
    let line = seg_dist(w, a, b).0 - half;
    let ring = Shape::Ring { c: b, r0, r1 }.sd(w);
    let cover = (0.5 - line.min(ring) / px).clamp(0.0, 1.0);
    if cover <= 0.0 {
        return;
    }
    let p = paint(overlay::AIM_COLOR);
    let a = p.1 * cover;
    for k in 0..3 {
        let l = srgb_to_linear(rgb[k] / 255.0);
        rgb[k] = linear_to_srgb(l + (p.0[k] - l) * a) * 255.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes_have_signed_distances() {
        let ring = Shape::Ring {
            c: [0.0, 0.0],
            r0: 1.0,
            r1: 2.0,
        };
        assert!(ring.sd([1.5, 0.0]) < 0.0);
        assert!(ring.sd([0.5, 0.0]) > 0.0 && ring.sd([2.5, 0.0]) > 0.0);
        let tri = Shape::Tri([[0.0, 0.0], [2.0, 0.0], [0.0, 2.0]]);
        assert!(tri.sd([0.5, 0.5]) < 0.0);
        assert!((tri.sd([3.0, 0.0]) - 1.0).abs() < 1e-6);
        let flipped = Shape::Tri([[0.0, 0.0], [0.0, 2.0], [2.0, 0.0]]);
        assert!(flipped.sd([0.5, 0.5]) < 0.0, "either winding");
        let d = Shape::Diamond {
            c: [0.0, 0.0],
            h: 1.0,
        };
        assert!(d.sd([0.4, 0.4]) < 0.0 && d.sd([0.6, 0.6]) > 0.0);
    }
}
