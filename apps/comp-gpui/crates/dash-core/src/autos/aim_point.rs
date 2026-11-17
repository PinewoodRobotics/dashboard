//! Port of the robot's AimPoint.java (FIR 2026Rebuilt util/AimPoint.java):
//! zones and targets are blue-perspective field fractions; on red the robot
//! mirrors X across the field center (not the PathPlanner rotation), and
//! outside every zone the nearest zone center wins.

use super::field::{FIELD_LENGTH_M, FIELD_WIDTH_M, FieldPoint, Pose};
use crate::playback::angle::wrap_pi;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AimZone {
    FrontOfHub,
    LeftCenter,
    MiddleCenter,
    RightCenter,
}

struct ZoneDef {
    zone: AimZone,
    min: (f64, f64),
    max: (f64, f64),
    target: (f64, f64),
}

const ZONES: [ZoneDef; 4] = [
    ZoneDef {
        zone: AimZone::FrontOfHub,
        min: (0.0, 0.0),
        max: (0.25, 1.0),
        target: (0.28, 0.5),
    },
    ZoneDef {
        zone: AimZone::LeftCenter,
        min: (0.25, 0.0),
        max: (0.5, 0.45),
        target: (0.2, 0.25),
    },
    ZoneDef {
        zone: AimZone::MiddleCenter,
        min: (0.25, 0.45),
        max: (0.5, 0.55),
        target: (0.5, 0.75),
    },
    ZoneDef {
        zone: AimZone::RightCenter,
        min: (0.25, 0.55),
        max: (0.5, 1.0),
        target: (0.2, 0.75),
    },
];

fn field(f: (f64, f64)) -> FieldPoint {
    FieldPoint::new(FIELD_LENGTH_M * f.0, FIELD_WIDTH_M * f.1)
}

fn mirror(p: FieldPoint, red: bool) -> FieldPoint {
    if red {
        FieldPoint::new(FIELD_LENGTH_M - p.x, p.y)
    } else {
        p
    }
}

fn zone_def(pos: FieldPoint, red: bool) -> &'static ZoneDef {
    let blue = mirror(pos, red);
    for z in &ZONES {
        let (lo, hi) = (field(z.min), field(z.max));
        if blue.x >= lo.x && blue.x < hi.x && blue.y >= lo.y && blue.y < hi.y {
            return z;
        }
    }
    let mut best = &ZONES[0];
    let mut best_d = f64::INFINITY;
    for z in &ZONES {
        let (lo, hi) = (field(z.min), field(z.max));
        let d = blue.distance_to(FieldPoint::new((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5));
        if d < best_d {
            best_d = d;
            best = z;
        }
    }
    best
}

pub fn zone(pos: FieldPoint, red: bool) -> AimZone {
    zone_def(pos, red).zone
}

pub fn target(pos: FieldPoint, red: bool) -> FieldPoint {
    mirror(field(zone_def(pos, red).target), red)
}

pub fn hub(red: bool) -> FieldPoint {
    mirror(field(ZONES[0].target), red)
}

/// Chassis-relative CCW angle ContinuousAimCommand turns to, without lead compensation.
pub fn turret_angle(pose: Pose, aim_at: FieldPoint) -> f64 {
    wrap_pi(pose.point().angle_to(aim_at) - pose.heading)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    #[test]
    fn aim_point_port() {
        assert_eq!(
            hub(false),
            FieldPoint::new(0.28 * FIELD_LENGTH_M, 0.5 * FIELD_WIDTH_M)
        );
        assert_eq!(
            hub(true),
            FieldPoint::new(FIELD_LENGTH_M - 0.28 * FIELD_LENGTH_M, 0.5 * FIELD_WIDTH_M)
        );
        assert!((hub(true).x - 0.72 * FIELD_LENGTH_M).abs() < 1e-9);
        assert_eq!(zone(FieldPoint::new(2.0, 4.0), false), AimZone::FrontOfHub);
        assert_eq!(zone(FieldPoint::new(14.5, 4.0), true), AimZone::FrontOfHub);
        assert_eq!(zone(FieldPoint::new(6.0, 1.0), false), AimZone::LeftCenter);
        assert_eq!(
            zone(FieldPoint::new(16.541 - 6.0, 1.0), true),
            AimZone::LeftCenter,
            "red mirrors X only"
        );
        assert_eq!(
            zone(FieldPoint::new(12.0, 4.0), false),
            AimZone::MiddleCenter,
            "outside every zone: nearest center"
        );
        assert!(
            (turret_angle(Pose::new(1.0, 1.0, 0.0), FieldPoint::new(2.0, 2.0)) - PI / 4.0).abs()
                < 1e-6
        );
        assert!(
            (turret_angle(Pose::new(1.0, 1.0, PI / 2.0), FieldPoint::new(2.0, 2.0)) + PI / 4.0)
                .abs()
                < 1e-6
        );
    }
}
