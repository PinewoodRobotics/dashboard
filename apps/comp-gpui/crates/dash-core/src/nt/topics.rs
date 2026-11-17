//! Every topic the dashboard reads or writes (core/nt/topics.gd).

use super::protocol::SubOptions;

pub const MATCH_STATE_PREFIX: &str = "/matchhud/state/";

/// Every /matchhud/state/* topic the robot publishes (MatchStatusSubsystem.java).
pub const MATCH_STATE: [(&str, &str); 28] = [
    ("seq", "int"),
    ("robot_time_us", "int"),
    ("connected", "boolean"),
    ("is_red_alliance", "boolean"),
    ("enabled", "boolean"),
    ("autonomous", "boolean"),
    ("game_specific_message", "string"),
    ("match_phase", "int"),
    ("hub_status", "int"),
    ("header_color", "int"),
    ("total_time_remaining_s", "double"),
    ("period_time_remaining_s", "double"),
    ("shift_time_remaining_s", "double"),
    ("shift_time_with_buffer_s", "double"),
    ("buffer_remaining_s", "double"),
    ("is_shooting", "boolean"),
    ("show_shift_indicator", "boolean"),
    ("show_buffer", "boolean"),
    ("robot_pose_x_m", "double"),
    ("robot_pose_y_m", "double"),
    ("robot_heading_rad", "double"),
    ("robot_pose_valid", "boolean"),
    ("auto_align_active", "boolean"),
    ("auto_align_distance_m", "double"),
    ("auto_align_ready", "boolean"),
    ("driver_override", "boolean"),
    ("aim_mode", "int"),
    ("camera_topic", "string"),
];

pub const JOINT_WRIST: &str = "/AdvantageKit/RealOutputs/IntakeSubsystem/WristPosition";
pub const JOINT_TURRET: &str = "/AdvantageKit/RealOutputs/Turret/PositionRot";
pub const JOINT_CLIMBER: &str = "/AdvantageKit/RealOutputs/Climber/CurrentHeightMeters";
pub const JOINT_TOPICS: [&str; 3] = [JOINT_WRIST, JOINT_TURRET, JOINT_CLIMBER];

pub const READOUT_DISTANCE: &str = "/AdvantageKit/RealOutputs/Turret/DistanceToTarget";
pub const READOUT_REQUESTED_RPM: &str = "/AdvantageKit/RealOutputs/Shooter/RequestedVelocityRPM";
pub const READOUT_VELOCITY_RPM: &str = "/AdvantageKit/RealOutputs/Shooter/VelocityRPM";
pub const READOUT_LEADER_RPM: &str = "/AdvantageKit/RealOutputs/Shooter/LeaderVelocityRPM";
pub const READOUT_FOLLOWER_RPM: &str = "/AdvantageKit/RealOutputs/Shooter/FollowerVelocityRPM";
pub const READOUT_TURRET_DEG: &str = "/AdvantageKit/RealOutputs/Turret/PositionDeg";
pub const READOUT_TURRET_ANGLE: &str = "/AdvantageKit/RealOutputs/Turret/Angle";
pub const READOUT_SPUN_UP: &str = "/AdvantageKit/RealOutputs/Shooter/IsSpunUp";
pub const READOUT_GPS_ASSIST: &str = "/AdvantageKit/RealOutputs/ShooterSubsystem/GPSAssistFeaturesEnabled";
pub const READOUT_IS_SHOOTING: &str = "/AdvantageKit/RealOutputs/MatchStatus/isShooting";
pub const READOUT_TOPICS: [&str; 10] = [
    READOUT_DISTANCE,
    READOUT_REQUESTED_RPM,
    READOUT_VELOCITY_RPM,
    READOUT_LEADER_RPM,
    READOUT_FOLLOWER_RPM,
    READOUT_TURRET_DEG,
    READOUT_TURRET_ANGLE,
    READOUT_SPUN_UP,
    READOUT_GPS_ASSIST,
    READOUT_IS_SHOOTING,
];

pub const LANE_ADJUSTING_VELOCITY: &str = "/AdvantageKit/RealOutputs/SwerveSubsystem/AdjustingVelocity";

pub const AIM_TRIM_PUBLISH: &str = "/Tuning/Turret/AimTrimDeg";
pub const AIM_TRIM_READBACK: &str = "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg";

pub const PP_CURRENT_SELECTED_AUTO: &str = "/AdvantageKit/RealOutputs/PathPlanner/CurrentSelectedAuto";
pub const PP_SELECTED_AUTO_VALID: &str = "/AdvantageKit/RealOutputs/PathPlanner/SelectedAutoValid";
pub const PP_VALID_AUTOS: &str = "/AdvantageKit/RealOutputs/PathPlanner/ValidNames/Autos";
/// Optional: published only by robot code with the README's snippet.
pub const PP_DEPLOY_HASH: &str = "/AdvantageKit/RealOutputs/PathPlanner/DeployHash";

pub const PERIODIC_FAST: f64 = 0.02;
pub const PERIODIC_DEFAULT: f64 = 0.1;

pub fn match_topic(key: &str) -> String {
    format!("{MATCH_STATE_PREFIX}{key}")
}

#[derive(Clone, Debug, PartialEq)]
pub struct SubscriptionGroup {
    pub topics: Vec<String>,
    pub options: SubOptions,
}

/// Sent in one batch on connect: the match table and the joints at 20 ms,
/// everything else at the server default 100 ms. `auto_state` and
/// `intake_state` are the State topics of the two Request/State pairs.
pub fn subscription_groups(auto_state: &str, intake_state: &str) -> Vec<SubscriptionGroup> {
    let mut slow: Vec<String> = READOUT_TOPICS.iter().map(|s| s.to_string()).collect();
    slow.extend(
        [
            LANE_ADJUSTING_VELOCITY,
            AIM_TRIM_READBACK,
            auto_state,
            intake_state,
            PP_CURRENT_SELECTED_AUTO,
            PP_SELECTED_AUTO_VALID,
            PP_VALID_AUTOS,
            PP_DEPLOY_HASH,
        ]
        .map(String::from),
    );
    vec![
        SubscriptionGroup {
            topics: vec![MATCH_STATE_PREFIX.into()],
            options: SubOptions {
                prefix: true,
                periodic: Some(PERIODIC_FAST),
                ..Default::default()
            },
        },
        SubscriptionGroup {
            topics: JOINT_TOPICS.map(String::from).to_vec(),
            options: SubOptions {
                periodic: Some(PERIODIC_FAST),
                ..Default::default()
            },
        },
        SubscriptionGroup {
            topics: slow,
            options: SubOptions {
                periodic: Some(PERIODIC_DEFAULT),
                ..Default::default()
            },
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_cover_every_read_topic() {
        let g = subscription_groups("/Shared/PathPlanner/SelectedPath/State", "/Shared/Intake/Speed/State");
        assert_eq!(g.len(), 3);
        assert!(g[0].options.prefix);
        assert_eq!(g[0].topics, vec!["/matchhud/state/".to_string()]);
        assert_eq!(g[1].topics.len(), 3);
        assert_eq!(g[2].topics.len(), 18);
        assert!(g[2].topics.contains(&"/Shared/Intake/Speed/State".to_string()));
        assert_eq!(match_topic("seq"), "/matchhud/state/seq");
    }
}
