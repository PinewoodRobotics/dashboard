use std::time::{Duration, Instant};

use gpui_kit::*;

use crate::viewport::ViewportSource;

pub struct Shell {
    source: ViewportSource,
    started: Instant,
    drawer_open: bool,
    drawer_changed: Instant,
    frames: FpsCounter,
    auto_drawer: bool,
}

impl Shell {
    pub fn new(source: ViewportSource, auto_drawer: bool) -> Self {
        Self {
            source,
            started: Instant::now(),
            drawer_open: true,
            drawer_changed: Instant::now() - Duration::from_secs(1),
            frames: FpsCounter::default(),
            auto_drawer,
        }
    }

    fn drawer_offset(&mut self) -> f32 {
        const SLIDE: f32 = 0.25;
        let progress = (self.drawer_changed.elapsed().as_secs_f32() / SLIDE).min(1.0);
        let eased = 1.0 - (1.0 - progress).powi(3);
        if self.drawer_open { 1.0 - eased } else { eased }
    }
}

#[derive(Default)]
pub struct FpsCounter {
    window_start: Option<Instant>,
    count: u32,
    pub fps: f32,
}

impl FpsCounter {
    pub fn tick(&mut self) {
        let now = Instant::now();
        let start = *self.window_start.get_or_insert(now);
        self.count += 1;
        let elapsed = now - start;
        if elapsed >= Duration::from_millis(500) {
            self.fps = self.count as f32 / elapsed.as_secs_f32();
            self.count = 0;
            self.window_start = Some(now);
        }
    }
}

const DRAWER_WIDTH: f32 = 320.0;

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.frames.tick();
        window.request_animation_frame();
        if self.auto_drawer && self.drawer_changed.elapsed() > Duration::from_secs(2) {
            self.drawer_open = !self.drawer_open;
            self.drawer_changed = Instant::now();
        }
        let t = self.started.elapsed().as_secs_f32();
        let offset = self.drawer_offset() * (DRAWER_WIDTH + 48.0);

        let viewport = self.source.element(t, cx);
        let mut overlay_lines = vec![format!("host fps {:.0}", self.frames.fps)];
        overlay_lines.extend(self.source.stats_lines());

        div()
            .size_full()
            .relative()
            .bg(rgb(0x0b0d12))
            .child(
                div()
                    .absolute()
                    .top(px(48.))
                    .left(px(16.))
                    .right(px(16.))
                    .bottom(px(16.))
                    .rounded(px(12.))
                    .overflow_hidden()
                    .child(viewport),
            )
            .child(
                div()
                    .absolute()
                    .top_0()
                    .left_0()
                    .right_0()
                    .h(px(40.))
                    .flex()
                    .items_center()
                    .px(px(16.))
                    .gap(px(12.))
                    .text_color(rgb(0xe6e8ee))
                    .text_size(px(13.))
                    .child("PWRUP 3D shared-texture spike")
                    .child(
                        div()
                            .id("toggle-drawer")
                            .px(px(10.))
                            .py(px(4.))
                            .rounded(px(6.))
                            .bg(rgb(0x2a3040))
                            .cursor_pointer()
                            .child(if self.drawer_open {
                                "Hide drawer"
                            } else {
                                "Show drawer"
                            })
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.drawer_open = !this.drawer_open;
                                this.drawer_changed = Instant::now();
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .absolute()
                    .top(px(64.))
                    .left(px(32.))
                    .p(px(10.))
                    .rounded(px(8.))
                    .bg(rgba(0x000000b0))
                    .text_color(rgb(0x9fe870))
                    .text_size(px(12.))
                    .font_family("Menlo")
                    .flex()
                    .flex_col()
                    .children(overlay_lines),
            )
            .child(
                div()
                    .absolute()
                    .top(px(64.))
                    .bottom(px(32.))
                    .right(px(32. - offset))
                    .w(px(DRAWER_WIDTH))
                    .rounded(px(12.))
                    .bg(rgba(0x161a24e6))
                    .border_1()
                    .border_color(rgba(0xffffff22))
                    .p(px(16.))
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .text_color(rgb(0xe6e8ee))
                    .text_size(px(13.))
                    .child(div().text_size(px(16.)).child("Drawer"))
                    .children((1..=6).map(|i| {
                        div()
                            .h(px(36.))
                            .rounded(px(6.))
                            .bg(rgba(0xffffff14))
                            .flex()
                            .items_center()
                            .px(px(10.))
                            .child(format!("GPUI row {i} drawn over the 3D surface"))
                    })),
            )
    }
}
