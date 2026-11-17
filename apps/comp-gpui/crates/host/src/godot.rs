use std::io::{BufReader, BufWriter};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::{Arc, Mutex};

use anyhow::{Context as _, Result, bail};
use protocol::{ToHost, ToProducer};

#[cfg(not(windows))]
const DEFAULT_GODOT_BIN: &str = "/opt/homebrew/bin/godot";
#[cfg(windows)]
const DEFAULT_GODOT_BIN: &str = "godot";
#[cfg(not(windows))]
const BRIDGE_LIBRARY: &str = "libgodot_bridge.dylib";
#[cfg(windows)]
const BRIDGE_LIBRARY: &str = "godot_bridge.dll";

pub struct GodotConfig {
    pub binary: PathBuf,
    pub project: PathBuf,
    pub fps: u32,
    pub width: u32,
    pub height: u32,
}

impl GodotConfig {
    pub fn from_env() -> Self {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        Self {
            binary: std::env::var_os("GODOT_BIN")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(DEFAULT_GODOT_BIN)),
            project: root.join("godot"),
            fps: 120,
            width: 1280,
            height: 720,
        }
    }
}

pub struct GodotProcess {
    child: Child,
    writer: Arc<Mutex<Option<BufWriter<TcpStream>>>>,
}

impl GodotProcess {
    pub fn spawn(config: &GodotConfig) -> Result<(Self, async_channel::Receiver<ToHost>)> {
        let bridge = config
            .project
            .join("../target/release")
            .join(BRIDGE_LIBRARY);
        if !bridge.exists() {
            bail!(
                "{} is missing; run `cargo build --release -p godot-bridge` first",
                bridge.display()
            );
        }
        // Godot only loads a GDExtension listed in .godot/extension_list.cfg, which is written
        // by an import pass; a fresh checkout has no .godot directory.
        if !config.project.join(".godot/extension_list.cfg").exists() {
            let status = Command::new(&config.binary)
                .args(["--headless", "--import", "--path"])
                .arg(&config.project)
                .status()
                .context("running the Godot import pass")?;
            if !status.success() {
                bail!("Godot import pass failed: {status}");
            }
        }

        let listener = TcpListener::bind("127.0.0.1:0")?;
        let port = listener.local_addr()?.port();
        let child = Command::new(&config.binary)
            .args(std::env::var("GODOT_ARGS").unwrap_or_default().split_whitespace())
            .arg("--path")
            .arg(&config.project)
            .arg("--")
            .args(["--port", &port.to_string()])
            .args(["--fps", &config.fps.to_string()])
            .args(["--width", &config.width.to_string()])
            .args(["--height", &config.height.to_string()])
            .spawn()
            .with_context(|| format!("spawning {}", config.binary.display()))?;

        let (tx, rx) = async_channel::unbounded();
        let writer = Arc::new(Mutex::new(None));
        let accept_writer = writer.clone();
        std::thread::spawn(move || {
            let Ok((stream, _)) = listener.accept() else {
                return;
            };
            let _ = stream.set_nodelay(true);
            let Ok(write_half) = stream.try_clone() else {
                return;
            };
            *accept_writer.lock().unwrap() = Some(BufWriter::new(write_half));
            let mut reader = BufReader::new(stream);
            while let Ok(Some(message)) = protocol::read_message::<ToHost>(&mut reader) {
                if tx.send_blocking(message).is_err() {
                    break;
                }
            }
        });
        Ok((Self { child, writer }, rx))
    }

    #[cfg_attr(not(windows), expect(dead_code))]
    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    pub fn send(&self, message: &ToProducer) {
        if let Some(writer) = self.writer.lock().unwrap().as_mut() {
            let _ = protocol::write_message(writer, message);
        }
    }
}

impl Drop for GodotProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
