//! Integer enums published by the robot (MatchStatusCalculator.java). Unknown
//! or malformed values map to the first variant, as the web dashboard does.

use crate::request_state::Value;

/// An in-range integer, or an integral finite double; anything else is None.
fn index(v: &Value, count: usize) -> Option<usize> {
    let i = match *v {
        Value::Int(i) => i,
        Value::Double(d) if d.is_finite() && d == d.floor() => d as i64,
        _ => return None,
    };
    usize::try_from(i).ok().filter(|&i| i < count)
}

macro_rules! robot_enum {
    ($(#[$doc:meta])* $name:ident { $($variant:ident = $wire:literal),+ $(,)? }) => {
        $(#[$doc])*
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
        pub enum $name {
            #[default]
            $($variant),+
        }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),+];
            pub const NAMES: &'static [&'static str] = &[$($wire),+];

            pub fn from_value(v: &Value) -> Self {
                index(v, Self::ALL.len()).map_or(Self::default(), |i| Self::ALL[i])
            }

            pub fn index(self) -> usize {
                self as usize
            }

            pub fn name(self) -> &'static str {
                Self::NAMES[self as usize]
            }

            pub fn to_value(self) -> Value {
                Value::Int(self as i64)
            }
        }
    };
}

robot_enum!(Phase {
    PreMatch = "pre_match",
    Autonomous = "autonomous",
    Transition = "transition",
    Shift1 = "shift1",
    Shift2 = "shift2",
    Shift3 = "shift3",
    Shift4 = "shift4",
    Endgame = "endgame",
    PostMatch = "post_match",
});

robot_enum!(Hub {
    None = "none",
    Both = "both",
    Active = "active",
    Warning = "warning",
    Inactive = "inactive",
});

robot_enum!(Header {
    Hidden = "hidden",
    Green = "green",
    Yellow = "yellow",
    Purple = "purple",
});

robot_enum!(Aim {
    ShooterDisabled = "shooter_disabled",
    GpsAuto = "gps_auto",
    ManualAiming = "manual_aiming",
});

impl Phase {
    /// Both hubs count, so the shift indicator shows the period clock.
    pub fn is_both_hub_period(self) -> bool {
        matches!(self, Phase::Autonomous | Phase::Transition | Phase::Endgame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phase_mapping() {
        for (i, p) in Phase::ALL.iter().enumerate() {
            assert_eq!(Phase::from_value(&Value::Int(i as i64)), *p);
        }
        assert_eq!(Phase::from_value(&Value::Int(3)).name(), "shift1");
        assert_eq!(
            Phase::from_value(&Value::Double(8.0)),
            Phase::PostMatch,
            "integral double"
        );
    }

    #[test]
    fn unknown_values_map_to_defaults() {
        let bad = [
            Value::Int(-1),
            Value::Int(9),
            Value::Int(42),
            Value::Double(2.5),
            Value::Double(f64::NAN),
            Value::Double(f64::INFINITY),
            Value::String("3".into()),
            Value::Bool(true),
            Value::StringArray(vec!["1".into()]),
        ];
        for v in &bad {
            assert_eq!(Phase::from_value(v), Phase::PreMatch, "phase {v:?}");
            assert_eq!(Hub::from_value(v), Hub::None, "hub {v:?}");
            assert_eq!(Header::from_value(v), Header::Hidden, "header {v:?}");
            assert_eq!(Aim::from_value(v), Aim::ShooterDisabled, "aim {v:?}");
        }
        assert_eq!(Hub::from_value(&Value::Int(5)), Hub::None);
        assert_eq!(Header::from_value(&Value::Int(4)), Header::Hidden);
        assert_eq!(Aim::from_value(&Value::Int(3)), Aim::ShooterDisabled);
    }

    #[test]
    fn enum_values_match_robot() {
        assert_eq!(Hub::from_value(&Value::Int(3)), Hub::Warning);
        assert_eq!(Header::from_value(&Value::Int(1)), Header::Green);
        assert_eq!(Header::from_value(&Value::Int(2)), Header::Yellow);
        assert_eq!(Header::from_value(&Value::Int(3)), Header::Purple);
        assert_eq!(Aim::from_value(&Value::Int(1)), Aim::GpsAuto);
        assert_eq!(Aim::from_value(&Value::Int(2)), Aim::ManualAiming);
        assert_eq!(Header::NAMES, ["hidden", "green", "yellow", "purple"]);
        assert_eq!(
            Hub::NAMES,
            ["none", "both", "active", "warning", "inactive"]
        );
        assert_eq!(Phase::Shift2.to_value(), Value::Int(4));
    }
}
