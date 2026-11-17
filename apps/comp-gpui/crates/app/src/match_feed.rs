//! Feeds `/matchhud/state/*` and the lane signal into the match model the way
//! the NT client will: only values that changed arrive (ntcore drops repeats),
//! nothing arrives while the link is down, and a reconnect re-delivers every
//! current value.

use std::collections::HashMap;

use dash_core::match_model::{Clock, MatchEvent, MatchModel};
use dash_core::request_state::Value;

#[derive(Clone, Debug)]
pub struct MatchFeed {
    pub clock: Clock,
    pub model: MatchModel,
    delivered: HashMap<&'static str, Value>,
}

impl MatchFeed {
    pub fn new(clock: Clock) -> Self {
        Self {
            clock,
            model: MatchModel::new(),
            delivered: HashMap::new(),
        }
    }

    pub fn now_us(&self) -> i64 {
        self.clock.now_us()
    }

    pub fn set_link(&mut self, up: bool) -> Option<MatchEvent> {
        if up && !self.model.nt_ready {
            self.delivered.clear();
        }
        self.model.set_nt_ready(up, self.clock.now_us())
    }

    pub fn publish(&mut self, topics: Vec<(&'static str, Value)>) -> Vec<MatchEvent> {
        if !self.model.nt_ready {
            return Vec::new();
        }
        let now = self.clock.now_us();
        let mut events = Vec::new();
        for (key, value) in topics {
            if self.delivered.get(key) == Some(&value) {
                continue;
            }
            events.extend(self.model.ingest(key, &value, now));
            self.delivered.insert(key, value);
        }
        events
    }

    pub fn step(&mut self) -> Option<MatchEvent> {
        self.model.step(self.clock.now_us())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dash_core::match_model::{Banner, LANE_KEY};

    fn feed() -> MatchFeed {
        let mut f = MatchFeed::new(Clock::frozen(0));
        f.set_link(true);
        f
    }

    #[test]
    fn repeated_values_do_not_reanchor_so_a_held_timer_stays_exact() {
        let mut f = feed();
        for seq in 1..=5 {
            f.publish(vec![
                ("seq", Value::Int(seq)),
                ("total_time_remaining_s", Value::Double(140.0)),
            ]);
            f.step();
            f.clock.advance_us(20_000);
        }
        assert_eq!(f.model.total_display(f.now_us()), 140.0);
    }

    #[test]
    fn nothing_arrives_while_down_and_a_reconnect_redelivers() {
        let mut f = feed();
        f.publish(vec![("seq", Value::Int(1)), (LANE_KEY, Value::Bool(false))]);
        f.set_link(false);
        assert!(f.publish(vec![(LANE_KEY, Value::Bool(true))]).is_empty());
        assert_eq!(f.model.banner(), Banner::Disconnected);
        f.set_link(true);
        assert_eq!(f.model.banner(), Banner::NoData);
        let events = f.publish(vec![("seq", Value::Int(1)), (LANE_KEY, Value::Bool(true))]);
        assert_eq!(events, [MatchEvent::ToastFired(true)]);
        f.step();
        assert_eq!(f.model.banner(), Banner::None);
    }
}
