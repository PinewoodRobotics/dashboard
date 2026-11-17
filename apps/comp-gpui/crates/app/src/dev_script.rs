//! `--script="tap 42,118; wait 300; drag 1500,300 1800,300; key f3; type ab"`:
//! scripted mouse input in design pixels and key presses, dispatched through
//! GPUI's normal event path, for checking interactions without a person at
//! the screen. `key` takes a GPUI keystroke (f3, backspace, shift-left,
//! cmd-a); `type` presses one key per character of the rest of the step,
//! and a key nothing handles inserts its character into the focused text
//! field, as the OS text input would.

use std::time::Duration;

use gpui_kit::*;

#[derive(Clone, Debug)]
pub enum Step {
    Down(Point<f32>),
    Move(Point<f32>),
    Up(Point<f32>),
    Wait(u64),
    Key(Keystroke),
}

fn parse_keystroke(spec: &str) -> anyhow::Result<Keystroke> {
    let mut parts: Vec<&str> = spec.split('-').collect();
    let key = parts.pop().filter(|k| !k.is_empty());
    let key = key.ok_or_else(|| anyhow::anyhow!("bad key {spec}"))?;
    let mut modifiers = Modifiers::default();
    for m in parts {
        match m {
            "cmd" | "platform" => modifiers.platform = true,
            "ctrl" => modifiers.control = true,
            "alt" => modifiers.alt = true,
            "shift" => modifiers.shift = true,
            _ => anyhow::bail!("bad modifier {m} in {spec}"),
        }
    }
    Ok(Keystroke {
        modifiers,
        key: key.to_owned(),
        key_char: None,
    })
}

fn keystroke(key: &str, key_char: Option<String>, shift: bool) -> Keystroke {
    Keystroke {
        modifiers: Modifiers {
            shift,
            ..Modifiers::default()
        },
        key: key.to_owned(),
        key_char,
    }
}

fn parse_point(s: &str) -> anyhow::Result<Point<f32>> {
    let (x, y) = s
        .split_once(',')
        .ok_or_else(|| anyhow::anyhow!("bad point {s}"))?;
    Ok(point(x.trim().parse()?, y.trim().parse()?))
}

pub fn parse(script: &str) -> anyhow::Result<Vec<Step>> {
    let mut out = Vec::new();
    for cmd in script.split(';').map(str::trim).filter(|c| !c.is_empty()) {
        if let Some(text) = cmd.strip_prefix("type ") {
            out.extend(text.chars().map(|c| {
                let lower = if c == ' ' {
                    "space".to_owned()
                } else {
                    c.to_lowercase().to_string()
                };
                Step::Key(keystroke(&lower, Some(c.to_string()), c.is_uppercase()))
            }));
            continue;
        }
        let parts: Vec<&str> = cmd.split_whitespace().collect();
        match parts.as_slice() {
            ["wait", ms] => out.push(Step::Wait(ms.parse()?)),
            ["down", p] => out.push(Step::Down(parse_point(p)?)),
            ["move", p] => out.push(Step::Move(parse_point(p)?)),
            ["up", p] => out.push(Step::Up(parse_point(p)?)),
            ["key", k] => out.push(Step::Key(parse_keystroke(k)?)),
            ["tap", p] => {
                let p = parse_point(p)?;
                out.extend([Step::Down(p), Step::Wait(50), Step::Up(p)]);
            }
            ["drag", a, b, rest @ ..] => {
                let (a, b) = (parse_point(a)?, parse_point(b)?);
                let ms: u64 = rest.first().map(|s| s.parse()).transpose()?.unwrap_or(300);
                let steps = 12u64;
                out.push(Step::Down(a));
                for i in 1..=steps {
                    let t = i as f32 / steps as f32;
                    out.push(Step::Wait(ms / steps));
                    out.push(Step::Move(point(
                        a.x + (b.x - a.x) * t,
                        a.y + (b.y - a.y) * t,
                    )));
                }
                out.push(Step::Up(b));
            }
            _ => anyhow::bail!("unknown script step: {cmd}"),
        }
    }
    Ok(out)
}

pub fn run(handle: AnyWindowHandle, steps: Vec<Step>, cx: &mut App) {
    cx.spawn(async move |cx| {
        cx.background_executor()
            .timer(Duration::from_millis(800))
            .await;
        for step in steps {
            if let Step::Wait(ms) = step {
                cx.background_executor()
                    .timer(Duration::from_millis(ms))
                    .await;
                continue;
            }
            if let Step::Key(keystroke) = step {
                let _ = handle.update(cx, |_, window, cx| {
                    let text = keystroke.key_char.clone();
                    let result = window.dispatch_event(
                        PlatformInput::KeyDown(KeyDownEvent {
                            keystroke,
                            is_held: false,
                            prefer_character_input: false,
                        }),
                        cx,
                    );
                    if let Some(text) = text.filter(|_| result.propagate) {
                        crate::widgets::type_into_focused(&text, window, cx);
                    }
                });
                cx.background_executor()
                    .timer(Duration::from_millis(16))
                    .await;
                continue;
            }
            let _ = handle.update(cx, |_, window, cx| {
                let rem = window.rem_size();
                let at = |p: Point<f32>| point(rem * p.x, rem * p.y);
                let event = match step {
                    Step::Down(p) => PlatformInput::MouseDown(MouseDownEvent {
                        button: MouseButton::Left,
                        position: at(p),
                        modifiers: Modifiers::default(),
                        click_count: 1,
                        first_mouse: false,
                    }),
                    Step::Move(p) => PlatformInput::MouseMove(MouseMoveEvent {
                        position: at(p),
                        pressed_button: Some(MouseButton::Left),
                        modifiers: Modifiers::default(),
                    }),
                    Step::Up(p) => PlatformInput::MouseUp(MouseUpEvent {
                        button: MouseButton::Left,
                        position: at(p),
                        modifiers: Modifiers::default(),
                        click_count: 1,
                    }),
                    Step::Wait(_) | Step::Key(_) => unreachable!(),
                };
                window.dispatch_event(event, cx);
            });
            cx.background_executor()
                .timer(Duration::from_millis(16))
                .await;
        }
    })
    .detach();
}
