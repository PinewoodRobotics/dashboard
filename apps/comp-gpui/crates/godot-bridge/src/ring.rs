pub struct RingState {
    slot_seq: Vec<u64>,
    acked_seq: u64,
    displayed: Option<u32>,
    previously_displayed: Option<u32>,
}

impl RingState {
    pub fn new(slots: usize) -> Self {
        Self {
            slot_seq: vec![0; slots],
            acked_seq: 0,
            displayed: None,
            previously_displayed: None,
        }
    }

    // The previously displayed slot stays reserved for one more ack because the host's GPU may
    // still be sampling it from the frame before the one that acked the new slot.
    pub fn acquire(&mut self, seq: u64) -> Option<u32> {
        let free = (0..self.slot_seq.len() as u32).find(|&slot| {
            Some(slot) != self.displayed
                && Some(slot) != self.previously_displayed
                && self.slot_seq[slot as usize] <= self.acked_seq
        })?;
        self.slot_seq[free as usize] = seq;
        Some(free)
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
        let mut ring = RingState::new(4);
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
}
