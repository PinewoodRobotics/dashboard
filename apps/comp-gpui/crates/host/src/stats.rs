use std::time::{Duration, Instant};

#[derive(Default, Clone, Copy)]
pub struct FpsCounter {
    window_start: Option<Instant>,
    count: u32,
    pub fps: f32,
}

impl FpsCounter {
    pub fn tick(&mut self) {
        let now = Instant::now();
        let start = *self.window_start.get_or_insert(now);
        self.count += 1;
        let elapsed = now - start;
        if elapsed >= Duration::from_millis(500) {
            self.fps = self.count as f32 / elapsed.as_secs_f32();
            self.count = 0;
            self.window_start = Some(now);
        }
    }
}

/// Exponential moving average that starts at its first sample.
#[derive(Default, Clone, Copy)]
pub struct Smoothed {
    pub value: f32,
    primed: bool,
}

impl Smoothed {
    pub fn push(&mut self, sample: f32) {
        if self.primed {
            self.value += (sample - self.value) * 0.1;
        } else {
            self.value = sample;
            self.primed = true;
        }
    }

    pub fn get(&self) -> Option<f32> {
        self.primed.then_some(self.value)
    }
}

pub fn fmt_ms(value: Option<f32>) -> String {
    value
        .map(|ms| format!("{ms:.2}"))
        .unwrap_or_else(|| "-".into())
}
