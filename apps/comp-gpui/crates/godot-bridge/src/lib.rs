#[cfg(target_os = "macos")]
mod mac;
mod ring;

use std::collections::HashMap;
use std::io::{BufReader, BufWriter};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use godot::classes::rendering_device::{
    DataFormat, DriverResource, TextureSamples, TextureType, TextureUsageBits,
};
use godot::classes::{RefCounted, RenderingServer};
use godot::prelude::*;
use protocol::{ToHost, ToProducer};

use crate::ring::RingState;

struct Bridge;

#[gdextension]
unsafe impl ExtensionLibrary for Bridge {}

struct ViewRing {
    generation: u32,
    state: RingState,
}

struct Link {
    writer: Mutex<BufWriter<TcpStream>>,
    rings: Mutex<HashMap<u32, ViewRing>>,
    inbox: Mutex<Vec<String>>,
    open: AtomicBool,
}

impl Link {
    fn send(&self, message: &ToHost) {
        let mut writer = self.writer.lock().unwrap();
        if protocol::write_message(&mut *writer, message).is_err() {
            self.open.store(false, Ordering::SeqCst);
        }
    }

    fn receive(&self, message: ToProducer) {
        match message {
            ToProducer::Ack {
                view,
                generation,
                slot,
                seq,
            } => {
                if let Some(ring) = self.rings.lock().unwrap().get_mut(&view)
                    && ring.generation == generation
                {
                    ring.state.ack(slot, seq);
                }
            }
            other => {
                if let Ok(line) = serde_json::to_string(&other) {
                    self.inbox.lock().unwrap().push(line);
                }
            }
        }
    }
}

#[derive(Default)]
struct ViewSlots {
    #[cfg(target_os = "macos")]
    slots: Vec<mac::SharedSlot>,
    generation: u32,
    seq: u64,
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
struct HostBridge {
    link: Option<Arc<Link>>,
    #[cfg(target_os = "macos")]
    queue: Option<
        objc2::rc::Retained<objc2::runtime::ProtocolObject<dyn objc2_metal::MTLCommandQueue>>,
    >,
    views: HashMap<u32, ViewSlots>,
    base: Base<RefCounted>,
}

#[godot_api]
impl HostBridge {
    #[func]
    fn connect_host(&mut self, port: i64) -> bool {
        let Ok(stream) = TcpStream::connect(("127.0.0.1", port as u16)) else {
            godot_error!("bridge: cannot connect to host on port {port}");
            return false;
        };
        let _ = stream.set_nodelay(true);
        let Ok(reader_stream) = stream.try_clone() else {
            return false;
        };
        let link = Arc::new(Link {
            writer: Mutex::new(BufWriter::new(stream)),
            rings: Mutex::new(HashMap::new()),
            inbox: Mutex::new(Vec::new()),
            open: AtomicBool::new(true),
        });
        let reader_link = link.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(reader_stream);
            while let Ok(Some(message)) = protocol::read_message::<ToProducer>(&mut reader) {
                reader_link.receive(message);
            }
            reader_link.open.store(false, Ordering::SeqCst);
        });
        self.link = Some(link);
        true
    }

    #[func]
    fn host_connected(&self) -> bool {
        self.link
            .as_ref()
            .is_some_and(|link| link.open.load(Ordering::SeqCst))
    }

    /// Host messages other than Ack (which the bridge applies itself), as JSON lines.
    #[func]
    fn poll_messages(&self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        if let Some(link) = &self.link {
            for line in link.inbox.lock().unwrap().drain(..) {
                out.push(&GString::from(&line));
            }
        }
        out
    }

    #[func]
    fn send_status(&self, message: GString) {
        if let Some(link) = &self.link {
            link.send(&ToHost::Status {
                message: message.to_string(),
            });
        }
    }

    #[func]
    fn hide_window(&self) {
        #[cfg(target_os = "macos")]
        mac::hide_app_windows();
    }

    #[func]
    fn now_us(&self) -> i64 {
        protocol::now_us() as i64
    }

    /// Allocates a new generation of shared slots for `view` and announces it to the host. The
    /// caller owns the returned RIDs and frees the previous generation's.
    #[func]
    fn create_ring(&mut self, view: i64, width: i64, height: i64, count: i64) -> Array<Rid> {
        let mut rids = Array::new();
        let view = view as u32;
        let Some(link) = self.link.clone() else {
            godot_error!("bridge: create_ring before connect_host");
            return rids;
        };
        let Some(mut rd) = RenderingServer::singleton().get_rendering_device() else {
            godot_error!("bridge: no RenderingDevice");
            return rids;
        };
        #[cfg(target_os = "macos")]
        {
            let device_handle =
                rd.get_driver_resource(DriverResource::LOGICAL_DEVICE, Rid::Invalid, 0);
            let Some(device) = (unsafe { mac::device_from_handle(device_handle) }) else {
                godot_error!("bridge: no Metal device");
                return rids;
            };
            if self.queue.is_none() {
                let queue_handle =
                    rd.get_driver_resource(DriverResource::COMMAND_QUEUE, Rid::Invalid, 0);
                self.queue = unsafe { mac::queue_from_handle(queue_handle) };
            }
            let mut slots = Vec::new();
            for _ in 0..count {
                let Some(slot) = mac::create_slot(&device, width as usize, height as usize) else {
                    godot_error!("bridge: IOSurface slot creation failed");
                    return rids;
                };
                slots.push(slot);
            }
            for slot in &slots {
                rids.push(rd.texture_create_from_extension(
                    TextureType::TYPE_2D,
                    DataFormat::R8G8B8A8_UNORM,
                    TextureSamples::SAMPLES_1,
                    TextureUsageBits::CAN_COPY_TO_BIT | TextureUsageBits::SAMPLING_BIT,
                    slot.native_handle,
                    width as u64,
                    height as u64,
                    1,
                    1,
                ));
            }
            let ids = slots.iter().map(|slot| slot.id()).collect();
            let entry = self.views.entry(view).or_default();
            entry.generation += 1;
            entry.slots = slots;
            link.rings.lock().unwrap().insert(
                view,
                ViewRing {
                    generation: entry.generation,
                    state: RingState::new(count as usize),
                },
            );
            link.send(&ToHost::Surfaces {
                view,
                generation: entry.generation,
                width: width as u32,
                height: height as u32,
                ids,
            });
        }
        rids
    }

    #[func]
    fn release_ring(&mut self, view: i64) {
        let view = view as u32;
        self.views.remove(&view);
        if let Some(link) = &self.link {
            link.rings.lock().unwrap().remove(&view);
        }
    }

    #[func]
    fn acquire_slot(&mut self, view: i64) -> i64 {
        let view = view as u32;
        let Some(link) = &self.link else { return -1 };
        let Some(entry) = self.views.get_mut(&view) else {
            return -1;
        };
        let next = entry.seq + 1;
        let mut rings = link.rings.lock().unwrap();
        let Some(ring) = rings.get_mut(&view) else {
            return -1;
        };
        match ring.state.acquire(next) {
            Some(slot) => {
                entry.seq = next;
                slot as i64
            }
            None => -1,
        }
    }

    /// Sends Frame once Godot's queue has drained past this tick's copies.
    #[func]
    fn submit_frame(
        &mut self,
        view: i64,
        slot: i64,
        cpu_ms: f64,
        render_submitted_us: i64,
        input_stamp: i64,
    ) -> bool {
        let view = view as u32;
        let Some(link) = self.link.clone() else {
            return false;
        };
        let Some(entry) = self.views.get(&view) else {
            return false;
        };
        let generation = entry.generation;
        let seq = entry.seq;
        #[cfg(target_os = "macos")]
        {
            let Some(queue) = &self.queue else {
                return false;
            };
            return mac::notify_when_queue_drains(queue, move || {
                let ready_us = protocol::now_us();
                link.send(&ToHost::Frame {
                    view,
                    generation,
                    slot: slot as u32,
                    seq,
                    cpu_ms: cpu_ms as f32,
                    gpu_ms: (ready_us.saturating_sub(render_submitted_us as u64)) as f32 / 1000.0,
                    ready_us,
                    input_stamp: input_stamp.max(0) as u64,
                });
            });
        }
        #[allow(unreachable_code)]
        false
    }
}
