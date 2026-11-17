//! Lane-alignment toast (MatchHUD.tsx): the first value after start or after a
//! match returns to pre-match is stored silently; afterwards every change fires
//! a toast that replaces the visible one and lasts [`DURATION_S`].

pub const DURATION_S: f64 = 1.8;
const DURATION_US: i64 = (DURATION_S * 1e6) as i64;

#[derive(Clone, Debug, PartialEq)]
pub struct LaneToast {
    seen: bool,
    last: bool,
    pub visible_on: bool,
    /// The latest fire; -1 before the first.
    pub fired_us: i64,
    /// When the current visible span began. A fire while the toast is still
    /// up replaces it in place (Sonner's shared id), so this does not move.
    pub entered_us: i64,
    pub fire_count: u32,
}

impl Default for LaneToast {
    fn default() -> Self {
        Self {
            seen: false,
            last: false,
            visible_on: false,
            fired_us: -1,
            entered_us: -1,
            fire_count: 0,
        }
    }
}

impl LaneToast {
    pub fn reset(&mut self) {
        self.seen = false;
        self.last = false;
    }

    /// Returns true when this value fired a toast.
    pub fn observe(&mut self, v: bool, now_us: i64) -> bool {
        if !self.seen {
            self.seen = true;
            self.last = v;
            return false;
        }
        if v == self.last {
            return false;
        }
        if !self.is_visible(now_us) {
            self.entered_us = now_us;
        }
        self.last = v;
        self.visible_on = v;
        self.fired_us = now_us;
        self.fire_count += 1;
        true
    }

    pub fn is_visible(&self, now_us: i64) -> bool {
        self.fired_us >= 0 && now_us - self.fired_us < DURATION_US
    }

    /// 0..1 of the toast lifetime, or None when hidden.
    pub fn progress(&self, now_us: i64) -> Option<f64> {
        self.is_visible(now_us)
            .then(|| (now_us - self.fired_us) as f64 / DURATION_US as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: i64 = 1_000_000;

    #[test]
    fn first_value_silent_then_changes_fire() {
        let mut t = LaneToast::default();
        assert!(!t.observe(true, 0), "first value is stored silently");
        assert!(!t.is_visible(0));
        assert!(!t.observe(true, S), "same value does nothing");
        assert!(t.observe(false, 2 * S), "change fires");
        assert!(t.is_visible(2 * S) && !t.visible_on);
        assert!(t.observe(true, 3 * S));
        assert_eq!(t.fire_count, 2);
    }

    #[test]
    fn duration_and_replace_in_place() {
        let mut t = LaneToast::default();
        t.observe(false, 0);
        t.observe(true, 10 * S);
        assert!(t.is_visible(10 * S + 1_790_000));
        assert!(!t.is_visible(10 * S + 1_800_000), "1.8 s lifetime");
        t.observe(false, 20 * S);
        t.observe(true, 21 * S);
        assert!(t.visible_on, "the newest toast replaces the previous one");
        assert!(
            t.is_visible(21 * S + 1_700_000),
            "replacing restarts the 1.8 s"
        );
        assert!(!t.is_visible(21 * S + 1_800_000));
        let p = t.progress(21 * S + 900_000).unwrap();
        assert!((p - 0.5).abs() < 1e-9);
        assert_eq!(t.progress(30 * S), None);
    }

    #[test]
    fn replacing_keeps_the_entry_time() {
        let mut t = LaneToast::default();
        t.observe(false, 0);
        t.observe(true, 10 * S);
        assert_eq!(t.entered_us, 10 * S);
        t.observe(false, 11 * S);
        assert_eq!(t.entered_us, 10 * S, "replaced while visible: no re-entry");
        assert_eq!(t.fired_us, 11 * S);
        t.observe(true, 13 * S);
        assert_eq!(
            t.entered_us,
            13 * S,
            "a toast after the last one ended enters anew"
        );
    }
}
