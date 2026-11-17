use std::time::{Duration, Instant};

use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;
use host::bridge3d::Bridge3d;
use host::stats::FpsCounter;
use host::test_pattern::TestPattern;
use host::view3d::View3d;
use protocol::Scene;

pub const DRAWER_WIDTH: f32 = 320.0;
pub const MINIMAP_SIZE: (f32, f32) = (360.0, 220.0);
pub const INSET: f32 = 16.0;
pub const HEADER_HEIGHT: f32 = 40.0;
/// The driver station touchscreen.
pub const KIOSK_VIEW_PX: (f32, f32) = (1920.0, 515.0);

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    /// Header with controls, the robot view in a card, minimap inset, sliding drawer.
    Spike,
    /// The robot view full-bleed with the minimap inset, as on the 1920x515 touchscreen.
    Kiosk,
    /// A second window with its own orbit view.
    Second,
}

pub struct ShellOptions {
    pub layout: Layout,
    pub robot_fps: u32,
    pub minimap_fps: u32,
    pub minimap: bool,
    pub auto_drawer: bool,
    pub log_stats: Option<Duration>,
}

pub struct Shell {
    layout: Layout,
    bridge: Option<Entity<Bridge3d>>,
    main: Option<Entity<View3d>>,
    minimap: Option<Entity<View3d>>,
    test_pattern: Option<TestPattern>,
    started: Instant,
    drawer_open: bool,
    drawer_changed: Instant,
    frames: FpsCounter,
    auto_drawer: bool,
    robot_fps: u32,
    _observers: Vec<Subscription>,
}

impl Shell {
    pub fn new(
        bridge: Option<Entity<Bridge3d>>,
        test_pattern: Option<TestPattern>,
        options: ShellOptions,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut observers = Vec::new();
        let mut main = None;
        let mut minimap = None;
        if let Some(bridge) = &bridge {
            observers.push(cx.observe(bridge, |_, _, cx| cx.notify()));
            let view = bridge.update(cx, |b, cx| b.open_view(Scene::Robot, options.robot_fps, cx));
            observers.push(cx.observe(&view, |_, _, cx| cx.notify()));
            main = Some(view);
            if options.layout != Layout::Second {
                let view =
                    bridge.update(cx, |b, cx| b.open_view(Scene::Minimap, options.minimap_fps, cx));
                view.update(cx, |view, cx| view.set_active(options.minimap, cx));
                observers.push(cx.observe(&view, |_, _, cx| cx.notify()));
                minimap = Some(view);
            }
        }
        if let Some(every) = options.log_stats {
            cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor().timer(every).await;
                    let Ok(lines) = this.update(cx, |shell, cx| shell.stats_lines(cx)) else {
                        break;
                    };
                    eprintln!("stats: {}", lines.join(" | "));
                }
            })
            .detach();
        }
        Self {
            layout: options.layout,
            bridge,
            main,
            minimap,
            test_pattern,
            started: Instant::now(),
            drawer_open: options.layout == Layout::Spike,
            drawer_changed: Instant::now() - Duration::from_secs(1),
            frames: FpsCounter::default(),
            auto_drawer: options.auto_drawer,
            robot_fps: options.robot_fps,
            _observers: observers,
        }
    }

    pub fn close_views(&mut self, cx: &mut Context<Self>) {
        let Some(bridge) = &self.bridge else { return };
        for view in self.main.iter().chain(self.minimap.iter()) {
            bridge.update(cx, |b, cx| b.close_view(view, cx));
        }
    }

    fn drawer_animating(&self) -> bool {
        self.drawer_changed.elapsed() < Duration::from_millis(300)
    }

    fn drawer_offset(&self) -> f32 {
        const SLIDE: f32 = 0.25;
        let progress = (self.drawer_changed.elapsed().as_secs_f32() / SLIDE).min(1.0);
        let eased = 1.0 - (1.0 - progress).powi(3);
        if self.drawer_open { 1.0 - eased } else { eased }
    }

    fn toggle_minimap(&mut self, cx: &mut Context<Self>) {
        if let Some(view) = &self.minimap {
            view.update(cx, |view, cx| {
                let active = !view.is_active();
                view.set_active(active, cx);
            });
        }
        cx.notify();
    }

    fn open_second_window(&mut self, cx: &mut Context<Self>) {
        let Some(bridge) = self.bridge.clone() else { return };
        let fps = self.robot_fps.min(60);
        open_shell_window(
            cx,
            Some(bridge),
            None,
            ShellOptions {
                layout: Layout::Second,
                robot_fps: fps,
                minimap_fps: 0,
                minimap: false,
                auto_drawer: false,
                log_stats: None,
            },
            size(px(720.), px(480.)),
            "PWRUP comp-gpui (second window)",
        );
    }

    fn stats_lines(&self, cx: &App) -> Vec<String> {
        let mut lines = vec![format!("host fps {:.0}", self.frames.fps)];
        if let Some(bridge) = &self.bridge {
            lines.extend(bridge.read(cx).status_lines());
        }
        if self.test_pattern.is_some() {
            lines.push("source test pattern (host IOSurface)".into());
        }
        for view in self.main.iter().chain(self.minimap.iter()) {
            lines.extend(view.read(cx).stats_lines());
        }
        lines
    }

    fn minimap_visible(&self, cx: &App) -> bool {
        self.minimap
            .as_ref()
            .is_some_and(|view| view.read(cx).is_active())
    }
}

pub fn window_options(content: Size<Pixels>, title: &str, cx: &App) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(None, content, cx))),
        titlebar: Some(TitlebarOptions {
            title: Some(title.to_string().into()),
            ..Default::default()
        }),
        // GPUI caps inactive windows at ~30 fps by default; the driver station keeps the FRC
        // Driver Station app focused, so the dashboard is inactive for the whole match.
        inactive_frame_interval: None,
        low_power_frame_interval: None,
        ..Default::default()
    }
}

pub fn open_shell_window(
    cx: &mut App,
    bridge: Option<Entity<Bridge3d>>,
    test_pattern: Option<TestPattern>,
    options: ShellOptions,
    content: Size<Pixels>,
    title: &str,
) -> Option<(AnyWindowHandle, Entity<Shell>)> {
    let window_options = window_options(content, title, cx);
    gpui_kit::open_window(window_options, cx, |window, cx| {
        let shell = cx.new(|cx| Shell::new(bridge, test_pattern, options, cx));
        let closing = shell.downgrade();
        window.on_window_should_close(cx, move |_, cx| {
            closing.update(cx, |shell, cx| shell.close_views(cx)).ok();
            true
        });
        shell
    })
    .ok()
}

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.frames.tick();
        if self.test_pattern.is_some() || self.drawer_animating() || self.auto_drawer {
            window.request_animation_frame();
        }
        if self.auto_drawer && self.drawer_changed.elapsed() > Duration::from_secs(2) {
            self.drawer_open = !self.drawer_open;
            self.drawer_changed = Instant::now();
        }
        let overlay_lines = self.stats_lines(cx);
        let main: AnyElement = match (&self.test_pattern, &self.main) {
            (Some(pattern), _) => {
                pattern.draw(self.started.elapsed().as_secs_f32());
                surface(pattern.buffer().clone())
                    .object_fit(ObjectFit::Cover)
                    .size_full()
                    .into_any_element()
            }
            (None, Some(view)) => view.clone().into_any_element(),
            (None, None) => div().into_any_element(),
        };
        let minimap = self
            .minimap
            .clone()
            .filter(|_| self.minimap_visible(cx))
            .map(|view| {
                div()
                    .absolute()
                    .left(px(INSET * 2.0))
                    .bottom(px(INSET * 2.0))
                    .w(px(MINIMAP_SIZE.0))
                    .h(px(MINIMAP_SIZE.1))
                    .rounded(px(10.))
                    .overflow_hidden()
                    .border_1()
                    .border_color(rgba(0xffffff33))
                    .child(view)
            });
        let overlay = div()
            .absolute()
            .top(px(if self.layout == Layout::Spike { 64. } else { 12. }))
            .left(px(if self.layout == Layout::Spike { 32. } else { 12. }))
            .p(px(10.))
            .rounded(px(8.))
            .bg(rgba(0x000000b0))
            .text_color(rgb(0x9fe870))
            .text_size(px(12.))
            .font_family("Menlo")
            .flex()
            .flex_col()
            .children(overlay_lines);

        let root = div().size_full().relative().bg(rgb(0x0b0d12));
        match self.layout {
            Layout::Kiosk => {
                let scale = window.scale_factor();
                root.child(
                    div()
                        .absolute()
                        .top_0()
                        .left_0()
                        .w(px(KIOSK_VIEW_PX.0 / scale))
                        .h(px(KIOSK_VIEW_PX.1 / scale))
                        .child(main),
                )
                .children(minimap)
                .child(overlay)
            }
            Layout::Second => root
                .child(div().absolute().inset_0().child(main))
                .children(minimap)
                .child(overlay),
            Layout::Spike => {
                let offset = self.drawer_offset() * (DRAWER_WIDTH + 48.0);
                root.child(
                    div()
                        .absolute()
                        .top(px(HEADER_HEIGHT + 8.))
                        .left(px(INSET))
                        .right(px(INSET))
                        .bottom(px(INSET))
                        .rounded(px(12.))
                        .overflow_hidden()
                        .child(main),
                )
                .child(self.header(cx))
                .children(minimap)
                .child(overlay)
                .child(
                    div()
                        .id("drawer")
                        .occlude()
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
    }
}

impl Shell {
    fn header(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let button = |id: &'static str, label: String| {
            div()
                .id(id)
                .px(px(10.))
                .py(px(4.))
                .rounded(px(6.))
                .bg(rgb(0x2a3040))
                .cursor_pointer()
                .child(label)
        };
        let minimap_on = self.minimap_visible(cx);
        div()
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .h(px(HEADER_HEIGHT))
            .flex()
            .items_center()
            .px(px(INSET))
            .gap(px(12.))
            .text_color(rgb(0xe6e8ee))
            .text_size(px(13.))
            .child("PWRUP 3D shared-texture spike")
            .child(
                button(
                    "toggle-drawer",
                    if self.drawer_open { "Hide drawer" } else { "Show drawer" }.into(),
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.drawer_open = !this.drawer_open;
                    this.drawer_changed = Instant::now();
                    cx.notify();
                })),
            )
            .when(self.minimap.is_some(), |this| {
                this.child(
                    button(
                        "toggle-minimap",
                        if minimap_on { "Hide minimap" } else { "Show minimap" }.into(),
                    )
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_minimap(cx))),
                )
            })
            .when(self.bridge.is_some(), |this| {
                this.child(
                    button("new-window", "New window".into())
                        .on_click(cx.listener(|this, _, _, cx| this.open_second_window(cx))),
                )
            })
    }
}
