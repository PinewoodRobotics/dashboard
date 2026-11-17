/// The last run that played to the end untouched (no seek, speed change or
/// scrub on the way); `wall_s` spans from the first tick after `play` to the
/// tick that reached the end.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LastRun {
    pub from_t: f64,
    pub wall_s: f64,
    pub speed: f64,
}

/// Playback time shared by every auto preview (touchscreen tab, HUD ghost).
/// Time follows the wall clock passed to `tick`, never frame deltas, and a
/// scrub holds t while keeping the play state for when the finger lifts.
#[derive(Clone, Debug, PartialEq)]
pub struct AutoClock {
    pub t: f64,
    pub duration: f64,
    pub playing: bool,
    pub speed: f64,
    pub looping: bool,
    pub scrubbing: bool,
    pub last_run: Option<LastRun>,
    last_us: Option<i64>,
    run_start_us: Option<i64>,
    run_from_t: f64,
    run_clean: bool,
}

impl Default for AutoClock {
    fn default() -> Self {
        Self {
            t: 0.0,
            duration: 0.0,
            playing: false,
            speed: 1.0,
            looping: false,
            scrubbing: false,
            last_run: None,
            last_us: None,
            run_start_us: None,
            run_from_t: 0.0,
            run_clean: false,
        }
    }
}

impl AutoClock {
    pub const SPEEDS: [f64; 3] = [0.5, 1.0, 2.0];

    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_duration(&mut self, seconds: f64) {
        self.duration = seconds.max(0.0);
        self.t = self.t.clamp(0.0, self.duration);
    }

    pub fn play(&mut self) {
        if self.duration <= 0.0 {
            return;
        }
        if self.t >= self.duration {
            self.t = 0.0;
        }
        self.playing = true;
        self.last_us = None;
        self.run_start_us = None;
        self.run_from_t = self.t;
        self.run_clean = true;
    }

    pub fn pause(&mut self) {
        self.playing = false;
    }

    pub fn toggle(&mut self) {
        if self.playing {
            self.pause()
        } else {
            self.play()
        }
    }

    pub fn seek(&mut self, seconds: f64) {
        self.t = seconds.clamp(0.0, self.duration);
        self.run_clean = false;
    }

    pub fn set_speed(&mut self, s: f64) {
        self.speed = if s > 0.0 { s } else { 1.0 };
        self.run_clean = false;
    }

    pub fn set_loop(&mut self, on: bool) {
        self.looping = on;
    }

    pub fn begin_scrub(&mut self) {
        self.scrubbing = true;
        self.run_clean = false;
    }

    pub fn end_scrub(&mut self) {
        self.scrubbing = false;
    }

    pub fn active(&self) -> bool {
        self.playing || self.scrubbing
    }

    /// Advances by the wall time since the previous tick; the first tick only
    /// records the time. Returns true when t changed.
    pub fn tick(&mut self, now_us: i64) -> bool {
        let dt = self
            .last_us
            .map_or(0.0, |last| ((now_us - last) as f64 / 1_000_000.0).max(0.0));
        self.last_us = Some(now_us);
        if self.playing && self.run_start_us.is_none() {
            self.run_start_us = Some(now_us);
        }
        let was_playing = self.playing;
        let moved = self.advance(dt);
        if was_playing && !self.playing && self.run_clean && self.t >= self.duration {
            let start = self.run_start_us.unwrap_or(now_us);
            self.last_run = Some(LastRun {
                from_t: self.run_from_t,
                wall_s: (now_us - start) as f64 / 1_000_000.0,
                speed: self.speed,
            });
        }
        moved
    }

    pub fn advance(&mut self, delta: f64) -> bool {
        if !self.playing || self.scrubbing || self.duration <= 0.0 {
            return false;
        }
        self.t += delta * self.speed;
        if self.t >= self.duration {
            if self.looping {
                self.t %= self.duration;
            } else {
                self.t = self.duration;
                self.playing = false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_advances_loops_and_stops() {
        let mut c = AutoClock::new();
        c.set_duration(2.0);
        assert!(!c.advance(0.5), "paused clock does not move");
        c.play();
        c.set_speed(2.0);
        c.advance(0.5);
        assert!((c.t - 1.0).abs() < 1e-12);
        c.advance(1.0);
        assert_eq!(c.t, 2.0);
        assert!(!c.playing, "stops at the end without loop");
        c.play();
        assert_eq!(c.t, 0.0, "play at the end restarts");
        c.looping = true;
        c.set_speed(0.5);
        c.advance(5.0);
        assert!((c.t - 0.5).abs() < 1e-12, "loops");
        assert!(c.playing);
        c.seek(-4.0);
        assert_eq!(c.t, 0.0);
        c.seek(9.0);
        assert_eq!(c.t, 2.0);
    }

    #[test]
    fn zero_duration_never_plays_and_bad_speed_resets() {
        let mut c = AutoClock::new();
        c.play();
        assert!(!c.playing);
        c.set_speed(-1.0);
        assert_eq!(c.speed, 1.0);
    }

    #[test]
    fn first_tick_only_records_time() {
        let mut c = AutoClock::new();
        c.set_duration(5.0);
        c.play();
        assert!(c.tick(1_000_000));
        assert_eq!(c.t, 0.0);
        c.tick(1_500_000);
        assert!((c.t - 0.5).abs() < 1e-12);
        c.tick(1_400_000);
        assert!(
            (c.t - 0.5).abs() < 1e-12,
            "a clock going backwards never rewinds"
        );
    }

    #[test]
    fn clean_run_is_recorded_and_a_seek_spoils_it() {
        let mut c = AutoClock::new();
        c.set_duration(1.0);
        c.play();
        c.tick(0);
        c.tick(1_200_000);
        assert_eq!(
            c.last_run,
            Some(LastRun {
                from_t: 0.0,
                wall_s: 1.2,
                speed: 1.0
            })
        );
        c.last_run = None;
        c.play();
        c.tick(2_000_000);
        c.seek(0.5);
        c.tick(3_000_000);
        assert!(!c.playing);
        assert_eq!(c.last_run, None);
    }
}
