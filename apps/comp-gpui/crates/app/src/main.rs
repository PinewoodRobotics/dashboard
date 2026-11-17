#![allow(dead_code)]

mod anim;
mod assets;
mod debug_overlay;
mod dev_script;
mod hud;
mod icons;
mod input;
mod match_feed;
mod mock;
mod placeholder;
mod screen;
mod theme;
mod touch;
mod touch_test;
mod widgets;
mod windows;

use std::time::Duration;

use gpui_kit::*;

use crate::mock::{MockData, Scenario};
use crate::touch::{PanelId, TabId, TouchScreen, TouchStart};
use crate::windows::{Placement, ScreenKind};

gpui_kit::actions!(comp, [Quit]);

struct Args {
    screens: Vec<ScreenKind>,
    scenario: Scenario,
    touch: TouchStart,
    windowed: bool,
    design_px: bool,
    mouse_as_touch: bool,
    script: Vec<dev_script::Step>,
}

const USAGE: &str = "usage: comp-gpui [--screen=both|hud|touch] [--fixture=NAME] [--tab=ID] [--panel=map|intake] \
[--dock] [--nt-down] [--windowed] [--design-size] [--mouse-as-touch] [--script=STEPS]";

fn parse_args() -> anyhow::Result<Args> {
    let mut args = Args {
        screens: vec![ScreenKind::Hud, ScreenKind::Touch],
        scenario: Scenario::Demo,
        touch: TouchStart::default(),
        windowed: false,
        design_px: false,
        mouse_as_touch: false,
        script: Vec::new(),
    };
    let mut nt_down = false;
    for a in std::env::args().skip(1) {
        let (k, v) = a
            .split_once('=')
            .map(|(k, v)| (k, Some(v)))
            .unwrap_or((a.as_str(), None));
        match (k, v) {
            ("--screen", Some("both")) => args.screens = vec![ScreenKind::Hud, ScreenKind::Touch],
            ("--screen", Some("hud")) => args.screens = vec![ScreenKind::Hud],
            ("--screen", Some("touch")) => args.screens = vec![ScreenKind::Touch],
            ("--fixture", Some(name)) => {
                args.scenario = Scenario::parse(name)
                    .ok_or_else(|| anyhow::anyhow!("unknown fixture {name}"))?
            }
            ("--tab", Some(id)) => {
                args.touch.tab =
                    Some(TabId::parse(id).ok_or_else(|| anyhow::anyhow!("unknown tab {id}"))?)
            }
            ("--panel", Some(id)) => {
                args.touch.panel =
                    Some(PanelId::parse(id).ok_or_else(|| anyhow::anyhow!("unknown panel {id}"))?)
            }
            ("--dock", None) => args.touch.dock = true,
            ("--nt-down", None) => nt_down = true,
            ("--windowed", None) => args.windowed = true,
            ("--design-size", None) => args.design_px = true,
            ("--mouse-as-touch", None) => args.mouse_as_touch = true,
            ("--script", Some(s)) => args.script = dev_script::parse(s)?,
            _ => anyhow::bail!("unknown argument {a}\n{USAGE}"),
        }
    }
    if nt_down && args.scenario == Scenario::Demo {
        args.scenario = Scenario::NtDisconnected;
    }
    Ok(args)
}

fn main() -> anyhow::Result<()> {
    let args = parse_args()?;
    input::set_mouse_as_touch(args.mouse_as_touch);

    gpui_kit::application()
        .with_assets(assets::Assets)
        .run(move |cx| {
            gpui_kit::init(cx);
            if let Err(e) = assets::register_fonts(cx) {
                eprintln!("comp-gpui: font registration failed: {e:#}");
            }
            cx.on_action(|_: &Quit, cx| cx.quit());
            cx.bind_keys([
                KeyBinding::new("cmd-q", Quit, None),
                KeyBinding::new("ctrl-q", Quit, None),
            ]);
            cx.on_window_closed(|cx, _| cx.quit()).detach();

            let data = cx.new(|_| MockData::new(args.scenario));
            if args.scenario == Scenario::Demo {
                let data = data.clone();
                cx.spawn(async move |cx| {
                    loop {
                        cx.background_executor()
                            .timer(Duration::from_millis(20))
                            .await;
                        data.update(cx, |d, cx| {
                            if d.demo_tick() {
                                cx.notify();
                            }
                        });
                    }
                })
                .detach();
            }

            let displays = windows::displays(cx);
            let mut plan = windows::plan(&displays, &args.screens);
            if args.windowed {
                for (_, p) in plan.iter_mut() {
                    *p = Placement::Windowed {
                        reason: "--windowed".into(),
                    };
                }
            }
            for (index, (kind, placement)) in plan.into_iter().enumerate() {
                eprintln!("comp-gpui: {} {:?}", kind.title(), placement);
                let design_px = args.design_px && matches!(placement, Placement::Windowed { .. });
                let options = windows::options(kind, &placement, index, design_px, cx);
                let data = data.clone();
                let touch = args.touch.clone();
                let opened = match kind {
                    ScreenKind::Hud => gpui_kit::open_window(options, cx, move |window, cx| {
                        if design_px {
                            windows::resize_to_design_pixels(kind, window);
                        }
                        cx.new(|cx| hud::HudScreen::new(data, cx))
                    })
                    .map(|_| ()),
                    ScreenKind::Touch => gpui_kit::open_window(options, cx, move |window, cx| {
                        if design_px {
                            windows::resize_to_design_pixels(kind, window);
                        }
                        cx.new(|cx| TouchScreen::new(data, touch, cx))
                    })
                    .map(|(handle, _)| {
                        if !args.script.is_empty() {
                            dev_script::run(handle.into(), args.script.clone(), cx);
                        }
                    }),
                };
                if let Err(e) = opened {
                    eprintln!("comp-gpui: cannot open {}: {e:#}", kind.title());
                }
            }
            cx.activate(true);
        });
    Ok(())
}
