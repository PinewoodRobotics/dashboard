//! Field geometry and the HUD minimap's pose smoothing and camera rig
//! (Godot `core/field/{field_frame,pose_smoother,minimap_camera}.gd`,
//! `core/smoothing.gd`, MiniMap3D.tsx).

use std::f64::consts::{FRAC_PI_2, PI};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Vec3 {
    pub const ZERO: Vec3 = Vec3::new(0.0, 0.0, 0.0);

    pub const fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }

    pub fn lerp(self, to: Vec3, t: f64) -> Vec3 {
        Vec3::new(
            self.x + (to.x - self.x) * t,
            self.y + (to.y - self.y) * t,
            self.z + (to.z - self.z) * t,
        )
    }

    pub fn distance_to(self, o: Vec3) -> f64 {
        ((self.x - o.x).powi(2) + (self.y - o.y).powi(2) + (self.z - o.z).powi(2)).sqrt()
    }

    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.z.is_finite()
    }
}

/// Godot's `wrapf`: `v` wrapped into `[min, max)`.
pub fn wrap(v: f64, min: f64, max: f64) -> f64 {
    let range = max - min;
    if range == 0.0 {
        return min;
    }
    min + (v - min).rem_euclid(range)
}

/// Frame-rate independent lerp factor: `rate` is the per-frame factor at 60 fps.
pub fn dt_lerp(rate: f64, dt: f64) -> f64 {
    1.0 - (1.0 - rate).powf(dt * 60.0)
}

pub fn lerp_angle(a: f64, b: f64, t: f64) -> f64 {
    a + wrap(b - a, -PI, PI) * t
}

/// WPILib blue-origin field pose (x along the field, y left, heading CCW) to
/// the world of field.glb (Y up, centered, blue alliance wall at +X).
/// Uses the official 16.541 x 8.069 m carpet, not the 8.21 m the web minimap used.
pub mod frame {
    use super::*;

    pub const FIELD_LENGTH_M: f64 = 16.541;
    pub const FIELD_WIDTH_M: f64 = 8.069;
    pub const HALF_LENGTH_M: f64 = FIELD_LENGTH_M / 2.0;
    pub const HALF_WIDTH_M: f64 = FIELD_WIDTH_M / 2.0;

    /// PathPlannerLib FlippingUtil field size (rotational symmetry).
    pub const PP_FIELD_SIZE: (f64, f64) = (16.54, 8.07);

    pub fn to_world(x: f64, y: f64) -> Vec3 {
        Vec3::new(HALF_LENGTH_M - x, 0.0, y - HALF_WIDTH_M)
    }

    pub fn from_world(p: Vec3) -> (f64, f64) {
        (HALF_LENGTH_M - p.x, p.z + HALF_WIDTH_M)
    }

    /// Rotation about +Y for the robot wrapper (model forward is +Z).
    pub fn yaw(heading: f64) -> f64 {
        heading - FRAC_PI_2
    }

    /// `v` rotated by `angle` about +Y.
    pub fn rotate_y(v: Vec3, angle: f64) -> Vec3 {
        let (s, c) = angle.sin_cos();
        Vec3::new(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
    }

    pub fn forward(heading: f64) -> Vec3 {
        rotate_y(Vec3::new(0.0, 0.0, 1.0), yaw(heading))
    }

    /// PathPlanner alliance flip of a blue-origin pose (x, y, heading).
    pub fn flip(pose: Vec3) -> Vec3 {
        Vec3::new(
            PP_FIELD_SIZE.0 - pose.x,
            PP_FIELD_SIZE.1 - pose.y,
            wrap(pose.z + PI, -PI, PI),
        )
    }
}

/// The minimap pose smoothing: snap on jumps over 1.5 m, otherwise an
/// adaptive frame-rate independent lerp with shortest-arc heading.
#[derive(Clone, Copy, Debug, Default)]
pub struct PoseSmoother {
    pub x: f64,
    pub y: f64,
    pub heading: f64,
    pub initialized: bool,
}

impl PoseSmoother {
    pub const SNAP_DISTANCE_M: f64 = 1.5;

    pub fn snap(&mut self, x: f64, y: f64, heading: f64) {
        *self = Self {
            x,
            y,
            heading,
            initialized: true,
        };
    }

    pub fn step(&mut self, px: f64, py: f64, ph: f64, dt: f64) {
        if !(px.is_finite() && py.is_finite() && ph.is_finite()) {
            return;
        }
        if !self.initialized
            || !(self.x.is_finite() && self.y.is_finite() && self.heading.is_finite())
        {
            self.snap(px, py, ph);
            return;
        }
        let dx = px - self.x;
        let dy = py - self.y;
        let dist = (dx * dx + dy * dy).sqrt();
        if dist > Self::SNAP_DISTANCE_M {
            self.snap(px, py, ph);
            return;
        }
        let t = dt_lerp((0.15 + dist * 1.4).min(0.95), dt);
        self.x += dx * t;
        self.y += dy * t;
        self.heading = lerp_angle(self.heading, ph, t);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameraMode {
    Follow,
    Driver,
}

/// The HUD map settings the camera reads: angle and zoom are 0..1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MapView {
    pub mode: CameraMode,
    pub angle: f64,
    pub zoom: f64,
}

impl Default for MapView {
    fn default() -> Self {
        Self {
            mode: CameraMode::Follow,
            angle: 0.3,
            zoom: 0.5,
        }
    }
}

/// HUD minimap camera math (MiniMap3D.tsx): a spherical rig around a target
/// that trails the robot.
#[derive(Clone, Copy, Debug, Default)]
pub struct MinimapCamera {
    pub phi: f64,
    pub dist: f64,
    pub theta: f64,
    pub target: Vec3,
    pub initialized: bool,
}

impl MinimapCamera {
    pub const FOV_DEG: f64 = 50.0;
    pub const NEAR: f64 = 0.1;
    pub const FAR: f64 = 100.0;
    pub const ZOOM_NEAR: f64 = 2.0;
    pub const ZOOM_FAR: f64 = 11.05;
    pub const POLAR_TOP: f64 = 0.08;
    pub const POLAR_LOW: f64 = 1.35;
    pub const LERP_POS: f64 = 0.15;
    pub const LERP_THETA: f64 = 0.10;
    pub const LERP_SPHERE: f64 = 0.1;
    pub const TARGET_HEIGHT: f64 = 0.3;

    pub fn target_phi(angle: f64) -> f64 {
        Self::POLAR_LOW - angle * (Self::POLAR_LOW - Self::POLAR_TOP)
    }

    pub fn target_dist(zoom: f64) -> f64 {
        Self::ZOOM_FAR + zoom * (Self::ZOOM_NEAR - Self::ZOOM_FAR)
    }

    pub fn desired_target(robot_world: Vec3, zoom: f64) -> Vec3 {
        Vec3::new(robot_world.x, Self::TARGET_HEIGHT, robot_world.z * zoom)
    }

    /// `is_red` is `None` while the alliance is unknown, which views as blue.
    pub fn desired_theta(mode: CameraMode, heading: f64, is_red: Option<bool>) -> f64 {
        match mode {
            CameraMode::Driver if is_red == Some(true) => -FRAC_PI_2,
            CameraMode::Driver => FRAC_PI_2,
            CameraMode::Follow => heading + FRAC_PI_2,
        }
    }

    /// The first call snaps to the goal so the view does not swoop in on startup.
    pub fn step(
        &mut self,
        dt: f64,
        robot_world: Vec3,
        heading: f64,
        view: MapView,
        is_red: Option<bool>,
    ) {
        let goal_target = Self::desired_target(robot_world, view.zoom);
        let goal_theta = Self::desired_theta(view.mode, heading, is_red);
        if !self.initialized {
            *self = Self {
                phi: Self::target_phi(view.angle),
                dist: Self::target_dist(view.zoom),
                target: goal_target,
                theta: goal_theta,
                initialized: true,
            };
            return;
        }
        let k_sphere = dt_lerp(Self::LERP_SPHERE, dt);
        self.phi += (Self::target_phi(view.angle) - self.phi) * k_sphere;
        self.dist += (Self::target_dist(view.zoom) - self.dist) * k_sphere;
        self.target = self.target.lerp(goal_target, dt_lerp(Self::LERP_POS, dt));
        self.theta = lerp_angle(self.theta, goal_theta, dt_lerp(Self::LERP_THETA, dt));
    }

    pub fn position(&self) -> Vec3 {
        let (sp, cp) = self.phi.sin_cos();
        let (st, ct) = self.theta.sin_cos();
        Vec3::new(
            self.target.x + self.dist * sp * st,
            self.target.y + self.dist * cp,
            self.target.z + self.dist * sp * ct,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::frame::*;
    use super::*;
    use std::f64::consts::TAU;

    fn near(a: f64, b: f64, tol: f64, msg: &str) {
        assert!((a - b).abs() <= tol, "{msg}: expected {b}, got {a}");
    }

    fn vec_near(a: Vec3, b: Vec3, tol: f64, msg: &str) {
        assert!(a.distance_to(b) <= tol, "{msg}: expected {b:?}, got {a:?}");
    }

    #[test]
    fn corners_map_to_world() {
        vec_near(
            to_world(0.0, 0.0),
            Vec3::new(8.2705, 0.0, -4.0345),
            1e-5,
            "blue-right corner",
        );
        vec_near(
            to_world(16.541, 8.069),
            Vec3::new(-8.2705, 0.0, 4.0345),
            1e-5,
            "red-left corner",
        );
        vec_near(to_world(8.2705, 4.0345), Vec3::ZERO, 1e-5, "center");
        let (x, y) = from_world(to_world(2.0, 4.03));
        near(x, 2.0, 1e-5, "round trip x");
        near(y, 4.03, 1e-5, "round trip y");
    }

    #[test]
    fn heading_zero_faces_world_minus_x() {
        vec_near(
            forward(0.0),
            Vec3::new(-1.0, 0.0, 0.0),
            1e-5,
            "heading 0 faces the red wall",
        );
        vec_near(
            forward(FRAC_PI_2),
            Vec3::new(0.0, 0.0, 1.0),
            1e-5,
            "heading +90 deg faces +y = world +Z",
        );
        near(yaw(0.0), -FRAC_PI_2, 1e-12, "yaw");
        vec_near(
            to_world(2.0, 4.03),
            Vec3::new(6.2705, 0.0, -0.0045),
            1e-5,
            "robot at (2, 4.03) is on the blue +X half",
        );
    }

    #[test]
    fn field_motion_is_a_proper_rotation() {
        let o = to_world(0.0, 0.0);
        let a = to_world(1.0, 0.0);
        let b = to_world(0.0, 1.0);
        let (ax, az) = (a.x - o.x, a.z - o.z);
        let (bx, bz) = (b.x - o.x, b.z - o.z);
        near(az * bx - ax * bz, 1.0, 1e-5, "x cross y = up, no mirroring");
    }

    #[test]
    fn pathplanner_flip() {
        let f = flip(Vec3::new(1.0, 2.0, 0.25));
        near(f.x, 15.54, 1e-5, "x");
        near(f.y, 6.07, 1e-5, "y");
        near(f.z, 0.25 + PI - TAU, 1e-5, "heading");
        let back = flip(f);
        near(back.x, 1.0, 1e-5, "x back");
        near(back.y, 2.0, 1e-5, "y back");
        near(back.z, 0.25, 1e-5, "heading back");
    }

    #[test]
    fn dt_lerp_compounds_per_frame() {
        near(
            dt_lerp(0.15, 1.0 / 60.0),
            0.15,
            1e-5,
            "one 60 Hz frame equals the rate",
        );
        near(
            dt_lerp(0.15, 2.0 / 60.0),
            1.0 - 0.85 * 0.85,
            1e-5,
            "two frames compound",
        );
        assert_eq!(dt_lerp(0.5, 0.0), 0.0);
    }

    #[test]
    fn lerp_angle_short_arc() {
        near(lerp_angle(0.0, 1.0, 0.5), 0.5, 1e-5, "plain");
        near(
            lerp_angle(3.0, -3.0, 0.5),
            3.0 + (TAU - 6.0) / 2.0,
            1e-5,
            "crosses +-PI the short way",
        );
        near(
            lerp_angle(-3.0, 3.0, 1.0),
            -3.0 - (TAU - 6.0),
            1e-5,
            "negative",
        );
        near(
            lerp_angle(0.0, 7.0, 1.0),
            7.0 - TAU,
            1e-5,
            "wraps targets beyond TAU",
        );
    }

    #[test]
    fn pose_smoother_snaps_above_1_5_m() {
        let mut s = PoseSmoother::default();
        s.step(1.0, 1.0, 0.0, 0.016);
        assert_eq!(s.x, 1.0, "first sample snaps");
        s.step(2.6, 1.0, 1.0, 1.0 / 60.0);
        assert_eq!(s.x, 2.6, "1.6 m jump snaps");
        assert_eq!(s.heading, 1.0);
        s.step(3.6, 1.0, 1.0, 1.0 / 60.0);
        let t = (0.15f64 + 1.0 * 1.4).min(0.95);
        near(
            s.x,
            2.6 + 1.0 * t,
            1e-5,
            "1.0 m step lerps with the adaptive rate",
        );
        let mut s2 = PoseSmoother::default();
        s2.snap(0.0, 0.0, 3.0);
        s2.step(0.1, 0.0, -3.0, 1.0 / 60.0);
        let t2 = 0.15 + 0.1 * 1.4;
        near(
            s2.heading,
            3.0 + (TAU - 6.0) * t2,
            1e-5,
            "heading takes the short arc",
        );
        near(s2.x, 0.1 * t2, 1e-5, "x");
    }

    #[test]
    fn smoother_ignores_non_finite_samples() {
        let mut s = PoseSmoother::default();
        s.step(2.0, 4.0, 0.0, 0.016);
        s.step(f64::NAN, 4.0, 0.0, 0.016);
        s.step(2.0, f64::INFINITY, 0.0, 0.016);
        s.step(2.0, 4.0, f64::NAN, 0.016);
        assert_eq!([s.x, s.y, s.heading], [2.0, 4.0, 0.0]);
        s.step(2.5, 4.0, 0.1, 0.016);
        assert!(
            s.x > 2.0 && s.x < 2.5,
            "valid samples keep smoothing: {}",
            s.x
        );
    }

    #[test]
    fn smoother_resnaps_from_a_poisoned_state() {
        let mut s = PoseSmoother::default();
        s.snap(f64::NAN, 4.0, 0.0);
        s.step(3.0, 5.0, 1.0, 0.016);
        assert_eq!([s.x, s.y, s.heading], [3.0, 5.0, 1.0]);
    }

    const DT: f64 = 1.0 / 60.0;

    fn view(mode: CameraMode, angle: f64, zoom: f64) -> MapView {
        MapView { mode, angle, zoom }
    }

    #[test]
    fn minimap_camera_math() {
        near(MinimapCamera::target_phi(0.0), 1.35, 1e-12, "phi 0");
        near(MinimapCamera::target_phi(1.0), 0.08, 1e-12, "phi 1");
        near(MinimapCamera::target_dist(0.0), 11.05, 1e-12, "dist 0");
        near(MinimapCamera::target_dist(1.0), 2.0, 1e-12, "dist 1");
        near(
            MinimapCamera::desired_theta(CameraMode::Follow, 0.3, None),
            0.3 + FRAC_PI_2,
            1e-12,
            "follow",
        );
        near(
            MinimapCamera::desired_theta(CameraMode::Driver, 0.3, Some(true)),
            -FRAC_PI_2,
            1e-12,
            "driver red",
        );
        near(
            MinimapCamera::desired_theta(CameraMode::Driver, 0.3, Some(false)),
            FRAC_PI_2,
            1e-12,
            "driver blue",
        );
        near(
            MinimapCamera::desired_theta(CameraMode::Driver, 0.3, None),
            FRAC_PI_2,
            1e-12,
            "unknown alliance = blue",
        );
        let t = MinimapCamera::desired_target(Vec3::new(6.0, 0.0, -2.0), 0.5);
        vec_near(
            t,
            Vec3::new(6.0, 0.3, -1.0),
            1e-9,
            "target z blends toward the robot with zoom",
        );

        let mut cam = MinimapCamera::default();
        let mut v = view(CameraMode::Follow, 0.3, 0.5);
        cam.step(0.016, Vec3::new(6.0, 0.0, 0.0), 0.0, v, None);
        let pos = cam.position();
        near(
            pos.distance_to(cam.target),
            MinimapCamera::target_dist(0.5),
            1e-5,
            "distance",
        );
        assert!(
            pos.x > cam.target.x + 1.0,
            "follow camera at heading 0 sits behind the robot (+X)"
        );
        near(
            ((pos.y - cam.target.y) / cam.dist).acos(),
            MinimapCamera::target_phi(0.3),
            1e-5,
            "polar angle",
        );
        v.zoom = 1.0;
        cam.step(DT, Vec3::new(6.0, 0.0, 0.0), 0.0, v, None);
        near(
            cam.dist,
            6.525 + (2.0 - 6.525) * 0.1,
            1e-6,
            "distance eases at dt_lerp(0.1)",
        );
    }

    #[test]
    fn angle_and_zoom_map_linearly() {
        for a in [0.0, 0.25, 0.3, 0.5, 1.0] {
            near(
                MinimapCamera::target_phi(a),
                1.35 - a * (1.35 - 0.08),
                1e-12,
                "phi",
            );
        }
        for z in [0.0, 0.5, 1.0] {
            near(
                MinimapCamera::target_dist(z),
                11.05 + z * (2.0 - 11.05),
                1e-12,
                "dist",
            );
        }
    }

    #[test]
    fn target_follows_robot_x_and_blends_z_with_zoom() {
        let w = Vec3::new(-3.0, 0.0, 2.0);
        vec_near(
            MinimapCamera::desired_target(w, 0.0),
            Vec3::new(-3.0, 0.3, 0.0),
            1e-9,
            "zoom 0: centered on the short axis",
        );
        vec_near(
            MinimapCamera::desired_target(w, 1.0),
            Vec3::new(-3.0, 0.3, 2.0),
            1e-9,
            "zoom 1: on the robot",
        );
    }

    #[test]
    fn settled_camera_matches_the_formula_for_every_mode() {
        let robot = Vec3::new(-2.0, 0.0, 1.5);
        for mode in [CameraMode::Follow, CameraMode::Driver] {
            for red in [None, Some(false), Some(true)] {
                let settings = view(mode, 0.7, 0.25);
                let mut cam = MinimapCamera::default();
                cam.step(DT, robot, 0.4, view(CameraMode::Follow, 0.0, 1.0), None);
                for _ in 0..900 {
                    cam.step(DT, robot, 0.4, settings, red);
                }
                let phi = MinimapCamera::target_phi(0.7);
                let r = MinimapCamera::target_dist(0.25);
                let theta = MinimapCamera::desired_theta(mode, 0.4, red);
                let target = MinimapCamera::desired_target(robot, 0.25);
                let want = Vec3::new(
                    target.x + r * phi.sin() * theta.sin(),
                    target.y + r * phi.cos(),
                    target.z + r * phi.sin() * theta.cos(),
                );
                assert!(
                    cam.position().distance_to(want) < 1e-4,
                    "{mode:?} red={red:?}: {:?} vs {want:?}",
                    cam.position()
                );
            }
        }
    }

    #[test]
    fn driver_mode_views_from_the_alliance_wall() {
        let mut cam = MinimapCamera::default();
        cam.step(
            DT,
            Vec3::ZERO,
            1.0,
            view(CameraMode::Driver, 0.3, 0.5),
            Some(false),
        );
        assert!(cam.position().x > 0.5, "blue: camera on the +X (blue) side");
        let mut cam = MinimapCamera::default();
        cam.step(
            DT,
            Vec3::ZERO,
            1.0,
            view(CameraMode::Driver, 0.3, 0.5),
            Some(true),
        );
        assert!(cam.position().x < -0.5, "red: camera on the -X (red) side");
    }

    #[test]
    fn theta_takes_the_short_arc() {
        let mut cam = MinimapCamera::default();
        let follow = MapView::default();
        cam.step(DT, Vec3::ZERO, PI - 0.1 - FRAC_PI_2, follow, None);
        let start = cam.theta;
        cam.step(DT, Vec3::ZERO, -PI + 0.1 - FRAC_PI_2, follow, None);
        assert!(
            cam.theta > start,
            "wraps forward across +-PI instead of swinging back"
        );
        near(cam.theta - start, 0.2 * dt_lerp(0.1, DT), 1e-6, "step");
    }
}
