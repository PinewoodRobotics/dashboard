//! Server clock estimate from RTT probes (core/nt/nt4_time_sync.gd).

const WINDOW: usize = 10;

#[derive(Clone, Debug)]
pub struct TimeSync {
    pub best_rtt_us: i64,
    pub offset_us: i64,
    pub sample_count: u64,
    samples: Vec<(i64, i64)>,
}

impl Default for TimeSync {
    fn default() -> Self {
        Self {
            best_rtt_us: -1,
            offset_us: 0,
            sample_count: 0,
            samples: Vec::with_capacity(WINDOW + 1),
        }
    }
}

impl TimeSync {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn has_sync(&self) -> bool {
        self.best_rtt_us >= 0
    }

    /// offset = now - rtt/2 - server, from the lowest-RTT sample of the last
    /// WINDOW.
    pub fn add_sample(&mut self, local_now_us: i64, sent_local_us: i64, server_us: i64) -> bool {
        let rtt = local_now_us - sent_local_us;
        if rtt < 0 || server_us <= 0 {
            return false;
        }
        self.samples.push((rtt, local_now_us - rtt / 2 - server_us));
        if self.samples.len() > WINDOW {
            self.samples.remove(0);
        }
        self.sample_count += 1;
        let best = *self.samples.iter().min_by_key(|s| s.0).unwrap();
        self.best_rtt_us = best.0;
        self.offset_us = best.1;
        true
    }

    pub fn server_now_us(&self, local_now_us: i64) -> i64 {
        local_now_us - self.offset_us
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lowest_rtt_sample_wins_within_window() {
        let mut s = TimeSync::default();
        assert!(!s.has_sync());
        assert!(s.add_sample(10_000, 6_000, 50_000));
        assert_eq!((s.best_rtt_us, s.offset_us), (4_000, 10_000 - 2_000 - 50_000));
        assert!(s.add_sample(20_000, 19_000, 60_000));
        assert_eq!(s.best_rtt_us, 1_000);
        assert_eq!(s.server_now_us(20_000), 60_500);
        assert!(!s.add_sample(5, 10, 1), "negative rtt");
        assert!(!s.add_sample(10, 5, 0), "no server time");
        for i in 0..10 {
            s.add_sample(100_000 + i, 100_000 + i - 3_000, 200_000);
        }
        assert_eq!(s.best_rtt_us, 3_000, "the 1 ms sample left the window");
    }
}
