//! A [`ControlLink`] over the mock data until the NT client lands: the
//! Request/State pairs in [`ControlTopics`] and the shooter readouts stand in
//! for the robot's topics, and [`echo`] plays the robot applying a request.

use std::time::Duration;

use dash_core::controls::{Controls, READOUT_ROWS};
use dash_core::request_state::{ControlLink, Value};
use gpui_kit::*;

use crate::mock::{ControlTopics, MockData, ShooterReadouts};

/// The speed the mock robot falls back to on the -1 sentinel
/// (touch_m6_base.json's Intake/Speed/State).
const COMPILED_SPEED: f64 = 0.5;
const ECHO_DELAY: Duration = Duration::from_millis(300);

pub struct MockLink<'a> {
    pub up: bool,
    pub topics: &'a mut ControlTopics,
    pub readouts: &'a ShooterReadouts,
}

fn readout(r: &ShooterReadouts, topic: &str) -> Option<Value> {
    let row = READOUT_ROWS.iter().find(|row| row.topic == topic)?;
    let num = |v: Option<f64>| v.map(Value::Double);
    let flag = |v: Option<bool>| v.map(Value::Bool);
    match row.label {
        "Mode" => flag(r.gps_assist_enabled),
        "Distance" => num(r.distance_to_target_m),
        "RPM target" => num(r.requested_rpm),
        "RPM actual" => num(r.velocity_rpm),
        "Leader" => num(r.leader_rpm),
        "Follower" => num(r.follower_rpm),
        "Spun up" => flag(r.is_spun_up),
        "Shooting" => flag(r.is_shooting),
        "Turret" => num(r.turret_position_deg),
        "Turret cmd" => num(r.turret_angle),
        _ => None,
    }
}

impl ControlLink for MockLink<'_> {
    fn connected(&self) -> bool {
        self.up
    }

    fn live(&self, topic: &str) -> bool {
        self.up && self.value(topic).is_some()
    }

    fn value(&self, topic: &str) -> Option<Value> {
        let t = &*self.topics;
        if topic == t.intake.topics.state {
            t.intake.state.map(Value::Double)
        } else if topic == t.aim_trim.topics.state {
            t.aim_trim.state.map(Value::Double)
        } else {
            readout(self.readouts, topic)
        }
    }

    fn publish(&mut self, topic: &str, value: Value) -> bool {
        let t = &mut *self.topics;
        if topic == t.intake.topics.request {
            t.intake.request = value.as_f64();
        } else if topic == t.aim_trim.topics.request {
            t.aim_trim.request = value.as_f64();
        }
        true
    }

    fn forget(&mut self, topic: &str) {
        self.release(topic);
    }

    fn release(&mut self, topic: &str) {
        let t = &mut *self.topics;
        if topic == t.intake.topics.request {
            t.intake.request = None;
        } else if topic == t.aim_trim.topics.request {
            t.aim_trim.request = None;
        }
    }
}

/// Runs `f` on the controllers with the mock link, then steps them and
/// persists the intake override, as ControlsService does each frame.
pub fn with_controls<R>(d: &mut MockData, f: impl FnOnce(&mut Controls, &mut MockLink) -> R) -> R {
    let MockData {
        control,
        controls,
        readouts,
        nt_connected,
        ..
    } = d;
    let mut link = MockLink {
        up: *nt_connected,
        topics: controls,
        readouts,
    };
    let r = f(control, &mut link);
    control.step(&mut link);
    link.topics.intake_stored = control.intake.requested();
    r
}

pub fn step(d: &mut MockData) {
    with_controls(d, |_, _| {});
}

/// Reads the controllers without changing the mock robot.
pub fn view<R>(d: &MockData, f: impl FnOnce(&Controls, &MockLink) -> R) -> R {
    let mut topics = d.controls.clone();
    let link = MockLink {
        up: d.nt_connected,
        topics: &mut topics,
        readouts: &d.readouts,
    };
    f(&d.control, &link)
}

/// The mock robot applies the current requests: the intake speed (the
/// compiled constant on the -1 sentinel) and the aim trim.
pub fn echo(d: &mut MockData) {
    if !d.nt_connected || d.live_nt {
        return;
    }
    let c = &mut d.controls;
    if let Some(r) = c.intake.request {
        c.intake.state = Some(if r < 0.0 { COMPILED_SPEED } else { r });
    }
    if let Some(r) = c.aim_trim.request {
        c.aim_trim.state = Some(r);
    }
    step(d);
}

/// Changes the controls now and lets the mock robot echo shortly after.
pub fn act(
    data: &Entity<MockData>,
    cx: &mut App,
    f: impl FnOnce(&mut Controls, &mut MockLink) + 'static,
) {
    data.update(cx, |d, cx| {
        with_controls(d, f);
        cx.notify();
    });
    let data = data.clone();
    cx.spawn(async move |cx| {
        cx.background_executor().timer(ECHO_DELAY).await;
        data.update(cx, |d, cx| {
            echo(d);
            cx.notify();
        });
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::{COMPILED_SPEED, echo, view, with_controls};
    use crate::mock::{MockData, Scenario};
    use dash_core::controls::{AimTrim, IntakeSpeed};

    fn statuses(d: &MockData) -> (String, String) {
        view(d, |c, l| (c.intake.status_line(l), c.trim.status_line(l)))
    }

    #[test]
    fn seeded_like_the_godot_fixture() {
        let d = MockData::new(Scenario::PreMatch);
        let (intake, trim) = statuses(&d);
        assert_eq!(intake, IntakeSpeed::STATUS_CONSTANT);
        assert_eq!(trim, AimTrim::STATUS_CONFIRMED);
        view(&d, |c, l| {
            assert_eq!(c.intake.slider_value(l), 0.5);
            let rows = c.readouts(l);
            assert_eq!(rows[0], ("Mode", "Auto shooter".to_string()));
            assert_eq!(rows[5], ("Follower", "3185".to_string()));
            assert_eq!(rows[9], ("Turret cmd", "-42.4°".to_string()));
        });
    }

    #[test]
    fn requests_wait_for_the_echo_then_confirm() {
        let mut d = MockData::new(Scenario::PreMatch);
        with_controls(&mut d, |c, l| {
            c.intake.set_speed(l, 0.42);
            c.trim.set_trim(l, 2.5);
        });
        assert_eq!(d.controls.intake_stored, Some(0.42));
        assert_eq!(d.controls.intake.request, Some(0.42));
        let (intake, trim) = statuses(&d);
        assert_eq!(intake, IntakeSpeed::STATUS_WAITING);
        assert_eq!(trim, AimTrim::STATUS_WAITING);
        echo(&mut d);
        let (intake, trim) = statuses(&d);
        assert_eq!(intake, IntakeSpeed::STATUS_CONFIRMED);
        assert_eq!(trim, AimTrim::STATUS_CONFIRMED);
        assert_eq!(d.control.trim.requested(), None);

        with_controls(&mut d, |c, l| c.intake.reset(l));
        assert_eq!(d.controls.intake_stored, None);
        echo(&mut d);
        assert_eq!(statuses(&d).0, IntakeSpeed::STATUS_CONSTANT);
        view(&d, |c, l| {
            assert_eq!(c.intake.slider_value(l), COMPILED_SPEED)
        });
    }

    #[test]
    fn disconnected_shows_dashes_and_blocks_the_trim() {
        let mut d = MockData::new(Scenario::NtDisconnected);
        let sent = with_controls(&mut d, |c, l| c.trim.set_trim(l, 1.0));
        assert!(!sent);
        let (intake, trim) = statuses(&d);
        assert_eq!(intake, IntakeSpeed::STATUS_DISCONNECTED);
        assert_eq!(trim, AimTrim::STATUS_DISCONNECTED);
        view(&d, |c, l| {
            assert!(c.readouts(l).iter().all(|(_, v)| v == "--"));
        });
    }
}
