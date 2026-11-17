use std::ffi::OsString;
use std::fs;
use std::io::{self, BufReader, BufWriter};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context as _, Result, bail};
use protocol::{ToHost, ToProducer};

const BRIDGE_LIB: &str = "libgodot_bridge.dylib";
const LAUNCH_HOOK_LIB: &str = "libgodot_launch_hook.dylib";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

pub struct GodotConfig {
    pub binary: PathBuf,
    pub project: PathBuf,
    /// Where the bridge and launch hook dylibs were built: the host's own target profile dir.
    pub lib_dir: PathBuf,
    pub robot_glb: PathBuf,
    pub field_glb: PathBuf,
    pub extra_args: Vec<String>,
}

impl GodotConfig {
    pub fn from_env() -> Self {
        let app = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let lib_dir = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(Path::to_path_buf))
            .unwrap_or_default();
        let env_path = |key: &str, fallback: PathBuf| {
            std::env::var_os(key).map(PathBuf::from).unwrap_or(fallback)
        };
        Self {
            binary: env_path("GODOT_BIN", PathBuf::from("/opt/homebrew/bin/godot")),
            project: app.join("godot"),
            lib_dir,
            robot_glb: env_path("PWRUP_ROBOT_GLB", app.join("models/Robot-Full.glb")),
            field_glb: env_path(
                "PWRUP_FIELD_GLB",
                app.join("../comp/cad-assets/field-2026.glb"),
            ),
            extra_args: std::env::var("PWRUP_GODOT_ARGS")
                .map(|args| args.split_whitespace().map(str::to_string).collect())
                .unwrap_or_default(),
        }
    }
}

pub enum GodotEvent {
    Connected { pid: u32 },
    Message(ToHost),
    Exited { pid: u32, status: String },
    Failed(String),
}

/// Write half of the current Godot connection; sends are dropped while Godot is down.
#[derive(Clone, Default)]
pub struct ProducerLink(Arc<Mutex<Option<BufWriter<TcpStream>>>>);

impl ProducerLink {
    pub fn send(&self, message: &ToProducer) {
        let mut writer = self.0.lock().unwrap();
        if let Some(w) = writer.as_mut()
            && protocol::write_message(w, message).is_err()
        {
            *writer = None;
        }
    }

    pub fn is_connected(&self) -> bool {
        self.0.lock().unwrap().is_some()
    }

    fn set(&self, writer: Option<BufWriter<TcpStream>>) {
        *self.0.lock().unwrap() = writer;
    }
}

/// Keeps one Godot child alive: spawns it, forwards its messages, and respawns it whenever it
/// exits or its connection drops. Dropping the supervisor kills the child.
pub struct GodotSupervisor {
    link: ProducerLink,
    child: Arc<Mutex<Option<Child>>>,
    shutdown: Arc<AtomicBool>,
}

impl GodotSupervisor {
    pub fn start(config: GodotConfig) -> Result<(Self, async_channel::Receiver<GodotEvent>)> {
        prepare_project(&config)?;
        let (tx, rx) = async_channel::unbounded();
        let supervisor = Self {
            link: ProducerLink::default(),
            child: Arc::new(Mutex::new(None)),
            shutdown: Arc::new(AtomicBool::new(false)),
        };
        let link = supervisor.link.clone();
        let child = supervisor.child.clone();
        let shutdown = supervisor.shutdown.clone();
        std::thread::Builder::new()
            .name("godot-supervisor".into())
            .spawn(move || supervise(config, link, child, shutdown, tx))?;
        Ok((supervisor, rx))
    }

    pub fn link(&self) -> ProducerLink {
        self.link.clone()
    }

    pub fn pid(&self) -> Option<u32> {
        self.child.lock().unwrap().as_ref().map(Child::id)
    }
}

impl Drop for GodotSupervisor {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn supervise(
    config: GodotConfig,
    link: ProducerLink,
    child_slot: Arc<Mutex<Option<Child>>>,
    shutdown: Arc<AtomicBool>,
    tx: async_channel::Sender<GodotEvent>,
) {
    let mut quick_failures = 0u32;
    while !shutdown.load(Ordering::SeqCst) {
        let started = Instant::now();
        match run_once(&config, &link, &child_slot, &shutdown, &tx) {
            Ok((pid, status)) => {
                let _ = tx.send_blocking(GodotEvent::Exited { pid, status });
            }
            Err(error) => {
                let _ = tx.send_blocking(GodotEvent::Failed(format!("{error:#}")));
            }
        }
        link.set(None);
        if tx.is_closed() {
            break;
        }
        quick_failures = if started.elapsed() < Duration::from_secs(5) {
            quick_failures + 1
        } else {
            0
        };
        std::thread::sleep(Duration::from_millis(
            250 * u64::from(quick_failures.min(20)),
        ));
    }
}

fn run_once(
    config: &GodotConfig,
    link: &ProducerLink,
    child_slot: &Mutex<Option<Child>>,
    shutdown: &AtomicBool,
    tx: &async_channel::Sender<GodotEvent>,
) -> Result<(u32, String)> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    let mut command = Command::new(&config.binary);
    command
        .arg("--path")
        .arg(&config.project)
        .arg("--")
        .args(["--port", &port.to_string()])
        .arg("--robot")
        .arg(&config.robot_glb)
        .arg("--field")
        .arg(&config.field_glb)
        .args(&config.extra_args);
    let hook = config.project.join("bin").join(LAUNCH_HOOK_LIB);
    if hook.exists() {
        command.env("DYLD_INSERT_LIBRARIES", hook);
    }
    let child = command
        .spawn()
        .with_context(|| format!("spawning {}", config.binary.display()))?;
    let pid = child.id();
    *child_slot.lock().unwrap() = Some(child);
    if shutdown.load(Ordering::SeqCst) {
        kill(child_slot);
    }

    let stream = accept_from_child(&listener, child_slot);
    let stream = match stream {
        Ok(stream) => stream,
        Err(error) => {
            kill(child_slot);
            return Err(error);
        }
    };
    let _ = stream.set_nodelay(true);
    link.set(Some(BufWriter::new(stream.try_clone()?)));
    let _ = tx.send_blocking(GodotEvent::Connected { pid });
    let mut reader = BufReader::new(stream);
    while let Ok(Some(message)) = protocol::read_message::<ToHost>(&mut reader) {
        if tx.send_blocking(GodotEvent::Message(message)).is_err() {
            break;
        }
    }
    link.set(None);
    let status = kill(child_slot);
    Ok((pid, status))
}

fn accept_from_child(
    listener: &TcpListener,
    child_slot: &Mutex<Option<Child>>,
) -> Result<TcpStream> {
    listener.set_nonblocking(true)?;
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false)?;
                return Ok(stream);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.into()),
        }
        if let Some(child) = child_slot.lock().unwrap().as_mut()
            && let Some(status) = child.try_wait()?
        {
            bail!("Godot exited before connecting: {status}");
        }
        if Instant::now() > deadline {
            bail!("Godot did not connect within {CONNECT_TIMEOUT:?}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn kill(child_slot: &Mutex<Option<Child>>) -> String {
    let Some(mut child) = child_slot.lock().unwrap().take() else {
        return "already reaped".into();
    };
    let status = match child.try_wait() {
        Ok(Some(status)) => status,
        _ => {
            let _ = child.kill();
            match child.wait() {
                Ok(status) => status,
                Err(error) => return error.to_string(),
            }
        }
    };
    status.to_string()
}

/// Copies the bridge and launch hook built alongside this host into the Godot project, so a
/// debug host runs the debug bridge and a release host the release one, and runs Godot's import
/// pass when the project's scripts are newer than its class cache.
fn prepare_project(config: &GodotConfig) -> Result<()> {
    let bin = config.project.join("bin");
    fs::create_dir_all(&bin)?;
    for name in [BRIDGE_LIB, LAUNCH_HOOK_LIB] {
        let source = config.lib_dir.join(name);
        if !source.exists() {
            bail!(
                "{} is missing; build it with the host's profile, e.g. \
                 `cargo build --release -p godot-bridge -p godot-launch-hook`",
                source.display()
            );
        }
        copy_if_changed(&source, &bin.join(name))?;
    }

    let cache = config.project.join(".godot/global_script_class_cache.cfg");
    let needs_import = !config.project.join(".godot/extension_list.cfg").exists()
        || newest_source_mtime(&config.project)? > mtime(&cache).unwrap_or(SystemTime::UNIX_EPOCH);
    if needs_import {
        let status = Command::new(&config.binary)
            .args(["--headless", "--import", "--path"])
            .arg(&config.project)
            .status()
            .context("running the Godot import pass")?;
        if !status.success() {
            bail!("Godot import pass failed: {status}");
        }
        // Godot leaves an unchanged cache untouched, which would rerun the import every launch.
        if let Ok(file) = fs::File::options().append(true).open(&cache) {
            let _ = file.set_modified(SystemTime::now());
        }
    }
    Ok(())
}

fn copy_if_changed(source: &Path, dest: &Path) -> Result<()> {
    let same = match (fs::metadata(source), fs::metadata(dest)) {
        (Ok(a), Ok(b)) => a.len() == b.len() && a.modified().ok() <= b.modified().ok(),
        _ => false,
    };
    if same {
        return Ok(());
    }
    // A running Godot may have the old copy mapped; replacing the directory entry leaves its
    // inode intact where overwriting in place would not.
    let mut temp = OsString::from(dest.as_os_str());
    temp.push(".tmp");
    let temp = PathBuf::from(temp);
    fs::copy(source, &temp).with_context(|| format!("copying {}", source.display()))?;
    fs::rename(&temp, dest)?;
    Ok(())
}

fn mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

fn newest_source_mtime(dir: &Path) -> Result<SystemTime> {
    let mut newest = SystemTime::UNIX_EPOCH;
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') || name == "bin" {
            continue;
        }
        if entry.file_type()?.is_dir() {
            newest = newest.max(newest_source_mtime(&path)?);
        } else if matches!(
            path.extension().and_then(|e| e.to_str()),
            Some("gd" | "gdshader" | "gdshaderinc" | "tscn" | "godot" | "gdextension")
        ) {
            newest = newest.max(mtime(&path).unwrap_or(SystemTime::UNIX_EPOCH));
        }
    }
    Ok(newest)
}
