use super::angle::angle_difference;
use crate::autos::field::Pose;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartPoseLevel {
    Ok,
    Off,
    Invalid,
}

/// Pre-match placement: the live robot pose against the auto's first pose.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StartPoseCheck {
    pub dist_m: f64,
    pub heading_deg: f64,
    pub level: StartPoseLevel,
}

impl StartPoseCheck {
    pub const OK_M: f64 = 0.15;
    pub const OK_DEG: f64 = 8.0;

    pub fn compare(robot: Pose, start: Pose, pose_valid: bool) -> Self {
        let dist_m = robot.point().distance_to(start.point());
        let heading_deg = angle_difference(robot.heading, start.heading)
            .to_degrees()
            .abs();
        let level = if !pose_valid {
            StartPoseLevel::Invalid
        } else if dist_m <= Self::OK_M && heading_deg <= Self::OK_DEG {
            StartPoseLevel::Ok
        } else {
            StartPoseLevel::Off
        };
        Self {
            dist_m,
            heading_deg,
            level,
        }
    }

    pub fn text(&self) -> String {
        match self.level {
            StartPoseLevel::Ok => format!(
                "On start pose ({:.2} m / {:.0}°)",
                self.dist_m, self.heading_deg
            ),
            StartPoseLevel::Off => {
                format!(
                    "Start pose off by {} / {:.0}°",
                    distance_text(self.dist_m),
                    self.heading_deg
                )
            }
            StartPoseLevel::Invalid => "Start pose unknown: robot pose not valid".into(),
        }
    }
}

pub fn distance_text(m: f64) -> String {
    if m < 10.0 {
        format!("{m:.2} m")
    } else {
        format!("{m:.1} m")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn on_the_start_pose() {
        let c = StartPoseCheck::compare(
            Pose::new(3.37, 4.03, 2.36),
            Pose::new(3.40, 4.10, 2.40),
            true,
        );
        assert!((c.dist_m - 0.03f64.hypot(0.07)).abs() < 1e-5);
        assert!((c.heading_deg - 0.04f64.to_degrees()).abs() < 1e-4);
        assert_eq!(c.level, StartPoseLevel::Ok);
        assert_eq!(c.text(), "On start pose (0.08 m / 2°)");
    }

    #[test]
    fn off_by_distance_or_heading() {
        let far = StartPoseCheck::compare(Pose::new(1.0, 2.0, 0.0), Pose::new(3.0, 2.0, 0.0), true);
        assert_eq!(far.level, StartPoseLevel::Off);
        assert_eq!(far.text(), "Start pose off by 2.00 m / 0°");
        let turned = StartPoseCheck::compare(
            Pose::new(3.0, 2.0, 20f64.to_radians()),
            Pose::new(3.0, 2.0, 0.0),
            true,
        );
        assert_eq!(
            turned.level,
            StartPoseLevel::Off,
            "position alone is not enough"
        );
        assert_eq!(turned.text(), "Start pose off by 0.00 m / 20°");
        let edge = StartPoseCheck::compare(
            Pose::default(),
            Pose::new(
                StartPoseCheck::OK_M - 1e-4,
                0.0,
                (StartPoseCheck::OK_DEG - 0.01).to_radians(),
            ),
            true,
        );
        assert_eq!(
            edge.level,
            StartPoseLevel::Ok,
            "just inside both tolerances"
        );
        assert_eq!(distance_text(12.345), "12.3 m");
    }

    #[test]
    fn heading_wraps() {
        let c = StartPoseCheck::compare(
            Pose::new(1.0, 1.0, 179f64.to_radians()),
            Pose::new(1.0, 1.0, (-179f64).to_radians()),
            true,
        );
        assert!((c.heading_deg - 2.0).abs() < 1e-4);
        assert_eq!(c.level, StartPoseLevel::Ok);
    }

    #[test]
    fn invalid_pose() {
        let c = StartPoseCheck::compare(Pose::new(1.0, 1.0, 0.0), Pose::new(1.0, 1.0, 0.0), false);
        assert_eq!(c.level, StartPoseLevel::Invalid);
        assert_eq!(c.text(), "Start pose unknown: robot pose not valid");
    }
}
