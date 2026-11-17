pub struct RingState {
    slot_seq: Vec<u64>,
    acked_seq: u64,
    displayed: Option<u32>,
    previously_displayed: Option<u32>,
    max_ahead: usize,
}

impl RingState {
    /// `max_ahead` caps the frames handed out but not yet acked (0 = only the ring limits them).
    pub fn new(slots: usize, max_ahead: usize) -> Self {
        Self {
            slot_seq: vec![0; slots],
            acked_seq: 0,
            displayed: None,
            previously_displayed: None,
            max_ahead,
        }
    }

    // The previously displayed slot stays reserved for one more ack because the host's GPU may
    // still be sampling it from the frame before the one that acked the new slot.
    pub fn acquire(&mut self, seq: u64) -> Option<u32> {
        let in_flight = self
            .slot_seq
            .iter()
            .filter(|&&slot_seq| slot_seq > self.acked_seq)
            .count();
        if self.max_ahead > 0 && in_flight >= self.max_ahead {
            return None;
        }
        let free = (0..self.slot_seq.len() as u32).find(|&slot| {
            Some(slot) != self.displayed
                && Some(slot) != self.previously_displayed
                && self.slot_seq[slot as usize] <= self.acked_seq
        })?;
        self.slot_seq[free as usize] = seq;
        Some(free)
    }

    /// Returns a slot whose frame was never sent.
    pub fn cancel(&mut self, slot: u32) {
        if let Some(seq) = self.slot_seq.get_mut(slot as usize) {
            *seq = 0;
        }
    }

    pub fn ack(&mut self, slot: u32, seq: u64) {
        if seq < self.acked_seq {
            return;
        }
        self.acked_seq = seq;
        if self.displayed != Some(slot) {
            self.previously_displayed = self.displayed;
            self.displayed = Some(slot);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_hands_out_displayed_or_unacked_slots() {
        let mut ring = RingState::new(4, 0);
        assert_eq!(ring.acquire(1), Some(0));
        assert_eq!(ring.acquire(2), Some(1));
        assert_eq!(ring.acquire(3), Some(2));
        assert_eq!(ring.acquire(4), Some(3));
        assert_eq!(ring.acquire(5), None);
        ring.ack(1, 2);
        assert_eq!(ring.acquire(5), Some(0));
        ring.ack(3, 4);
        assert_eq!(ring.acquire(6), Some(2));
        assert_eq!(ring.acquire(7), None);
    }

    #[test]
    fn max_ahead_waits_for_the_host_to_take_each_frame() {
        let mut ring = RingState::new(4, 1);
        assert_eq!(ring.acquire(1), Some(0));
        assert_eq!(ring.acquire(2), None);
        ring.ack(0, 1);
        assert_eq!(ring.acquire(2), Some(1));
        ring.cancel(1);
        assert_eq!(ring.acquire(3), Some(1));
    }
}
