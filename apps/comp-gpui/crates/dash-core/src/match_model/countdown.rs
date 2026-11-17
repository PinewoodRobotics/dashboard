//! One robot-published countdown (seconds remaining) shown at frame rate.
//! - Every received update re-anchors (ntcore drops repeated identical values,
//!   so "no update" can mean "value unchanged").
//! - Between updates it counts down locally, at most [`EXTRAPOLATE_CAP_S`].
//! - Once seq has advanced [`HOLD_AFTER_SEQ`] times without a new value, the
//!   robot is holding it (pre/post match, disabled gap): show it exactly.
//! - With the link down, a running timer keeps dead-reckoning (uncapped) and a
//!   held one stays put; the HUD dims it.

pub const EXTRAPOLATE_CAP_S: f64 = 0.1;
pub const HOLD_AFTER_SEQ: u32 = 2;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Countdown {
    pub value: f64,
    pub has_value: bool,
    pub anchor_us: i64,
    pub seq_since_anchor: u32,
    held_at_link_loss: bool,
}

impl Countdown {
    pub fn update(&mut self, v: f64, now_us: i64) {
        self.value = v;
        self.has_value = true;
        self.anchor_us = now_us;
        self.seq_since_anchor = 0;
    }

    pub fn on_seq(&mut self) {
        if self.has_value {
            self.seq_since_anchor += 1;
        }
    }

    pub fn is_held(&self) -> bool {
        self.seq_since_anchor >= HOLD_AFTER_SEQ
    }

    pub fn on_link_lost(&mut self) {
        self.held_at_link_loss = self.is_held();
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn display(&self, now_us: i64, link_ok: bool) -> f64 {
        if !self.has_value {
            return 0.0;
        }
        let elapsed = ((now_us - self.anchor_us) as f64 / 1e6).max(0.0);
        let shown = if link_ok {
            if self.is_held() {
                self.value
            } else {
                self.value - elapsed.min(EXTRAPOLATE_CAP_S)
            }
        } else if self.held_at_link_loss {
            self.value
        } else {
            self.value - elapsed
        };
        shown.max(0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: i64 = 1000;

    fn near(a: f64, b: f64, tol: f64, what: &str) {
        assert!((a - b).abs() <= tol, "{what}: {a} vs {b}");
    }

    #[test]
    fn anchor_and_capped_extrapolation() {
        let mut c = Countdown::default();
        assert_eq!(c.display(0, true), 0.0, "no value yet");
        c.update(100.0, 1_000_000);
        near(c.display(1_000_000, true), 100.0, 1e-9, "anchor");
        near(
            c.display(1_000_000 + 30 * MS, true),
            99.97,
            1e-9,
            "counts down between updates",
        );
        near(
            c.display(1_000_000 + 500 * MS, true),
            99.9,
            1e-9,
            "extrapolation capped at 100 ms",
        );
        c.update(99.5, 1_500_000);
        near(
            c.display(1_500_000 + 10 * MS, true),
            99.49,
            1e-9,
            "re-anchors on every update",
        );
        c.update(99.5, 1_520_000);
        near(
            c.display(1_520_000, true),
            99.5,
            1e-9,
            "an identical value re-anchors too",
        );
    }

    #[test]
    fn exact_hold_when_value_static_while_seq_advances() {
        let mut c = Countdown::default();
        c.update(140.0, 0);
        let mut t = 0;
        for i in 0..100 {
            t += 20 * MS;
            c.on_seq();
            let want = if i >= 1 { 140.0 } else { 139.98 };
            near(
                c.display(t, true),
                want,
                1e-9,
                &format!("held value at {} ms", t / MS),
            );
        }
        assert!(c.is_held());
        c.update(139.98, t + 5 * MS);
        assert!(!c.is_held(), "a new value ends the hold");
        near(c.display(t + 15 * MS, true), 139.97, 1e-9, "after hold");
    }
}
