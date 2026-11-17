use std::collections::HashMap;

use serde::Deserialize;

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct CommandEffect {
    #[serde(default)]
    pub aim: bool,
    #[serde(default)]
    pub shooter: bool,
    /// Wrist setpoint name (BOTTOM, MIDDLE, TOP).
    pub wrist: Option<String>,
    pub rollers: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct CommandSpec {
    #[serde(default)]
    pub registered: bool,
    #[serde(default)]
    pub end: String,
    #[serde(default)]
    pub effect: CommandEffect,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct WristConfig {
    #[serde(default = "default_travel_s")]
    pub travel_s: f64,
    #[serde(default)]
    pub at_setpoint_check: String,
    #[serde(default)]
    pub setpoints_rot: HashMap<String, f64>,
}

fn default_travel_s() -> f64 {
    0.5
}

impl Default for WristConfig {
    fn default() -> Self {
        Self {
            travel_s: default_travel_s(),
            at_setpoint_check: String::new(),
            setpoints_rot: HashMap::new(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct IntakeDefault {
    #[serde(default)]
    pub wrist: String,
    #[serde(default)]
    pub rollers: bool,
}

/// `data/auto_commands.json`: what each named command does on the robot.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct AutoCommands {
    #[serde(default)]
    pub auto_length_s: Option<f64>,
    #[serde(default)]
    pub robot_loop_s: Option<f64>,
    #[serde(default)]
    pub wrist: WristConfig,
    #[serde(default)]
    pub intake_default_command: IntakeDefault,
    #[serde(default)]
    pub commands: HashMap<String, CommandSpec>,
}

impl AutoCommands {
    pub fn builtin() -> Self {
        Self::parse(super::builtin::BUILTIN_COMMANDS).unwrap_or_default()
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        serde_json::from_str(text).map_err(|e| e.to_string())
    }

    pub fn effect(&self, command: &str) -> CommandEffect {
        self.commands
            .get(command)
            .map(|c| c.effect.clone())
            .unwrap_or_default()
    }

    /// How long a command that ends at its wrist setpoint runs.
    pub fn wrist_command_s(&self) -> f64 {
        if self.wrist.at_setpoint_check == "always_true" {
            self.robot_loop_s.unwrap_or(0.02)
        } else {
            self.wrist.travel_s
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_commands_parse() {
        let c = AutoCommands::builtin();
        assert_eq!(c.intake_default_command.wrist, "MIDDLE");
        assert_eq!(c.wrist.setpoints_rot["MIDDLE"], 0.338);
        assert!(c.effect("ContinuousAimCommand").aim);
        assert_eq!(
            c.effect("IntakeBottomCommand").wrist.as_deref(),
            Some("BOTTOM")
        );
        assert!(!c.commands["MoveClimberUp"].registered);
        assert_eq!(c.effect("Nope"), CommandEffect::default());
    }
}
