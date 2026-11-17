#![allow(dead_code)]

mod anim;
mod assets;
mod autos;
mod debug_overlay;
mod dev_script;
mod hud;
mod icons;
mod input;
mod match_feed;
mod mock;
mod nt_source;
mod placeholder;
mod screen;
mod settings;
mod theme;
mod touch;
mod touch_test;
mod widgets;
mod windows;

use std::path::PathBuf;
use std::time::Duration;

use gpui_kit::*;

use crate::mock::{MockData, Scenario};
use crate::touch::{PanelId, TabId, TouchStart};
use crate::windows::ScreenKind;

gpui_kit::actions!(comp, [Quit]);

struct Args {
    screens: Vec<ScreenKind>,
    scenario: Scenario,
    touch: TouchStart,
    windowed: bool,
    design_px: bool,
    mouse_as_touch: bool,
    touch_test: bool,
    debug_overlay: bool,
    script: Vec<dev_script::Step>,
    nt_host: Option<String>,
    nt_port: Option<u16>,
    settings: Option<PathBuf>,
    auto_fixture: Option<autos::Fixture>,
}

const USAGE: &str = "usage: comp-gpui [--screen=both|hud|touch] [--fixture=NAME] [--tab=ID] [--panel=map|intake] \
[--dock] [--nt-down] [--nt-host=HOST] [--nt-port=PORT] [--windowed] [--design-size] [--mouse-as-touch] \
[--touch-test] [--debug-overlay] [--script=STEPS] [--settings=PATH]";

fn parse_args() -> anyhow::Result<Args> {
    let mut args = Args {
        screens: vec![ScreenKind::Hud, ScreenKind::Touch],
        scenario: Scenario::Demo,
        touch: TouchStart::default(),
        windowed: false,
        design_px: false,
        mouse_as_touch: false,
        touch_test: false,
        debug_overlay: false,
        script: Vec::new(),
        nt_host: None,
        nt_port: None,
        settings: None,
        auto_fixture: None,
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
                if let Some(fx) = autos::Fixture::parse(name) {
                    args.scenario = Scenario::PreMatch;
                    args.touch.tab.get_or_insert(TabId::Auto);
                    args.auto_fixture = Some(fx);
                } else {
                    args.scenario = Scenario::parse(name)
                        .ok_or_else(|| anyhow::anyhow!("unknown fixture {name}"))?
                }
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
            ("--touch-test", None) => args.touch_test = true,
            ("--debug-overlay", None) => args.debug_overlay = true,
            ("--script", Some(s)) => args.script = dev_script::parse(s)?,
            ("--nt-host", Some(h)) => args.nt_host = Some(h.to_owned()),
            ("--nt-port", Some(p)) => {
                args.nt_port = Some(p.parse().map_err(|_| anyhow::anyhow!("bad --nt-port {p}"))?)
            }
            ("--settings", Some(p)) => args.settings = Some(PathBuf::from(p)),
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
            cx.on_window_closed(|cx, id| {
                if !windows::closing_for_retile(id) {
                    cx.quit();
                }
            })
            .detach();
            debug_overlay::init(cx);
            if args.touch_test {
                touch_test::open_all(cx);
            }

            let data = cx.new(|_| MockData::new(args.scenario));
            settings::install(
                &data,
                settings::Options::new(args.settings.clone(), args.scenario != Scenario::Demo),
                cx,
            );
            autos::init(data.clone(), args.auto_fixture.clone(), cx);
            if args.nt_host.is_some() || args.nt_port.is_some() {
                let (host, port) = (args.nt_host.clone(), args.nt_port);
                let mut source = data.update(cx, |d, _| nt_source::NtSource::start(d, host, port));
                let data = data.clone();
                cx.spawn(async move |cx| {
                    loop {
                        cx.background_executor()
                            .timer(Duration::from_millis(16))
                            .await;
                        data.update(cx, |d, cx| {
                            if source.tick(d) {
                                cx.notify();
                            }
                        });
                    }
                })
                .detach();
            } else if args.scenario == Scenario::Demo {
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

            let opened = windows::open_all(
                &data,
                windows::OpenOptions {
                    screens: args.screens.clone(),
                    force_windowed: args.windowed,
                    design_px: args.design_px,
                    touch: args.touch.clone(),
                },
                cx,
            );
            if args.debug_overlay
                && let Some((_, first)) = opened.first()
            {
                debug_overlay::open(first.window_id(), cx);
            }
            let script_target = opened
                .iter()
                .find(|(kind, _)| *kind == ScreenKind::Touch)
                .or_else(|| opened.first().filter(|_| args.screens == [ScreenKind::Hud]));
            if let Some((_, handle)) = script_target
                && !args.script.is_empty()
            {
                dev_script::run(*handle, args.script.clone(), cx);
            }
            cx.activate(true);
        });
    Ok(())
}
