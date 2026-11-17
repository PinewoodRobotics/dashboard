use dash_core::settings::WindowsSettings;
use dash_core::settings::placement::{self, Plan, WindowKey};
use gpui_kit::*;

use crate::hud::HudScreen;
use crate::mock::MockData;
use crate::settings;
use crate::theme::{HUD_DESIGN, TOUCH_DESIGN};
use crate::touch::{TouchScreen, TouchStart};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScreenKind {
    Hud,
    Touch,
}

impl ScreenKind {
    pub fn design(self) -> Size<f32> {
        match self {
            ScreenKind::Hud => HUD_DESIGN,
            ScreenKind::Touch => TOUCH_DESIGN,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            ScreenKind::Hud => "PWRUP Comp - HUD",
            ScreenKind::Touch => "PWRUP Comp - Touchscreen",
        }
    }

    fn key(self) -> WindowKey {
        match self {
            ScreenKind::Hud => WindowKey::Hud,
            ScreenKind::Touch => WindowKey::Touch,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Placement {
    Fullscreen {
        display: DisplayId,
        bounds: Bounds<Pixels>,
        index: usize,
        reason: String,
    },
    Windowed {
        reason: String,
    },
}

impl Placement {
    /// "display 2 (exact size)", "windowed (single screen)".
    pub fn describe(&self) -> String {
        match self {
            Placement::Fullscreen { index, reason, .. } => {
                format!("display {} ({reason})", index + 1)
            }
            Placement::Windowed { reason } => format!("windowed ({reason})"),
        }
    }
}

pub struct DisplayInfo {
    pub id: DisplayId,
    pub bounds: Bounds<Pixels>,
}

pub fn plan(
    displays: &[DisplayInfo],
    windows: &[ScreenKind],
    overrides: &WindowsSettings,
) -> Vec<(ScreenKind, Placement)> {
    let sizes: Vec<(f32, f32)> = displays
        .iter()
        .map(|d| {
            (
                f32::from(d.bounds.size.width),
                f32::from(d.bounds.size.height),
            )
        })
        .collect();
    let keys: Vec<WindowKey> = windows.iter().map(|k| k.key()).collect();
    let planned = placement::plan(&sizes, &keys, overrides);
    windows
        .iter()
        .filter_map(|&kind| {
            let (_, p) = planned.iter().find(|(k, _)| *k == kind.key())?;
            Some((
                kind,
                match p {
                    Plan::Fullscreen { screen, reason } => Placement::Fullscreen {
                        display: displays[*screen].id,
                        bounds: displays[*screen].bounds,
                        index: *screen,
                        reason: reason.clone(),
                    },
                    Plan::Windowed { reason } => Placement::Windowed {
                        reason: reason.clone(),
                    },
                },
            ))
        })
        .collect()
}

pub fn displays(cx: &App) -> Vec<DisplayInfo> {
    cx.displays()
        .iter()
        .map(|d| DisplayInfo {
            id: d.id(),
            bounds: d.bounds(),
        })
        .collect()
}

pub fn options(
    kind: ScreenKind,
    placement: &Placement,
    index: usize,
    borderless: bool,
    cx: &App,
) -> WindowOptions {
    match placement {
        Placement::Fullscreen {
            display, bounds, ..
        } => WindowOptions {
            window_bounds: Some(WindowBounds::Fullscreen(*bounds)),
            titlebar: None,
            display_id: Some(*display),
            is_movable: false,
            is_resizable: false,
            app_id: Some("pwrup-comp".into()),
            ..Default::default()
        },
        Placement::Windowed { .. } => {
            let design = kind.design();
            let scale = 2.0 / 3.0;
            let sz = size(
                px((design.width * scale).round()),
                px((design.height * scale).round()),
            );
            let origin = cx
                .primary_display()
                .map(|d| d.bounds().origin)
                .unwrap_or_default();
            let at = point(
                origin.x + px(40.),
                origin.y + px(40. + index as f32 * (f32::from(sz.height) + 40.)),
            );
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(at, sz))),
                titlebar: (!borderless).then(|| TitlebarOptions {
                    title: Some(kind.title().into()),
                    ..Default::default()
                }),
                app_id: Some("pwrup-comp".into()),
                ..Default::default()
            }
        }
    }
}

/// Resizes a dev window to the design size in physical pixels, so its
/// screenshots compare 1:1 with the reference images.
pub fn resize_to_design_pixels(kind: ScreenKind, window: &mut Window) {
    let sf = window.scale_factor().max(0.1);
    let d = kind.design();
    window.resize(size(px(d.width / sf), px(d.height / sf)));
}

gpui_kit::actions!(comp, [Retile]);

const RETIRE_DELAY: std::time::Duration = std::time::Duration::from_millis(300);

thread_local! {
    static RETIRED: std::cell::RefCell<Vec<WindowId>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// True for a window Re-tile replaced, so closing it does not quit the app
/// as closing a window by hand does.
pub fn closing_for_retile(id: WindowId) -> bool {
    RETIRED.with_borrow_mut(|r| {
        let found = r.contains(&id);
        r.retain(|w| *w != id);
        found
    })
}

/// The open windows and where they went, so Re-tile (the Visual tab,
/// Ctrl/Cmd+Shift+F) can move them. GPUI cannot move a window to another
/// display, so a window whose placement changed is replaced by a new one.
pub struct Tiler {
    data: Entity<MockData>,
    force_windowed: bool,
    design_px: bool,
    open: Vec<(ScreenKind, AnyWindowHandle, Placement)>,
    display_count: usize,
}

impl Global for Tiler {}

pub struct OpenOptions {
    pub screens: Vec<ScreenKind>,
    pub force_windowed: bool,
    pub design_px: bool,
    pub touch: TouchStart,
}

/// Opens the start-up windows; returns the touchscreen window, if any.
pub fn open_all(
    data: &Entity<MockData>,
    opts: OpenOptions,
    cx: &mut App,
) -> Option<AnyWindowHandle> {
    let displays = displays(cx);
    let planned = plan(&displays, &opts.screens, &settings::windows(cx));
    let mut tiler = Tiler {
        data: data.clone(),
        force_windowed: opts.force_windowed,
        design_px: opts.design_px,
        open: Vec::new(),
        display_count: displays.len(),
    };
    let mut touch_window = None;
    for (index, (kind, placement)) in planned.into_iter().enumerate() {
        let placement = tiler.adjust(placement);
        eprintln!("comp-gpui: {} {:?}", kind.title(), placement);
        match tiler.open_screen(kind, &placement, index, opts.touch.clone(), cx) {
            Ok(handle) => {
                if kind == ScreenKind::Touch {
                    touch_window = Some(handle);
                }
                tiler.open.push((kind, handle, placement));
            }
            Err(e) => eprintln!("comp-gpui: cannot open {}: {e:#}", kind.title()),
        }
    }
    cx.set_global(tiler);
    cx.on_action(|_: &Retile, cx| retile(TouchStart::default(), cx));
    cx.bind_keys([
        KeyBinding::new("cmd-shift-f", Retile, None),
        KeyBinding::new("ctrl-shift-f", Retile, None),
    ]);
    touch_window
}

impl Tiler {
    fn adjust(&self, p: Placement) -> Placement {
        if self.force_windowed {
            Placement::Windowed {
                reason: "--windowed".into(),
            }
        } else {
            p
        }
    }

    fn open_screen(
        &self,
        kind: ScreenKind,
        placement: &Placement,
        index: usize,
        touch: TouchStart,
        cx: &mut App,
    ) -> anyhow::Result<AnyWindowHandle> {
        let design_px = self.design_px && matches!(placement, Placement::Windowed { .. });
        let options = options(kind, placement, index, design_px, cx);
        let data = self.data.clone();
        let opened = match kind {
            ScreenKind::Hud => {
                gpui_kit::open_window(options, cx, move |window, cx| {
                    if design_px {
                        resize_to_design_pixels(kind, window);
                    }
                    cx.new(|cx| HudScreen::new(data, cx))
                })?
                .0
            }
            ScreenKind::Touch => {
                gpui_kit::open_window(options, cx, move |window, cx| {
                    if design_px {
                        resize_to_design_pixels(kind, window);
                    }
                    cx.new(|cx| TouchScreen::new(data, touch, cx))
                })?
                .0
            }
        };
        Ok(opened)
    }
}

pub fn tiling_text(cx: &App) -> String {
    let Some(t) = cx.try_global::<Tiler>() else {
        return "Not tiled yet: windows stay where they opened".into();
    };
    let mut lines = vec![format!("{} display(s)", t.display_count)];
    for (kind, _, p) in &t.open {
        let name = match kind {
            ScreenKind::Hud => "HUD",
            ScreenKind::Touch => "Touch",
        };
        lines.push(format!("{name}: {}", p.describe()));
    }
    lines.join("\n")
}

/// Re-plans every open window and replaces the ones whose placement changed;
/// a replaced touchscreen window starts at `touch`. Deferred, so the window
/// whose button asked for it is not removed in the middle of its own event.
pub fn retile(touch: TouchStart, cx: &mut App) {
    cx.defer(move |cx| {
        if !cx.has_global::<Tiler>() {
            return;
        }
        let displays = displays(cx);
        let overrides = settings::windows(cx);
        let mut tiler = cx.remove_global::<Tiler>();
        tiler.display_count = displays.len();
        let kinds: Vec<ScreenKind> = tiler.open.iter().map(|(k, _, _)| *k).collect();
        let planned = plan(&displays, &kinds, &overrides);
        let mut open = Vec::new();
        let mut retired = Vec::new();
        for (index, (kind, handle, old)) in std::mem::take(&mut tiler.open).into_iter().enumerate()
        {
            let new = planned
                .iter()
                .find(|(k, _)| *k == kind)
                .map(|(_, p)| tiler.adjust(p.clone()))
                .unwrap_or_else(|| old.clone());
            if new == old {
                open.push((kind, handle, old));
                continue;
            }
            eprintln!("comp-gpui: re-tile {} {:?}", kind.title(), new);
            match tiler.open_screen(kind, &new, index, touch.clone(), cx) {
                Ok(replacement) => {
                    RETIRED.with_borrow_mut(|r| r.push(handle.window_id()));
                    retired.push(handle);
                    open.push((kind, replacement, new));
                }
                Err(e) => {
                    eprintln!("comp-gpui: cannot re-tile {}: {e:#}", kind.title());
                    open.push((kind, handle, old));
                }
            }
        }
        tiler.open = open;
        cx.set_global(tiler);
        cx.refresh_windows();
        if retired.is_empty() {
            return;
        }
        // Closing a window in the run-loop turn that opened its replacement
        // makes AppKit throw from its touch bar observer; close it later.
        cx.spawn(async move |cx| {
            cx.background_executor().timer(RETIRE_DELAY).await;
            for handle in retired {
                let _ = handle.update(cx, |_, window, _| window.remove_window());
            }
        })
        .detach();
    });
}
