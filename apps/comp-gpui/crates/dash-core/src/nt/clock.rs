use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Instant;

/// Microsecond clock shared by the client and its transport worker, so RTT
/// probe stamps, receive stamps and publish timestamps agree. Tests use a
/// manual clock that only moves when told to.
#[derive(Clone, Debug, Default)]
pub struct Clock {
    manual: Option<Arc<AtomicI64>>,
}

fn origin() -> Instant {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    *ORIGIN.get_or_init(Instant::now)
}

impl Clock {
    pub fn real() -> Self {
        origin();
        Self { manual: None }
    }

    pub fn manual(start_us: i64) -> Self {
        Self {
            manual: Some(Arc::new(AtomicI64::new(start_us))),
        }
    }

    pub fn now_us(&self) -> i64 {
        match &self.manual {
            Some(t) => t.load(Ordering::Relaxed),
            None => origin().elapsed().as_micros() as i64 + 1,
        }
    }

    pub fn advance_us(&self, us: i64) {
        self.manual
            .as_ref()
            .expect("advance on a real clock")
            .fetch_add(us, Ordering::Relaxed);
    }

    pub fn advance_s(&self, s: f64) {
        self.advance_us((s * 1_000_000.0).round() as i64);
    }
}
