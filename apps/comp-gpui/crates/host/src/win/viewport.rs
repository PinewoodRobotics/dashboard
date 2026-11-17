// UNTESTED: Windows counterpart of viewport.rs, only type-checked for aarch64-pc-windows-msvc.
// It keeps viewport.rs's public API so main.rs and shell.rs are shared; the two should become
// one file with a per-platform slot type once the macOS side settles.

use std::time::Instant;

use gpui_kit::*;
use protocol::{ToHost, ToProducer};

use crate::godot::GodotProcess;
use crate::shell::FpsCounter;
use crate::test_pattern::TestPattern;

pub enum ViewportSource {
    TestPattern(TestPattern),
    Godot(GodotView),
}

impl ViewportSource {
    pub fn element(&mut self, t: f32) -> AnyElement {
        match self {
            ViewportSource::TestPattern(pattern) => {
                pattern.draw(t);
                surface(pattern.texture())
                    .object_fit(ObjectFit::Cover)
                    .size_full()
                    .into_any_element()
            }
            ViewportSource::Godot(view) => view.element(),
        }
    }

    pub fn wants_animation_frames(&self) -> bool {
        matches!(self, ViewportSource::TestPattern(_))
    }

    pub fn stats_lines(&self) -> Vec<String> {
        match self {
            ViewportSource::TestPattern(_) => {
                vec!["source test pattern (host D3D11 shared texture)".into()]
            }
            ViewportSource::Godot(view) => view.stats_lines(),
        }
    }
}

struct LatestFrame {
    slot: u32,
    seq: u64,
    ready_us: u64,
}

pub struct GodotView {
    process: GodotProcess,
    generation: u32,
    textures: Vec<SharedTexture>,
    latest: Option<LatestFrame>,
    displayed_seq: u64,
    producer: FpsCounter,
    cpu_ms: Smoothed,
    gpu_ms: Smoothed,
    age_ms: Smoothed,
    started: Instant,
    first_frame_ms: Option<f32>,
}

impl GodotView {
    pub fn new(process: GodotProcess) -> Self {
        install_stderr_logger();
        Self {
            process,
            generation: 0,
            textures: Vec::new(),
            latest: None,
            displayed_seq: 0,
            producer: FpsCounter::default(),
            cpu_ms: Smoothed::default(),
            gpu_ms: Smoothed::default(),
            age_ms: Smoothed::default(),
            started: Instant::now(),
            first_frame_ms: None,
        }
    }

    pub fn on_message(&mut self, message: ToHost) {
        match message {
            ToHost::Surfaces {
                view,
                generation,
                width,
                height,
                ids,
            } => {
                let pid = self.process.pid();
                self.textures = ids
                    .iter()
                    .map(|&slot| SharedTexture {
                        name: protocol::shared_texture::windows_slot_name(
                            pid, view, generation, slot,
                        )
                        .into(),
                        size: size(DevicePixels(width as i32), DevicePixels(height as i32)),
                        opaque: true,
                    })
                    .collect();
                self.generation = generation;
                self.latest = None;
            }
            ToHost::Frame {
                generation,
                slot,
                seq,
                cpu_ms,
                gpu_ms,
                ready_us,
                ..
            } => {
                if generation != self.generation || slot as usize >= self.textures.len() {
                    return;
                }
                self.producer.tick();
                self.cpu_ms.push(cpu_ms);
                self.gpu_ms.push(gpu_ms);
                self.first_frame_ms
                    .get_or_insert(self.started.elapsed().as_secs_f32() * 1000.0);
                if self.latest.as_ref().is_none_or(|latest| seq > latest.seq) {
                    self.latest = Some(LatestFrame {
                        slot,
                        seq,
                        ready_us,
                    });
                }
            }
        }
    }

    fn element(&mut self) -> AnyElement {
        let Some(latest) = &self.latest else {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_color(rgb(0x8a90a0))
                .child("waiting for Godot...")
                .into_any_element();
        };
        if latest.seq != self.displayed_seq {
            self.displayed_seq = latest.seq;
            self.age_ms
                .push(protocol::now_us().saturating_sub(latest.ready_us) as f32 / 1000.0);
            self.process.send(&ToProducer::Ack {
                view: 0,
                generation: self.generation,
                slot: latest.slot,
                seq: latest.seq,
            });
        }
        surface(self.textures[latest.slot as usize].clone())
            .object_fit(ObjectFit::Cover)
            .size_full()
            .into_any_element()
    }

    fn stats_lines(&self) -> Vec<String> {
        vec![
            format!("producer fps {:.0}", self.producer.fps),
            format!("godot cpu ms {:.2}", self.cpu_ms.value),
            format!("gpu ms (submit to fence) {:.2}", self.gpu_ms.value),
            format!(
                "frame age ms (fence to host paint) {:.2}",
                self.age_ms.value
            ),
            format!(
                "first frame {}",
                self.first_frame_ms
                    .map(|ms| format!("{ms:.0} ms after spawn"))
                    .unwrap_or_else(|| "pending".into())
            ),
        ]
    }
}

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

#[derive(Default)]
struct Smoothed {
    value: f32,
    primed: bool,
}

impl Smoothed {
    fn push(&mut self, sample: f32) {
        if self.primed {
            self.value += (sample - self.value) * 0.1;
        } else {
            self.value = sample;
            self.primed = true;
        }
    }
}
