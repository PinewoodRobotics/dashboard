struct StderrLogger;

impl log::Log for StderrLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            eprintln!("[{} {}] {}", record.level(), record.target(), record.args());
        }
    }

    fn flush(&self) {}
}

/// Routes GPUI's `log` output to stderr, where its shared-texture open failures land. The level
/// comes from RUST_LOG (`error`, `warn`, `info`, `debug`, `trace`) and defaults to warn.
pub fn install_stderr_logger() {
    static LOGGER: StderrLogger = StderrLogger;
    if log::set_logger(&LOGGER).is_ok() {
        let level = std::env::var("RUST_LOG")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(log::LevelFilter::Warn);
        log::set_max_level(level);
    }
}
