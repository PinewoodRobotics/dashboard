use std::time::Duration;

use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;
use objc2_core_foundation::CFRetained;
use objc2_core_video::CVPixelBuffer;
use protocol::{Pointer, PointerKind, PointerPhase, Scene, ToHost, ToProducer};

use crate::godot::ProducerLink;
use crate::iosurface;
use crate::present::{self, Painted};
use crate::stats::{FpsCounter, Smoothed, fmt_ms};

/// How long the element's size must hold still before Godot builds surfaces at the new size.
/// Until then the previous generation is drawn cropped to cover the element.
const RESIZE_DEBOUNCE: Duration = Duration::from_millis(150);
/// Chromium's WheelEvent delta per Cocoa line.
const LINE_PX: f32 = 40.0;

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct DeviceSize {
    pub width: u32,
    pub height: u32,
    pub scale: f32,
}

struct Ring {
    generation: u32,
    width: u32,
    height: u32,
    buffers: Vec<CFRetained<CVPixelBuffer>>,
}

#[derive(Clone, Copy)]
struct FrameInfo {
    generation: u32,
    slot: u32,
    seq: u64,
    ready_us: u64,
    input_stamp: u64,
}

struct Shown {
    buffer: CFRetained<CVPixelBuffer>,
    width: u32,
    height: u32,
    generation: u32,
    seq: u64,
}

/// One 3D view rendered by the shared Godot process: owns the surfaces of its current
/// generation, the frame on screen, and the pointer capture over its element.
pub struct View3d {
    id: u32,
    scene: Scene,
    fps: u32,
    link: ProducerLink,
    active: bool,
    opened: bool,
    measured: Option<DeviceSize>,
    requested: Option<DeviceSize>,
    resize_task: Option<Task<()>>,
    ring: Option<Ring>,
    latest: Option<FrameInfo>,
    shown: Option<Shown>,
    captured: Option<u8>,
    producer: FpsCounter,
    cpu_ms: Smoothed,
    gpu_ms: Smoothed,
    tick_ms: Smoothed,
    paint_age_ms: Smoothed,
    error: Option<String>,
}

impl View3d {
    pub fn new(id: u32, scene: Scene, fps: u32, link: ProducerLink) -> Self {
        Self {
            id,
            scene,
            fps,
            link,
            active: true,
            opened: false,
            measured: None,
            requested: None,
            resize_task: None,
            ring: None,
            latest: None,
            shown: None,
            captured: None,
            producer: FpsCounter::default(),
            cpu_ms: Smoothed::default(),
            gpu_ms: Smoothed::default(),
            tick_ms: Smoothed::default(),
            paint_age_ms: Smoothed::default(),
            error: None,
        }
    }

    pub fn id(&self) -> u32 {
        self.id
    }

    pub fn scene(&self) -> Scene {
        self.scene
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Hidden views stop rendering in Godot and keep their last frame here.
    pub fn set_active(&mut self, active: bool, cx: &mut Context<Self>) {
        if self.active == active {
            return;
        }
        self.active = active;
        if self.opened {
            self.link.send(&ToProducer::SetActive {
                view: self.id,
                active,
            });
        }
        cx.notify();
    }

    pub fn close(&mut self) {
        if self.opened {
            self.link.send(&ToProducer::CloseView { view: self.id });
        }
        self.opened = false;
    }

    /// A new Godot process is up: it knows nothing of this view, so open it again at the
    /// current size. The last frame stays on screen until the new process sends one.
    pub fn on_connected(&mut self) {
        self.opened = false;
        self.latest = None;
        self.ring = None;
        if let Some(size) = self.measured {
            self.open(size);
        }
    }

    fn open(&mut self, size: DeviceSize) {
        self.link.send(&ToProducer::OpenView {
            view: self.id,
            scene: self.scene,
            width: size.width,
            height: size.height,
            scale: size.scale,
            fps: self.fps,
            active: self.active,
        });
        self.requested = Some(size);
        self.opened = self.link.is_connected();
    }

    fn on_measured(&mut self, size: DeviceSize, cx: &mut Context<Self>) {
        if self.measured == Some(size) {
            return;
        }
        self.measured = Some(size);
        if !self.opened {
            self.open(size);
            return;
        }
        self.resize_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(RESIZE_DEBOUNCE).await;
            this.update(cx, |view, _| view.flush_resize()).ok();
        }));
    }

    fn flush_resize(&mut self) {
        let Some(size) = self.measured else { return };
        if self.requested == Some(size) || !self.opened {
            return;
        }
        self.link.send(&ToProducer::Resize {
            view: self.id,
            width: size.width,
            height: size.height,
            scale: size.scale,
        });
        self.requested = Some(size);
    }

    pub fn on_message(&mut self, message: ToHost, cx: &mut Context<Self>) {
        match message {
            ToHost::Surfaces {
                generation,
                width,
                height,
                ids,
                ..
            } => {
                let buffers: anyhow::Result<Vec<_>> = ids
                    .iter()
                    .map(|&id| {
                        let surface = iosurface::lookup_surface(id)?;
                        iosurface::pixel_buffer(&surface, true)
                    })
                    .collect();
                match buffers {
                    Ok(buffers) => {
                        self.ring = Some(Ring {
                            generation,
                            width,
                            height,
                            buffers,
                        });
                        self.latest = None;
                    }
                    Err(error) => self.error = Some(format!("{error:#}")),
                }
            }
            ToHost::Frame {
                generation,
                slot,
                seq,
                cpu_ms,
                gpu_ms,
                tick_ms,
                ready_us,
                input_stamp,
                ..
            } => {
                let Some(ring) = &self.ring else { return };
                if generation != ring.generation || slot as usize >= ring.buffers.len() {
                    return;
                }
                self.producer.tick();
                self.cpu_ms.push(cpu_ms);
                self.gpu_ms.push(gpu_ms);
                self.tick_ms.push(tick_ms);
                if self.latest.is_none_or(|latest| seq > latest.seq) {
                    self.latest = Some(FrameInfo {
                        generation,
                        slot,
                        seq,
                        ready_us,
                        input_stamp,
                    });
                    cx.notify();
                }
            }
            ToHost::Status { .. } => {}
        }
    }

    /// Takes the newest delivered frame for this paint and acks it, which frees the producer to
    /// reuse the slot shown before the previous one.
    fn take_latest(&mut self) {
        let Some(frame) = self.latest.take() else {
            return;
        };
        let Some(ring) = &self.ring else { return };
        if frame.generation != ring.generation {
            return;
        }
        let buffer = ring.buffers[frame.slot as usize].clone();
        present::painted(
            CFRetained::as_ptr(&buffer).as_ptr() as usize,
            Painted {
                view: self.id,
                seq: frame.seq,
                ready_us: frame.ready_us,
                input_stamp: frame.input_stamp,
            },
        );
        self.paint_age_ms
            .push(protocol::now_us().saturating_sub(frame.ready_us) as f32 / 1000.0);
        self.link.send(&ToProducer::Ack {
            view: self.id,
            generation: frame.generation,
            slot: frame.slot,
            seq: frame.seq,
        });
        self.shown = Some(Shown {
            buffer,
            width: ring.width,
            height: ring.height,
            generation: frame.generation,
            seq: frame.seq,
        });
    }

    fn send_pointer(
        &self,
        phase: PointerPhase,
        position: Point<Pixels>,
        origin: Point<Pixels>,
        fill: impl FnOnce(&mut Pointer),
    ) {
        let mut pointer = Pointer {
            view: self.id,
            kind: PointerKind::Mouse,
            id: 0,
            phase,
            x: f32::from(position.x - origin.x),
            y: f32::from(position.y - origin.y),
            button: protocol::buttons::NONE,
            mods: 0,
            wheel_x: 0.0,
            wheel_y: 0.0,
            magnify: 1.0,
            stamp: protocol::now_us(),
        };
        fill(&mut pointer);
        self.link.send(&ToProducer::Pointer(pointer));
    }

    pub fn stats_lines(&self) -> Vec<String> {
        let present = present::stats(self.id);
        let observed = present::is_observed();
        let size = self
            .shown
            .as_ref()
            .map(|s| {
                format!(
                    "{}x{} gen {} seq {}",
                    s.width, s.height, s.generation, s.seq
                )
            })
            .unwrap_or_else(|| "no frame".into());
        let element = self
            .measured
            .map(|m| format!(" on {}x{} px", m.width, m.height))
            .unwrap_or_default();
        let mut lines = vec![
            format!(
                "[{:?} view {}] {size}{element}{}",
                self.scene,
                self.id,
                if self.active { "" } else { " (inactive)" }
            ),
            format!(
                "producer fps {:.0}  shown fps {:.0}",
                self.producer.fps, present.fps.fps
            ),
            format!(
                "godot cpu ms {}  tick wall ms {}",
                fmt_ms(self.cpu_ms.get()),
                fmt_ms(self.tick_ms.get())
            ),
            format!("gpu ms (submit to fence) {}", fmt_ms(self.gpu_ms.get())),
        ];
        if observed {
            lines.push(format!(
                "frame age at present ms {}  input->present ms {}",
                fmt_ms(present.age_ms.get()),
                fmt_ms(present.input_ms.get())
            ));
        } else {
            lines.push(format!(
                "frame age at paint ms {}",
                fmt_ms(self.paint_age_ms.get())
            ));
        }
        if let Some(error) = &self.error {
            lines.push(error.clone());
        }
        lines
    }
}

impl Render for View3d {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.take_latest();
        let shown = self
            .shown
            .as_ref()
            .map(|s| (s.buffer.clone(), s.width, s.height));
        let waiting = shown.is_none();
        let entity = cx.entity().downgrade();
        let surface = canvas(
            {
                let entity = entity.clone();
                move |bounds, window, cx| {
                    let scale = window.scale_factor();
                    let size = DeviceSize {
                        width: (f32::from(bounds.size.width) * scale).round().max(1.0) as u32,
                        height: (f32::from(bounds.size.height) * scale).round().max(1.0) as u32,
                        scale,
                    };
                    entity
                        .update(cx, |view, cx| view.on_measured(size, cx))
                        .ok();
                    window.insert_hitbox(bounds, HitboxBehavior::Normal)
                }
            },
            move |bounds, hitbox, window, _cx| {
                if let Some((buffer, width, height)) = shown {
                    let rect = cover(bounds, width, height, window.scale_factor());
                    window.with_content_mask(Some(ContentMask { bounds }), |window| {
                        window.paint_surface(rect, buffer)
                    });
                }
                register_pointer_handlers(entity, bounds, hitbox, window);
            },
        )
        .size_full();

        div()
            .size_full()
            .relative()
            .child(surface)
            .when(waiting, |this| {
                this.child(
                    div()
                        .absolute()
                        .inset_0()
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_color(rgb(0x8a90a0))
                        .child(
                            self.error
                                .clone()
                                .unwrap_or_else(|| "waiting for Godot...".into()),
                        ),
                )
            })
    }
}

/// The rect that draws a `width` x `height` device-pixel frame over `bounds` without
/// distortion, cropping the overflow; it is `bounds` itself once the sizes match.
fn cover(bounds: Bounds<Pixels>, width: u32, height: u32, scale: f32) -> Bounds<Pixels> {
    let frame = size(px(width as f32 / scale), px(height as f32 / scale));
    let fit = (f32::from(bounds.size.width) / f32::from(frame.width))
        .max(f32::from(bounds.size.height) / f32::from(frame.height));
    let drawn = size(frame.width * fit, frame.height * fit);
    Bounds {
        origin: point(
            bounds.origin.x + (bounds.size.width - drawn.width) / 2.0,
            bounds.origin.y + (bounds.size.height - drawn.height) / 2.0,
        ),
        size: drawn,
    }
}

fn button_code(button: MouseButton) -> Option<u8> {
    match button {
        MouseButton::Left => Some(protocol::buttons::LEFT),
        MouseButton::Right => Some(protocol::buttons::RIGHT),
        MouseButton::Middle => Some(protocol::buttons::MIDDLE),
        MouseButton::Navigate(_) => None,
    }
}

fn mods_code(modifiers: &Modifiers) -> u8 {
    let mut mods = 0;
    if modifiers.shift {
        mods |= protocol::mods::SHIFT;
    }
    if modifiers.control {
        mods |= protocol::mods::CTRL;
    }
    if modifiers.alt {
        mods |= protocol::mods::ALT;
    }
    if modifiers.platform {
        mods |= protocol::mods::META;
    }
    mods
}

/// A press that lands on the view (not on GPUI content occluding it) captures the pointer
/// until that button is released, wherever the pointer goes meanwhile.
fn register_pointer_handlers(
    entity: WeakEntity<View3d>,
    bounds: Bounds<Pixels>,
    hitbox: Hitbox,
    window: &mut Window,
) {
    let origin = bounds.origin;
    window.on_mouse_event({
        let entity = entity.clone();
        let hitbox = hitbox.clone();
        move |event: &MouseDownEvent, phase, window, cx| {
            if phase != DispatchPhase::Bubble || !hitbox.is_hovered(window) {
                return;
            }
            let Some(button) = button_code(event.button) else {
                return;
            };
            entity
                .update(cx, |view, _| {
                    if view.captured.is_some() {
                        return;
                    }
                    view.captured = Some(button);
                    view.send_pointer(PointerPhase::Down, event.position, origin, |p| {
                        p.button = button;
                        p.mods = mods_code(&event.modifiers);
                    });
                })
                .ok();
        }
    });
    window.on_mouse_event({
        let entity = entity.clone();
        move |event: &MouseMoveEvent, phase, _window, cx| {
            if phase != DispatchPhase::Bubble {
                return;
            }
            entity
                .update(cx, |view, _| {
                    if view.captured.is_some() {
                        view.send_pointer(PointerPhase::Move, event.position, origin, |p| {
                            p.mods = mods_code(&event.modifiers);
                        });
                    }
                })
                .ok();
        }
    });
    window.on_mouse_event({
        let entity = entity.clone();
        move |event: &MouseUpEvent, phase, _window, cx| {
            if phase != DispatchPhase::Bubble {
                return;
            }
            let Some(button) = button_code(event.button) else {
                return;
            };
            entity
                .update(cx, |view, _| {
                    if view.captured != Some(button) {
                        return;
                    }
                    view.captured = None;
                    view.send_pointer(PointerPhase::Up, event.position, origin, |p| {
                        p.button = button;
                        p.mods = mods_code(&event.modifiers);
                    });
                })
                .ok();
        }
    });
    window.on_mouse_event({
        let entity = entity.clone();
        let hitbox = hitbox.clone();
        move |event: &ScrollEvent, phase, window, cx| {
            if phase != DispatchPhase::Bubble || !hitbox.should_handle_scroll(window) {
                return;
            }
            let (dx, dy) = match event.delta {
                ScrollDelta::Pixels(delta) => (-f32::from(delta.x), -f32::from(delta.y)),
                ScrollDelta::Lines(delta) => (-delta.x * LINE_PX, -delta.y * LINE_PX),
            };
            if dx == 0.0 && dy == 0.0 {
                return;
            }
            entity
                .update(cx, |view, _| {
                    view.send_pointer(PointerPhase::Wheel, event.position, origin, |p| {
                        p.wheel_x = dx;
                        p.wheel_y = dy;
                        p.mods = mods_code(&event.modifiers);
                    });
                })
                .ok();
        }
    });
    window.on_mouse_event(move |event: &PinchEvent, phase, window, cx| {
        if phase != DispatchPhase::Bubble || !hitbox.is_hovered(window) {
            return;
        }
        entity
            .update(cx, |view, _| {
                view.send_pointer(PointerPhase::Pinch, event.position, origin, |p| {
                    p.magnify = 1.0 + event.delta;
                    p.mods = mods_code(&event.modifiers);
                });
            })
            .ok();
    });
}

#[cfg(test)]
mod tests {
    use gpui_kit::{Bounds, Pixels, point, px, size};

    use super::cover;

    #[test]
    fn cover_is_the_element_once_sizes_match_and_crops_without_distortion_before() {
        let bounds = Bounds {
            origin: point(px(10.), px(20.)),
            size: size(px(960.), px(257.5)),
        };
        assert_eq!(cover(bounds, 1920, 515, 2.0), bounds);

        let stale = cover(bounds, 1280, 720, 2.0);
        let aspect = f32::from(stale.size.width) / f32::from(stale.size.height);
        assert!((aspect - 1280.0 / 720.0).abs() < 1e-4);
        assert_eq!(stale.size.width, px(960.));
        assert!(stale.size.height > bounds.size.height);
        let center = |b: Bounds<Pixels>| f32::from(b.origin.y + b.size.height / 2.0);
        assert!((center(stale) - center(bounds)).abs() < 1e-3);
    }
}
