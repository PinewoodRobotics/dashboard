use std::time::{Duration, Instant};

pub type Easing = fn(f32) -> f32;

/// A value that animates toward a target. `play` restarts from an explicit
/// value like a CSS keyframe animation; `retarget` starts from wherever the
/// value is now like a CSS transition. Owners request animation frames while
/// `running` is true.
#[derive(Clone, Copy, Debug)]
pub struct Tween {
    from: f32,
    to: f32,
    start: Instant,
    duration: Duration,
    easing: Easing,
}

impl Tween {
    pub fn new(value: f32) -> Self {
        Self {
            from: value,
            to: value,
            start: Instant::now(),
            duration: Duration::ZERO,
            easing: crate::theme::ease_css,
        }
    }

    pub fn with_easing(mut self, easing: Easing) -> Self {
        self.easing = easing;
        self
    }

    pub fn play(&mut self, from: f32, to: f32, seconds: f32) {
        self.from = from;
        self.to = to;
        self.start = Instant::now();
        self.duration = Duration::from_secs_f32(seconds.max(0.0));
    }

    pub fn retarget(&mut self, to: f32, seconds: f32) {
        if (to - self.to).abs() < f32::EPSILON && self.running() {
            return;
        }
        let now = self.value();
        self.play(now, to, seconds);
    }

    pub fn jump(&mut self, value: f32) {
        self.from = value;
        self.to = value;
        self.duration = Duration::ZERO;
    }

    pub fn progress(&self) -> f32 {
        if self.duration.is_zero() {
            return 1.0;
        }
        (self.start.elapsed().as_secs_f32() / self.duration.as_secs_f32()).clamp(0.0, 1.0)
    }

    pub fn value(&self) -> f32 {
        let p = self.progress();
        if p >= 1.0 {
            return self.to;
        }
        self.from + (self.to - self.from) * (self.easing)(p)
    }

    pub fn target(&self) -> f32 {
        self.to
    }

    pub fn running(&self) -> bool {
        self.progress() < 1.0
    }
}
