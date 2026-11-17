//! Every pointer interaction goes through this module: widgets start a
//! capture on press, and each window's root forwards moves and releases to
//! it, the way the web's `setPointerCapture` works. Input arrives as GPUI
//! mouse events today. GPUI's Windows touch support is not merged upstream;
//! when it is, touch events become `Pointer`s with `Source::Touch` next to the
//! mouse listeners in `install_root` and nothing else changes. Until then
//! `--mouse-as-touch` tags mouse input as touch to exercise the touch-only
//! paths (swipe dismissal, drag scrolling).

use std::cell::{Cell, RefCell};
use std::time::Instant;

use gpui_kit::*;

pub const TAP_SLOP: f32 = 16.0;
pub const INTENT_PX: f32 = 8.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Mouse,
    Touch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Down,
    Move,
    Up,
    /// Another gesture (a swipe dismissal) claimed the press.
    Cancel,
}

/// Positions are in design pixels of the window.
#[derive(Clone, Copy, Debug)]
pub struct Pointer {
    pub phase: Phase,
    pub pos: Point<f32>,
    pub source: Source,
    pub at: Instant,
}

impl Pointer {
    pub fn is_touch(&self) -> bool {
        self.source == Source::Touch
    }
}

type Handler = Box<dyn FnMut(&Pointer, &mut Window, &mut App)>;

thread_local! {
    static MOUSE_AS_TOUCH: Cell<bool> = const { Cell::new(false) };
    static CAPTURE: RefCell<Option<(WindowId, Handler)>> = const { RefCell::new(None) };
    static PRESS: Cell<PressContext> = const { Cell::new(PressContext::NONE) };
}

pub fn set_mouse_as_touch(on: bool) {
    MOUSE_AS_TOUCH.with(|c| c.set(on));
}

fn source() -> Source {
    if MOUSE_AS_TOUCH.with(|c| c.get()) {
        Source::Touch
    } else {
        Source::Mouse
    }
}

pub fn to_design(pos: Point<Pixels>, window: &Window) -> Point<f32> {
    let rem = f32::from(window.rem_size()).max(0.0001);
    point(f32::from(pos.x) / rem, f32::from(pos.y) / rem)
}

pub fn pointer(phase: Phase, pos: Point<Pixels>, window: &Window) -> Pointer {
    Pointer {
        phase,
        pos: to_design(pos, window),
        source: source(),
        at: Instant::now(),
    }
}

pub fn capture(window: &Window, handler: impl FnMut(&Pointer, &mut Window, &mut App) + 'static) {
    let id = window.window_handle().window_id();
    CAPTURE.with(|c| *c.borrow_mut() = Some((id, Box::new(handler))));
}

pub fn release_capture() {
    CAPTURE.with(|c| *c.borrow_mut() = None);
}

pub fn cancel_capture(at: Point<f32>, window: &mut Window, cx: &mut App) {
    let taken = CAPTURE.with(|c| c.borrow_mut().take());
    if let Some((_, mut handler)) = taken {
        let p = Pointer {
            phase: Phase::Cancel,
            pos: at,
            source: source(),
            at: Instant::now(),
        };
        handler(&p, window, cx);
    }
}

/// What lies under the current press, reported by the widgets it landed on:
/// the web's touchmove stopPropagation on sliders and selectors, and
/// scrollers away from their top, which the swipe recognizer must respect.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PressContext {
    pub widget: PressWidget,
    pub scroll_not_at_top: bool,
    pub vetoed: bool,
}

impl PressContext {
    pub const NONE: Self = Self {
        widget: PressWidget::None,
        scroll_not_at_top: false,
        vetoed: false,
    };
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PressWidget {
    None,
    Slider,
    Selector,
}

pub fn press_context() -> PressContext {
    PRESS.with(|p| p.get())
}

pub fn note_press_widget(widget: PressWidget) {
    PRESS.with(|p| {
        let mut c = p.get();
        if c.widget == PressWidget::None {
            c.widget = widget;
        }
        p.set(c);
    });
}

pub fn note_scroll_not_at_top() {
    PRESS.with(|p| {
        let mut c = p.get();
        c.scroll_not_at_top = true;
        p.set(c);
    });
}

pub fn veto_swipe() {
    PRESS.with(|p| {
        let mut c = p.get();
        c.vetoed = true;
        p.set(c);
    });
}

pub type Observer = std::rc::Rc<dyn Fn(&Pointer, &mut Window, &mut App)>;

/// `observer` sees every event: a press before any widget, a move or release
/// after the captured widget.
pub fn install_root(root: Div, observer: Observer) -> Div {
    root.child(hub_listener(observer))
}

fn dispatch(p: &Pointer, window: &mut Window, cx: &mut App) {
    let id = window.window_handle().window_id();
    let taken = CAPTURE.with(|c| {
        let mut slot = c.borrow_mut();
        match slot.as_ref() {
            Some((owner, _)) if *owner == id => slot.take(),
            _ => None,
        }
    });
    if let Some((owner, mut handler)) = taken {
        handler(p, window, cx);
        if p.phase == Phase::Move {
            CAPTURE.with(|c| {
                let mut slot = c.borrow_mut();
                if slot.is_none() {
                    *slot = Some((owner, handler));
                }
            });
        }
    }
}

/// Window-wide listeners, so overlays that occlude the root cannot hide a
/// press from the swipe recognizer.
fn hub_listener(observer: Observer) -> impl IntoElement {
    canvas(
        |_, _, _| {},
        move |_, _, window, _| {
            let down = observer.clone();
            window.on_mouse_event(move |e: &MouseDownEvent, phase, window, cx| {
                if phase != DispatchPhase::Capture || e.button != MouseButton::Left {
                    return;
                }
                release_capture();
                PRESS.with(|p| p.set(PressContext::NONE));
                let p = pointer(Phase::Down, e.position, window);
                down(&p, window, cx);
            });
            let mv = observer.clone();
            window.on_mouse_event(move |e: &MouseMoveEvent, phase, window, cx| {
                if phase != DispatchPhase::Capture || e.pressed_button != Some(MouseButton::Left) {
                    return;
                }
                let p = pointer(Phase::Move, e.position, window);
                dispatch(&p, window, cx);
                mv(&p, window, cx);
            });
            let up = observer.clone();
            window.on_mouse_event(move |e: &MouseUpEvent, phase, window, cx| {
                if phase != DispatchPhase::Capture || e.button != MouseButton::Left {
                    return;
                }
                let p = pointer(Phase::Up, e.position, window);
                dispatch(&p, window, cx);
                up(&p, window, cx);
            });
        },
    )
    .absolute()
    .size_0()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SwipeDir {
    Down,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SwipeState {
    Idle,
    Pending,
    Tracking,
    Rejected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SwipeOutcome {
    None,
    Commit,
    SnapBack,
}

/// Dismiss swipes (useSwipeGesture.ts). Once either axis has moved 8 px the
/// gesture is decided once: it tracks only if the main axis dominates and
/// moves in the swipe direction. Release commits at 35% of the dimension or
/// 0.5 px/ms over the last 5 tracked moves. A slider stops every move once
/// one has gone sideways; a selector lets only its first decided move
/// through, and only if it is vertical.
pub struct SwipeRecognizer {
    dir: SwipeDir,
    pub dimension: f32,
    state: SwipeState,
    pub delta: f32,
    start: Point<f32>,
    began: Instant,
    samples: Vec<(f32, f32)>,
    ctx: PressContext,
    widget_decided: bool,
    widget_horizontal: bool,
}

impl SwipeRecognizer {
    const COMMIT_FRACTION: f32 = 0.35;
    const COMMIT_VELOCITY: f32 = 0.5;
    const SAMPLES: usize = 5;

    pub fn new(dir: SwipeDir, dimension: f32) -> Self {
        Self {
            dir,
            dimension,
            state: SwipeState::Idle,
            delta: 0.0,
            start: point(0.0, 0.0),
            began: Instant::now(),
            samples: Vec::new(),
            ctx: PressContext::NONE,
            widget_decided: false,
            widget_horizontal: false,
        }
    }

    pub fn begin(&mut self, pos: Point<f32>) {
        self.start = pos;
        self.began = Instant::now();
        self.delta = 0.0;
        self.samples.clear();
        self.widget_decided = false;
        self.widget_horizontal = false;
        self.ctx = PressContext::NONE;
        self.state = SwipeState::Pending;
    }

    fn widget_stops(&mut self, d: Point<f32>) -> bool {
        match self.ctx.widget {
            PressWidget::Selector => {
                if self.widget_decided {
                    return true;
                }
                if d.x.abs() < INTENT_PX && d.y.abs() < INTENT_PX {
                    return false;
                }
                self.widget_decided = true;
                d.x.abs() > d.y.abs()
            }
            PressWidget::Slider => {
                if !self.widget_horizontal && (d.x.abs() >= INTENT_PX || d.y.abs() >= INTENT_PX) {
                    self.widget_horizontal = d.x.abs() > d.y.abs();
                }
                self.widget_horizontal
            }
            PressWidget::None => false,
        }
    }

    pub fn update(&mut self, pos: Point<f32>, at: Instant) -> bool {
        if self.state == SwipeState::Pending {
            self.ctx = press_context();
            if self.ctx.vetoed || (self.dir == SwipeDir::Down && self.ctx.scroll_not_at_top) {
                self.state = SwipeState::Rejected;
            }
        }
        if matches!(self.state, SwipeState::Idle | SwipeState::Rejected) {
            return false;
        }
        let d = point(pos.x - self.start.x, pos.y - self.start.y);
        if self.widget_stops(d) {
            return false;
        }
        let (main, cross) = match self.dir {
            SwipeDir::Down => (d.y, d.x),
            SwipeDir::Right => (d.x, d.y),
        };
        let mut started = false;
        if self.state == SwipeState::Pending {
            if d.x.abs() < INTENT_PX && d.y.abs() < INTENT_PX {
                return false;
            }
            if cross.abs() > main.abs() || main < 0.0 {
                self.state = SwipeState::Rejected;
                return false;
            }
            self.state = SwipeState::Tracking;
            started = true;
        }
        self.delta = main.clamp(0.0, self.dimension);
        let ms = at.duration_since(self.began).as_secs_f32() * 1000.0;
        self.samples.push((ms, self.delta));
        if self.samples.len() > Self::SAMPLES {
            self.samples.remove(0);
        }
        started
    }

    fn velocity(&self) -> f32 {
        if self.samples.len() < 2 {
            return 0.0;
        }
        let (t0, d0) = self.samples[0];
        let (t1, d1) = self.samples[self.samples.len() - 1];
        if t1 > t0 { (d1 - d0) / (t1 - t0) } else { 0.0 }
    }

    pub fn end(&mut self) -> SwipeOutcome {
        let was = self.state;
        self.state = SwipeState::Idle;
        if was != SwipeState::Tracking {
            return SwipeOutcome::None;
        }
        if self.delta >= self.dimension * Self::COMMIT_FRACTION
            || self.velocity() >= Self::COMMIT_VELOCITY
        {
            SwipeOutcome::Commit
        } else {
            SwipeOutcome::SnapBack
        }
    }

    pub fn is_tracking(&self) -> bool {
        self.state == SwipeState::Tracking
    }

    pub fn is_active(&self) -> bool {
        matches!(self.state, SwipeState::Pending | SwipeState::Tracking)
    }
}
