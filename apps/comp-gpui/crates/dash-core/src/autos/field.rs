use crate::playback::angle::wrap_pi;

pub const FIELD_LENGTH_M: f64 = 16.541;
pub const FIELD_WIDTH_M: f64 = 8.069;
pub const HALF_LENGTH_M: f64 = FIELD_LENGTH_M / 2.0;
pub const HALF_WIDTH_M: f64 = FIELD_WIDTH_M / 2.0;
/// PathPlannerLib FlippingUtil field size, which differs from the carpet.
pub const PP_FIELD_LENGTH_M: f64 = 16.54;
pub const PP_FIELD_WIDTH_M: f64 = 8.07;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FieldPoint {
    pub x: f64,
    pub y: f64,
}

impl FieldPoint {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub fn distance_to(self, other: FieldPoint) -> f64 {
        (self.x - other.x).hypot(self.y - other.y)
    }

    pub fn angle_to(self, other: FieldPoint) -> f64 {
        (other.y - self.y).atan2(other.x - self.x)
    }
}

/// WPILib blue-origin field pose: meters, heading in radians CCW.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Pose {
    pub x: f64,
    pub y: f64,
    pub heading: f64,
}

impl Pose {
    pub const fn new(x: f64, y: f64, heading: f64) -> Self {
        Self { x, y, heading }
    }

    pub fn point(self) -> FieldPoint {
        FieldPoint::new(self.x, self.y)
    }

    /// PathPlanner's rotational alliance flip.
    pub fn flipped(self) -> Pose {
        Pose::new(
            PP_FIELD_LENGTH_M - self.x,
            PP_FIELD_WIDTH_M - self.y,
            wrap_pi(self.heading + std::f64::consts::PI),
        )
    }
}

/// Godot world point of field.glb: Y up, field centered, blue alliance wall at +X.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct WorldPoint {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl WorldPoint {
    pub fn distance_to(self, o: WorldPoint) -> f64 {
        ((self.x - o.x).powi(2) + (self.y - o.y).powi(2) + (self.z - o.z).powi(2)).sqrt()
    }
}

pub fn to_world(x: f64, y: f64) -> WorldPoint {
    WorldPoint {
        x: HALF_LENGTH_M - x,
        y: 0.0,
        z: y - HALF_WIDTH_M,
    }
}

pub fn from_world(p: WorldPoint) -> FieldPoint {
    FieldPoint::new(HALF_LENGTH_M - p.x, p.z + HALF_WIDTH_M)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn world_round_trip_and_flip() {
        let w = to_world(3.0, 2.0);
        assert_eq!(from_world(w), FieldPoint::new(3.0, 2.0));
        assert!(to_world(15.0, 4.0).x < 0.0, "red wall is world -X");
        let f = Pose::new(1.0, 2.0, 0.5).flipped();
        assert!((f.x - 15.54).abs() < 1e-12 && (f.y - 6.07).abs() < 1e-12);
        assert!((f.heading - (0.5 - std::f64::consts::PI)).abs() < 1e-12);
    }
}
