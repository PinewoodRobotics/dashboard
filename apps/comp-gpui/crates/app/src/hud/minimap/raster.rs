//! CPU rendering of the interim 2D minimap: the top-down field picture seen
//! along the minimap camera's azimuth, the robot, and MiniMap3D.tsx's frame
//! (elliptical top corners and inset vignette, as Godot's
//! minimap_frame.gdshader evaluates it). GPUI cannot rotate raster images, so
//! each view is resampled into one BGRA image.

use dash_core::field::frame::{FIELD_LENGTH_M, FIELD_WIDTH_M};

/// `assets/field/field-2026.png`: `public/match/field-2026.png` (7992 x 3240)
/// scaled to 2886 px wide.
pub const FIELD_PNG: &[u8] = include_bytes!("../../../assets/field/field-2026.png");
const SOURCE_WIDTH: f32 = 7992.0;
/// Inner edges of the white carpet border in the 7992 px source: world -X
/// (red wall) is left and world +Z is down, so the picture is the field seen
/// from above with no rotation.
const SOURCE_CARPET: [f32; 4] = [1066.0, 188.0, 6926.0, 3052.0];

pub const ROBOT_SIDE_M: f32 = 0.9;
const ROBOT_FRAME_M: f32 = 0.66;
const BUMPER_RED: [f32; 3] = [0xdd as f32, 0x11 as f32, 0x11 as f32];
const BUMPER_BLUE: [f32; 3] = [0x11 as f32, 0x11 as f32, 0xdd as f32];
const BUMPER_UNKNOWN: [f32; 3] = [0x55 as f32, 0x55 as f32, 0x55 as f32];
const ROBOT_FRAME: [f32; 3] = [0x2a as f32, 0x2a as f32, 0x2a as f32];
const ROBOT_ARROW: [f32; 3] = [255.0, 255.0, 255.0];
/// CadMaterials.DIM: the robot while its pose is not current.
const DIM: f32 = 0.35;

pub struct Texture {
    pub width: usize,
    pub height: usize,
    /// RGB, row-major.
    pub rgb: Vec<u8>,
    /// Texture pixels per meter and the world origin (field center) in
    /// texture pixels.
    pub ppm: f32,
    pub center: [f32; 2],
}

impl Texture {
    pub fn decode() -> Option<Texture> {
        let img = image::load_from_memory_with_format(FIELD_PNG, image::ImageFormat::Png)
            .ok()?
            .into_rgb8();
        let (w, h) = img.dimensions();
        Some(Self::from_rgb(w as usize, h as usize, img.into_raw()))
    }

    pub fn from_rgb(width: usize, height: usize, rgb: Vec<u8>) -> Texture {
        let s = width as f32 / SOURCE_WIDTH;
        let [l, t, r, b] = SOURCE_CARPET.map(|v| v * s);
        let ppm = ((r - l) / FIELD_LENGTH_M as f32 + (b - t) / FIELD_WIDTH_M as f32) / 2.0;
        Texture {
            width,
            height,
            rgb,
            ppm,
            center: [(l + r) / 2.0, (t + b) / 2.0],
        }
    }

    /// Texture pixel of a world (X, Z) point.
    pub fn texel(&self, x: f32, z: f32) -> [f32; 2] {
        [self.center[0] + x * self.ppm, self.center[1] + z * self.ppm]
    }

    fn sample(&self, u: f32, v: f32) -> [f32; 3] {
        let u = u - 0.5;
        let v = v - 0.5;
        let x0 = u.floor();
        let y0 = v.floor();
        let fx = u - x0;
        let fy = v - y0;
        let (x0, y0) = (x0 as isize, y0 as isize);
        let px = |x: isize, y: isize| -> [f32; 3] {
            if x < 0 || y < 0 || x >= self.width as isize || y >= self.height as isize {
                return [0.0; 3];
            }
            let i = (y as usize * self.width + x as usize) * 3;
            [
                self.rgb[i] as f32,
                self.rgb[i + 1] as f32,
                self.rgb[i + 2] as f32,
            ]
        };
        let a = px(x0, y0);
        let b = px(x0 + 1, y0);
        let c = px(x0, y0 + 1);
        let d = px(x0 + 1, y0 + 1);
        let mut out = [0.0; 3];
        for k in 0..3 {
            let top = a[k] + (b[k] - a[k]) * fx;
            let bot = c[k] + (d[k] - c[k]) * fx;
            out[k] = top + (bot - top) * fy;
        }
        out
    }
}

/// Everything one minimap image depends on.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct View {
    pub width: usize,
    pub height: usize,
    /// Output pixels per design pixel.
    pub scale: f32,
    /// World (X, Z) at the image center: the camera target.
    pub target: [f32; 2],
    /// Camera azimuth (MinimapCamera.theta).
    pub theta: f32,
    /// Output pixels per meter.
    pub ppm: f32,
    /// Robot world (X, Z) and field heading.
    pub robot: [f32; 2],
    pub heading: f32,
    pub alliance_red: Option<bool>,
    pub dimmed: bool,
}

impl View {
    /// World (X, Z) under output pixel center (px, py). The camera sits on
    /// the (sin theta, cos theta) side of the target looking at it, so screen
    /// right is world (cos, -sin) and screen down is world (sin, cos).
    pub fn world_at(&self, px: f32, py: f32) -> [f32; 2] {
        let mx = (px - self.width as f32 / 2.0) / self.ppm;
        let my = (py - self.height as f32 / 2.0) / self.ppm;
        let (s, c) = self.theta.sin_cos();
        [
            self.target[0] + mx * c + my * s,
            self.target[1] - mx * s + my * c,
        ]
    }

    /// Visually equal: no pixel would move by more than a fraction of one.
    pub fn close_to(&self, o: &View) -> bool {
        let px = 0.25 / self.ppm;
        let span = (self.width.max(self.height) as f32).max(1.0);
        self.width == o.width
            && self.height == o.height
            && self.alliance_red == o.alliance_red
            && self.dimmed == o.dimmed
            && (self.scale - o.scale).abs() < 1e-4
            && (self.ppm - o.ppm).abs() * span / self.ppm < 0.25
            && (self.target[0] - o.target[0]).abs() < px
            && (self.target[1] - o.target[1]).abs() < px
            && (self.robot[0] - o.robot[0]).abs() < px
            && (self.robot[1] - o.robot[1]).abs() < px
            && angle_diff(self.theta, o.theta) * span < 0.25
            && angle_diff(self.heading, o.heading) * ROBOT_SIDE_M * self.ppm < 0.25
    }
}

fn angle_diff(a: f32, b: f32) -> f32 {
    let d = (a - b).rem_euclid(std::f32::consts::TAU);
    d.min(std::f32::consts::TAU - d)
}

/// The frame of MiniMap3D.tsx in design pixels: `border-radius: 30% 30% 0 0`
/// and `box-shadow: inset 0 0 5vw 3.5vw black`.
pub struct Frame {
    pub size: [f32; 2],
    pub radius: [f32; 2],
    pub blur: f32,
    pub spread: f32,
}

/// Per output pixel: how much of the picture survives the vignette, and the
/// coverage of the rounded frame.
pub struct Mask {
    pub width: usize,
    pub height: usize,
    pub keep: Vec<f32>,
    pub alpha: Vec<u8>,
}

fn sd_ellipse(p: [f32; 2], r: [f32; 2]) -> f32 {
    let k0 = ((p[0] / r[0]).powi(2) + (p[1] / r[1]).powi(2)).sqrt();
    let k1 = ((p[0] / (r[0] * r[0])).powi(2) + (p[1] / (r[1] * r[1])).powi(2)).sqrt();
    k0 * (k0 - 1.0) / k1.max(1e-6)
}

/// Distance from `p` to the edge of a box with elliptical top corners,
/// positive inside.
pub fn inside_dist(p: [f32; 2], size: [f32; 2], r: [f32; 2]) -> f32 {
    let mut d = p[0].min(size[0] - p[0]).min(p[1].min(size[1] - p[1]));
    if p[1] < r[1] {
        if p[0] < r[0] {
            d = -sd_ellipse([p[0] - r[0], p[1] - r[1]], r);
        } else if p[0] > size[0] - r[0] {
            d = -sd_ellipse([p[0] - (size[0] - r[0]), p[1] - r[1]], r);
        }
    }
    d
}

/// Abramowitz-Stegun 7.1.26.
fn erf(x: f32) -> f32 {
    let s = x.signum();
    let a = x.abs();
    let t = 1.0 / (1.0 + 0.327_591_1 * a);
    let y = 1.0
        - (((((1.061_405_4 * t - 1.453_152_1) * t) + 1.421_413_8) * t - 0.284_496_74) * t
            + 0.254_829_6)
            * t
            * (-a * a).exp();
    s * y
}

impl Mask {
    pub fn new(frame: &Frame, width: usize, height: usize) -> Mask {
        let sx = frame.size[0] / width as f32;
        let sy = frame.size[1] / height as f32;
        let inner = [
            frame.size[0] - 2.0 * frame.spread,
            frame.size[1] - 2.0 * frame.spread,
        ];
        let inner_r = [
            (frame.radius[0] - frame.spread).max(1e-3),
            (frame.radius[1] - frame.spread).max(1e-3),
        ];
        let sigma = frame.blur * 0.5;
        let mut keep = Vec::with_capacity(width * height);
        let mut alpha = Vec::with_capacity(width * height);
        for y in 0..height {
            for x in 0..width {
                let p = [(x as f32 + 0.5) * sx, (y as f32 + 0.5) * sy];
                let edge = inside_dist(p, frame.size, frame.radius) / sx;
                alpha.push(((edge + 0.5).clamp(0.0, 1.0) * 255.0).round() as u8);
                let d_in = inside_dist([p[0] - frame.spread, p[1] - frame.spread], inner, inner_r);
                let shadow = 0.5 * (1.0 - erf(d_in / (sigma * std::f32::consts::SQRT_2)));
                keep.push(1.0 - shadow);
            }
        }
        Mask {
            width,
            height,
            keep,
            alpha,
        }
    }
}

struct Robot {
    pos: [f32; 2],
    fwd: [f32; 2],
    bumper: [f32; 3],
    shade: f32,
    px: f32,
}

impl Robot {
    fn new(view: &View) -> Robot {
        let h = view.heading;
        Robot {
            pos: view.robot,
            fwd: [-h.cos(), h.sin()],
            bumper: match view.alliance_red {
                Some(true) => BUMPER_RED,
                Some(false) => BUMPER_BLUE,
                None => BUMPER_UNKNOWN,
            },
            shade: if view.dimmed { DIM } else { 1.0 },
            px: 1.0 / view.ppm,
        }
    }

    /// Paints the robot over `rgb` at world point `w`.
    fn over(&self, w: [f32; 2], rgb: &mut [f32; 3]) {
        let d = [w[0] - self.pos[0], w[1] - self.pos[1]];
        let reach = ROBOT_SIDE_M * 0.75;
        if d[0].abs() > reach || d[1].abs() > reach {
            return;
        }
        let along = d[0] * self.fwd[0] + d[1] * self.fwd[1];
        let side = d[0] * -self.fwd[1] + d[1] * self.fwd[0];
        let boxd = |half: f32| along.abs().max(side.abs()) - half;
        let cover = |sd: f32| (0.5 - sd / self.px).clamp(0.0, 1.0);
        let layers = [
            (cover(boxd(ROBOT_SIDE_M / 2.0)), self.bumper),
            (cover(boxd(ROBOT_FRAME_M / 2.0)), ROBOT_FRAME),
            (cover(arrow_sd(along, side)), ROBOT_ARROW),
        ];
        for (a, c) in layers {
            if a > 0.0 {
                for k in 0..3 {
                    rgb[k] += (c[k] * self.shade - rgb[k]) * a;
                }
            }
        }
    }
}

/// Signed distance (meters, approximate) to the forward-pointing arrow head
/// inside the robot frame.
fn arrow_sd(along: f32, side: f32) -> f32 {
    let tip = 0.24;
    let back = -0.14;
    let half_w = 0.2;
    let base = back - along;
    let slope = half_w / (tip - back);
    let n = (1.0 + slope * slope).sqrt();
    let edge = (side.abs() - (tip - along) * slope) / n;
    base.max(edge)
}

/// The BGRA image of `view`, straight alpha, rendered in row bands across
/// the available cores.
pub fn render(tex: &Texture, mask: &Mask, view: &View) -> Vec<u8> {
    let (w, h) = (view.width, view.height);
    let mut out = vec![0u8; w * h * 4];
    if w == 0 || h == 0 {
        return out;
    }
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .clamp(1, 8);
    let rows_per = h.div_ceil(threads);
    std::thread::scope(|scope| {
        for (band, chunk) in out.chunks_mut(rows_per * w * 4).enumerate() {
            scope.spawn(move || render_rows(tex, mask, view, band * rows_per, chunk));
        }
    });
    out
}

fn render_rows(tex: &Texture, mask: &Mask, view: &View, first_row: usize, out: &mut [u8]) {
    let w = view.width;
    let robot = Robot::new(view);
    let o = view.world_at(0.5, 0.5);
    let dx = {
        let p = view.world_at(1.5, 0.5);
        [p[0] - o[0], p[1] - o[1]]
    };
    let dy = {
        let p = view.world_at(0.5, 1.5);
        [p[0] - o[0], p[1] - o[1]]
    };
    let same_mask = mask.width == w && mask.height == view.height;
    for (r, row) in out.chunks_mut(w * 4).enumerate() {
        let y = first_row + r;
        let mut wpt = [o[0] + dy[0] * y as f32, o[1] + dy[1] * y as f32];
        for (x, p) in row.chunks_exact_mut(4).enumerate() {
            let i = y * w + x;
            let (keep, alpha) = if same_mask {
                (mask.keep[i], mask.alpha[i])
            } else {
                (1.0, 255)
            };
            if alpha > 0 {
                let t = tex.texel(wpt[0], wpt[1]);
                let mut rgb = tex.sample(t[0], t[1]);
                robot.over(wpt, &mut rgb);
                p[0] = (rgb[2] * keep).round().clamp(0.0, 255.0) as u8;
                p[1] = (rgb[1] * keep).round().clamp(0.0, 255.0) as u8;
                p[2] = (rgb[0] * keep).round().clamp(0.0, 255.0) as u8;
                p[3] = alpha;
            }
            wpt[0] += dx[0];
            wpt[1] += dx[1];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Frame, Mask, SOURCE_WIDTH, Texture, View, render};
    use dash_core::field::frame::{HALF_LENGTH_M, HALF_WIDTH_M};
    use std::f32::consts::{FRAC_PI_2, PI};

    fn view(theta: f32) -> View {
        View {
            width: 100,
            height: 80,
            scale: 1.0,
            target: [2.0, -1.0],
            theta,
            ppm: 10.0,
            robot: [2.0, -1.0],
            heading: 0.0,
            alliance_red: Some(false),
            dimmed: false,
        }
    }

    fn near(a: [f32; 2], b: [f32; 2], msg: &str) {
        assert!(
            (a[0] - b[0]).abs() < 1e-4 && (a[1] - b[1]).abs() < 1e-4,
            "{msg}: {a:?} vs {b:?}"
        );
    }

    #[test]
    fn target_is_the_image_center() {
        for theta in [0.0, 1.0, PI, -2.5] {
            near(view(theta).world_at(50.0, 40.0), [2.0, -1.0], "center");
        }
    }

    #[test]
    fn theta_zero_is_the_picture_unrotated() {
        let v = view(0.0);
        near(v.world_at(60.0, 40.0), [3.0, -1.0], "right is +X");
        near(v.world_at(50.0, 50.0), [2.0, 0.0], "down is +Z");
    }

    #[test]
    fn follow_mode_puts_robot_forward_up() {
        for heading in [0.0f32, 0.7, -2.0, 3.0] {
            let theta = heading + FRAC_PI_2;
            let v = view(theta);
            let up = v.world_at(50.0, 30.0);
            let fwd = [-heading.cos(), heading.sin()];
            near(
                [up[0] - 2.0, up[1] + 1.0],
                fwd,
                "screen up is the robot's forward",
            );
        }
    }

    #[test]
    fn blue_driver_view_looks_at_the_red_wall() {
        let v = view(FRAC_PI_2);
        let up = v.world_at(50.0, 30.0);
        assert!(up[0] < 2.0 - 0.9, "up is world -X, toward red: {up:?}");
        let v = view(-FRAC_PI_2);
        let up = v.world_at(50.0, 30.0);
        assert!(up[0] > 2.0 + 0.9, "red driver: up is toward blue: {up:?}");
    }

    #[test]
    fn carpet_corners_land_on_the_border() {
        let tex = Texture::from_rgb(2886, 1170, Vec::new());
        let s = 2886.0 / SOURCE_WIDTH;
        let tl = tex.texel(-HALF_LENGTH_M as f32, -HALF_WIDTH_M as f32);
        let br = tex.texel(HALF_LENGTH_M as f32, HALF_WIDTH_M as f32);
        assert!(
            (tl[0] - 1066.0 * s).abs() < 1.5 && (tl[1] - 188.0 * s).abs() < 1.5,
            "{tl:?}"
        );
        assert!(
            (br[0] - 6926.0 * s).abs() < 1.5 && (br[1] - 3052.0 * s).abs() < 1.5,
            "{br:?}"
        );
    }

    #[test]
    fn frame_mask_rounds_the_top_and_darkens_the_edges() {
        let f = Frame {
            size: [840.0, 619.2],
            radius: [252.0, 185.76],
            blur: 96.0,
            spread: 67.2,
        };
        let m = Mask::new(&f, 84, 62);
        let at = |x: usize, y: usize| (m.keep[y * 84 + x], m.alpha[y * 84 + x]);
        assert_eq!(at(0, 0).1, 0, "top-left corner is cut");
        assert_eq!(at(83, 0).1, 0, "top-right corner is cut");
        assert_eq!(at(0, 61).1, 255, "bottom corners are square");
        assert_eq!(at(42, 31).1, 255);
        assert!(at(42, 31).0 > 0.99, "center is clear: {}", at(42, 31).0);
        assert!(at(1, 40).0 < 0.2, "edges fade to black: {}", at(1, 40).0);
    }

    #[test]
    fn robot_paints_bumpers_and_arrow() {
        let v = View {
            width: 120,
            height: 120,
            ppm: 100.0,
            ..view(FRAC_PI_2)
        };
        let tex = Texture::from_rgb(1, 1, vec![0, 0, 0]);
        let mask = Mask {
            width: 0,
            height: 0,
            keep: Vec::new(),
            alpha: Vec::new(),
        };
        let img = render(&tex, &mask, &v);
        let px = |x: usize, y: usize| {
            let i = (y * 120 + x) * 4;
            [img[i + 2], img[i + 1], img[i]]
        };
        assert_eq!(px(60, 50), [255, 255, 255], "arrow ahead of center");
        assert_eq!(px(85, 60), [0x2a, 0x2a, 0x2a], "frame beside it");
        assert_eq!(px(60, 100), [0x11, 0x11, 0xdd], "blue bumper at the back");
        assert_eq!(px(2, 2), [0, 0, 0], "field elsewhere");
    }

    #[test]
    fn close_views_skip_rerender() {
        let a = view(0.3);
        let mut b = a;
        b.target[0] += 0.001;
        assert!(a.close_to(&b));
        b.target[0] += 0.1;
        assert!(!a.close_to(&b));
        let mut c = a;
        c.dimmed = true;
        assert!(!a.close_to(&c));
    }
}
