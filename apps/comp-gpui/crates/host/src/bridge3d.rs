use std::collections::HashMap;

use anyhow::Result;
use gpui_kit::*;
use protocol::{Scene, ToHost};

use crate::godot::{GodotConfig, GodotEvent, GodotSupervisor};
use crate::view3d::View3d;

/// The app's one Godot process and the views it renders, shared by every window.
pub struct Bridge3d {
    supervisor: GodotSupervisor,
    views: HashMap<u32, WeakEntity<View3d>>,
    next_id: u32,
    pid: Option<u32>,
    restarts: u32,
    last_exit: Option<String>,
    status: Vec<String>,
}

impl Bridge3d {
    pub fn start(config: GodotConfig, cx: &mut App) -> Result<Entity<Self>> {
        let (supervisor, events) = GodotSupervisor::start(config)?;
        Ok(cx.new(|cx| {
            cx.spawn(async move |this: WeakEntity<Bridge3d>, cx: &mut AsyncApp| {
                while let Ok(event) = events.recv().await {
                    if this
                        .update(cx, |bridge, cx| bridge.on_event(event, cx))
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .detach();
            Self {
                supervisor,
                views: HashMap::new(),
                next_id: 1,
                pid: None,
                restarts: 0,
                last_exit: None,
                status: Vec::new(),
            }
        }))
    }

    pub fn open_view(&mut self, scene: Scene, fps: u32, cx: &mut Context<Self>) -> Entity<View3d> {
        let id = self.next_id;
        self.next_id += 1;
        let view = cx.new(|_| View3d::new(id, scene, fps, self.supervisor.link()));
        self.views.insert(id, view.downgrade());
        view
    }

    pub fn close_view(&mut self, view: &Entity<View3d>, cx: &mut Context<Self>) {
        view.update(cx, |view, _| view.close());
        self.views.remove(&view.read(cx).id());
    }

    pub fn pid(&self) -> Option<u32> {
        self.pid.or_else(|| self.supervisor.pid())
    }

    pub fn status_lines(&self) -> Vec<String> {
        let mut lines = vec![format!(
            "godot pid {} restarts {}{}",
            self.pid
                .map(|pid| pid.to_string())
                .unwrap_or_else(|| "-".into()),
            self.restarts,
            self.last_exit
                .as_ref()
                .map(|exit| format!(" (last exit: {exit})"))
                .unwrap_or_default()
        )];
        lines.extend(self.status.iter().cloned());
        lines
    }

    fn on_event(&mut self, event: GodotEvent, cx: &mut Context<Self>) {
        match event {
            GodotEvent::Connected { pid } => {
                eprintln!("bridge: Godot {pid} connected");
                self.pid = Some(pid);
                self.status.clear();
                self.views.retain(|_, view| view.upgrade().is_some());
                for view in self.views.values() {
                    view.update(cx, |view, _| view.on_connected()).ok();
                }
            }
            GodotEvent::Message(ToHost::Status { message }) => {
                eprintln!("godot: {message}");
                self.status.push(message);
                if self.status.len() > 3 {
                    self.status.remove(0);
                }
            }
            GodotEvent::Message(message) => {
                let id = match &message {
                    ToHost::Surfaces { view, .. } | ToHost::Frame { view, .. } => *view,
                    ToHost::Status { .. } => return,
                };
                if let Some(view) = self.views.get(&id) {
                    view.update(cx, |view, cx| view.on_message(message, cx))
                        .ok();
                }
                return;
            }
            GodotEvent::Exited { pid, status } => {
                eprintln!("bridge: Godot {pid} exited ({status}); respawning");
                self.pid = None;
                self.restarts += 1;
                self.last_exit = Some(status);
            }
            GodotEvent::Failed(error) => {
                eprintln!("bridge: Godot launch failed: {error}");
                self.pid = None;
                self.last_exit = Some(error);
            }
        }
        cx.notify();
    }
}
