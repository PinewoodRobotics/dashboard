use std::time::Instant;

/// Monotonic microseconds, frozen for fixtures and tests so countdowns show
/// exactly the published values.
#[derive(Clone, Debug)]
pub struct Clock {
    origin: Instant,
    frozen_us: Option<i64>,
}

impl Default for Clock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock {
    pub fn new() -> Self {
        Self {
            origin: Instant::now(),
            frozen_us: None,
        }
    }

    pub fn frozen(at_us: i64) -> Self {
        Self {
            origin: Instant::now(),
            frozen_us: Some(at_us),
        }
    }

    pub fn now_us(&self) -> i64 {
        self.frozen_us
            .unwrap_or_else(|| self.origin.elapsed().as_micros() as i64)
    }

    pub fn freeze(&mut self) {
        self.frozen_us = Some(self.now_us());
    }

    pub fn is_frozen(&self) -> bool {
        self.frozen_us.is_some()
    }

    /// Panics on a running clock.
    pub fn advance_us(&mut self, us: i64) {
        *self
            .frozen_us
            .as_mut()
            .expect("Clock::advance_us requires a frozen clock") += us;
    }

    pub fn advance_s(&mut self, s: f64) {
        self.advance_us((s * 1e6).round() as i64);
    }
}
