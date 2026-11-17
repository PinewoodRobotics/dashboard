/// NT handle name of one slot of a producer's shared-texture ring on Windows. The producer's
/// process id keeps a respawned producer, whose generations restart at 1, from colliding with
/// names the host still has open from the previous process.
pub fn windows_slot_name(producer_pid: u32, view: u32, generation: u32, slot: u32) -> String {
    format!(r"Local\pwrup-p{producer_pid}-v{view}-g{generation}-s{slot}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slot_names_are_session_local_and_distinct_per_process() {
        assert_eq!(windows_slot_name(42, 0, 3, 1), r"Local\pwrup-p42-v0-g3-s1");
        assert_ne!(
            windows_slot_name(42, 0, 1, 0),
            windows_slot_name(43, 0, 1, 0)
        );
    }
}
