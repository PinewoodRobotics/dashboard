//! Auto preview playback (L2): one exported auto sampled as a pure function of
//! t ([`AutoPlayback`]), its mechanisms and timeline ([`AutoMechanisms`]), the
//! shared wall-clock driven [`AutoClock`] and the pre-match
//! [`StartPoseCheck`]. Ports Godot's `core/auto/{auto_playback, auto_clock,
//! auto_mechanisms, start_pose_check}.gd`.

pub mod angle;
mod auto;
mod clock;
mod mechanisms;
mod start_pose;

pub use auto::{Alliance, AutoEvent, AutoPlayback, AutoWarning, Channel, Sample, Segment};
pub use clock::{AutoClock, LastRun};
pub use mechanisms::{
    AimSource, AutoMechanisms, ItemKind, MechanismState, RawJoints, TimelineItem,
};
pub use start_pose::{StartPoseCheck, StartPoseLevel, distance_text};
