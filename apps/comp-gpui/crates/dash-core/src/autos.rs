//! Auto library (L1): the PathPlanner export the Godot app reads
//! (`apps/comp-godot/data/{autos, auto_meta.json, auto_commands.json}`), with
//! per-file validation, event-update vs built-in sources, export freshness
//! against the robot's deploy hash, the robot's aim point, path ribbons and
//! overlays, and [`AutosModel`], which ties the library to the preview clock
//! (L2) the Auto tab, preview panel and HUD read. Ports Godot's
//! `core/auto/{auto_library, export_freshness, aim_point, path_ribbon}.gd`,
//! `scenes3d/auto/auto_path_overlay.gd` and `services/autos_service.gd`.

pub mod aim_point;
mod builtin;
pub mod commands;
pub mod field;
pub mod freshness;
mod library;
mod model;
pub mod overlay;
pub mod ribbon;
mod source_hash;

pub use commands::AutoCommands;
pub use field::{FieldPoint, Pose, WorldPoint};
pub use freshness::{Freshness, FreshnessLevel};
pub use library::{
    AutoLibrary, AutoMeta, ExportIndex, ExportSource, FORMAT_VERSION, IndexAuto, IndexPath,
    MetaMap, builtin_meta, parse_meta,
};
pub use model::{AutosModel, HudAuto, HudOverlay, LivePose, PreviewFrame, PreviewInputs};
pub use overlay::PathOverlay;
pub use source_hash::{sha256_hex, source_hash};

#[cfg(test)]
mod tests;
