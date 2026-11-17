//! Interim 2D HUD minimap standing in for MiniMap3D.tsx until the 3D views
//! land: the top-down field picture framed by the minimap camera (target,
//! azimuth, distance), the HUD's auto path, and the robot at its smoothed
//! pose with alliance bumpers, inside MiniMap3D's rounded, vignetted frame.
//! While the HUD mirrors the touchscreen preview, the robot and camera follow
//! the preview frame instead (Godot's MinimapView). Self-contained: the HUD
//! holds one [`Minimap`] and places its element.

mod path;
mod raster;

use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use dash_core::autos::{HudOverlay, PathOverlay};
use dash_core::field::{CameraMode, MapView, MinimapCamera, PoseSmoother, frame};
use gpui_kit::*;

use crate::mock::{MapMode, MockData};
use crate::theme::u;

const MINIMAP: Bounds<f32> = Bounds {
    origin: Point { x: 540.0, y: 480.0 },
    size: Size {
        width: 840.0,
        height: 1080.0 + 19.2 - 480.0,
    },
};
const FRAME: raster::Frame = raster::Frame {
    size: [MINIMAP.size.width, MINIMAP.size.height],
    radius: [0.3 * MINIMAP.size.width, 0.3 * MINIMAP.size.height],
    blur: 96.0,
    spread: 67.2,
};
/// Longest frame step fed to the smoothers, so a stall does not jump.
const MAX_DT_S: f64 = 0.1;

type Finished = Arc<Mutex<Option<(raster::View, Vec<u8>)>>>;

struct Job {
    view: raster::View,
    path: Option<Arc<PathOverlay>>,
    done: Finished,
}

/// Renders views on one background thread, latest request wins.
fn spawn_worker() -> Sender<Job> {
    let (tx, rx) = channel::<Job>();
    std::thread::Builder::new()
        .name("minimap".into())
        .spawn(move || worker(rx))
        .ok();
    tx
}

fn worker(rx: Receiver<Job>) {
    let Some(tex) = raster::Texture::decode() else {
        eprintln!("comp-gpui: cannot decode the minimap field picture");
        return;
    };
    let mut mask: Option<raster::Mask> = None;
    let mut layer: Option<(Arc<PathOverlay>, path::PathLayer)> = None;
    while let Ok(mut job) = rx.recv() {
        while let Ok(newer) = rx.try_recv() {
            job = newer;
        }
        let v = job.view;
        if mask
            .as_ref()
            .is_none_or(|m| m.width != v.width || m.height != v.height)
        {
            mask = Some(raster::Mask::new(&FRAME, v.width, v.height));
        }
        let Some(m) = mask.as_ref() else { continue };
        match &job.path {
            Some(p) if !layer.as_ref().is_some_and(|(q, _)| Arc::ptr_eq(p, q)) => {
                layer = Some((p.clone(), path::PathLayer::new(p)));
            }
            _ => {}
        }
        let drawn = job.path.as_ref().and(layer.as_ref()).map(|(_, l)| l);
        let bgra = raster::render(&tex, m, &v, drawn);
        if let Ok(mut slot) = job.done.lock() {
            *slot = Some((v, bgra));
        }
    }
}

pub struct Minimap {
    smoother: PoseSmoother,
    camera: MinimapCamera,
    last_frame: Option<Instant>,
    jobs: Option<Sender<Job>>,
    done: Finished,
    requested: Option<raster::View>,
    /// Keeps the requested path alive so its address stays its id.
    requested_path: Option<Arc<PathOverlay>>,
    pending: bool,
    shown: Option<Arc<RenderImage>>,
    retired: Vec<Arc<RenderImage>>,
}

impl Default for Minimap {
    fn default() -> Self {
        Self::new()
    }
}

impl Minimap {
    pub fn new() -> Self {
        Self {
            smoother: PoseSmoother::default(),
            camera: MinimapCamera::default(),
            last_frame: None,
            jobs: None,
            done: Arc::new(Mutex::new(None)),
            requested: None,
            requested_path: None,
            pending: false,
            shown: None,
            retired: Vec::new(),
        }
    }

    /// The robot pose to draw and its alliance: the smoothed NT pose, or the
    /// preview frame's while mirroring.
    fn step(
        &mut self,
        data: &MockData,
        auto: Option<&HudOverlay>,
        now: Instant,
    ) -> ((f64, f64, f64), Option<bool>) {
        let dt = self
            .last_frame
            .map(|t| now.saturating_duration_since(t).as_secs_f64().min(MAX_DT_S))
            .unwrap_or(0.0);
        self.last_frame = Some(now);
        let p = &data.pose;
        self.smoother.step(p.x_m, p.y_m, p.heading_rad, dt);
        let mirror = auto.and_then(|a| a.mirror.as_ref());
        let (pose, alliance) = match mirror {
            Some(f) => (
                (f.state.pose.x, f.state.pose.y, f.state.pose.heading),
                Some(f.alliance.is_red()),
            ),
            None => {
                let s = &self.smoother;
                ((s.x, s.y, s.heading), data.matchs.is_red_alliance)
            }
        };
        let view = MapView {
            mode: match data.map.mode {
                MapMode::Follow => CameraMode::Follow,
                MapMode::Driver => CameraMode::Driver,
            },
            angle: data.map.angle as f64,
            zoom: data.map.zoom as f64,
        };
        self.camera
            .step(dt, frame::to_world(pose.0, pose.1), pose.2, view, alliance);
        (pose, alliance)
    }

    /// The raster view for this frame. The camera's distance is turned into a
    /// scale by the height its 50 degree field of view covers at the target.
    fn view(
        &self,
        data: &MockData,
        auto: Option<&HudOverlay>,
        (pose, alliance_red): ((f64, f64, f64), Option<bool>),
        scale: f32,
    ) -> raster::View {
        let width = (MINIMAP.size.width * scale).round().max(1.0) as usize;
        let height = (MINIMAP.size.height * scale).round().max(1.0) as usize;
        let half_fov = (MinimapCamera::FOV_DEG / 2.0).to_radians();
        let visible_m = 2.0 * self.camera.dist * half_fov.tan();
        let robot = frame::to_world(pose.0, pose.1);
        let mirroring = auto.is_some_and(|a| a.mirror.is_some());
        let trusted = mirroring || data.match_feed.model.pose_trusted();
        raster::View {
            width,
            height,
            scale,
            target: [self.camera.target.x as f32, self.camera.target.z as f32],
            theta: self.camera.theta as f32,
            ppm: (height as f64 / visible_m) as f32,
            robot: [robot.x as f32, robot.z as f32],
            heading: pose.2 as f32,
            alliance_red,
            dimmed: !trusted,
            path: auto.map(|a| raster::PathView {
                id: Arc::as_ptr(&a.path) as usize,
                progress: a.progress as f32,
            }),
            aim: auto
                .and_then(|a| a.aim)
                .map(|(from, to)| [from.x as f32, from.z as f32, to.x as f32, to.z as f32]),
        }
    }

    fn take_finished(&mut self) {
        let finished = self.done.lock().ok().and_then(|mut s| s.take());
        let Some((v, bgra)) = finished else { return };
        if self.requested.is_some_and(|r| r == v) {
            self.pending = false;
        }
        let Some(buf) = image::RgbaImage::from_raw(v.width as u32, v.height as u32, bgra) else {
            return;
        };
        let img = Arc::new(RenderImage::new(vec![image::Frame::new(buf)]));
        if let Some(old) = self.shown.replace(img) {
            self.retired.push(old);
        }
    }

    pub fn render(
        &mut self,
        data: &MockData,
        auto: Option<&HudOverlay>,
        now: Instant,
        window: &mut Window,
    ) -> impl IntoElement {
        let pose = self.step(data, auto, now);
        self.take_finished();
        // Rendering above one output pixel per design pixel only costs time:
        // the field picture has ~128 px/m.
        let scale = (window.rem_size() / px(1.0) * window.scale_factor()).min(1.0);
        let view = self.view(data, auto, pose, scale);
        let path = auto.map(|a| a.path.clone());
        if !self.requested.is_some_and(|r| r.close_to(&view)) {
            let jobs = self.jobs.get_or_insert_with(spawn_worker);
            let sent = jobs
                .send(Job {
                    view,
                    path: path.clone(),
                    done: self.done.clone(),
                })
                .is_ok();
            if sent {
                self.requested = Some(view);
                self.requested_path = path;
                self.pending = true;
            }
        }
        if self.pending {
            window.request_animation_frame();
        }

        let shown = self.shown.clone();
        let retired = std::mem::take(&mut self.retired);
        div()
            .absolute()
            .left(u(MINIMAP.origin.x))
            .top(u(MINIMAP.origin.y))
            .w(u(MINIMAP.size.width))
            .h(u(MINIMAP.size.height))
            .child(
                canvas(
                    |_, _, _| {},
                    move |bounds, _, window, _| {
                        for old in retired {
                            window.drop_image(old).ok();
                        }
                        if let Some(img) = shown {
                            window
                                .paint_image(bounds, bounds, Corners::default(), img, 0, false)
                                .ok();
                        }
                    },
                )
                .absolute()
                .top_0()
                .left_0()
                .size_full(),
            )
    }
}
