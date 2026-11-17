#[cfg(target_os = "macos")]
mod mac;
mod ring;
#[cfg(windows)]
mod win;

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

struct Link {
    writer: Mutex<BufWriter<TcpStream>>,
    ring: Mutex<RingState>,
    open: AtomicBool,
}

impl Link {
    fn send(&self, message: &ToHost) {
        let mut writer = self.writer.lock().unwrap();
        if protocol::write_message(&mut *writer, message).is_err() {
            self.open.store(false, Ordering::SeqCst);
        }
    }
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
struct HostBridge {
    link: Option<Arc<Link>>,
    #[cfg(target_os = "macos")]
    slots: Vec<mac::SharedSlot>,
    #[cfg(target_os = "macos")]
    queue: Option<
        objc2::rc::Retained<objc2::runtime::ProtocolObject<dyn objc2_metal::MTLCommandQueue>>,
    >,
    #[cfg(windows)]
    win: win::WinState,
    rids: Vec<Rid>,
    generation: u32,
    seq: u64,
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
            ring: Mutex::new(RingState::new(0)),
            open: AtomicBool::new(true),
        });
        let reader_link = link.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(reader_stream);
            while let Ok(Some(message)) = protocol::read_message::<ToProducer>(&mut reader) {
                match message {
                    ToProducer::Ack { slot, seq, .. } => {
                        reader_link.ring.lock().unwrap().ack(slot, seq);
                    }
                }
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

    #[func]
    fn hide_window(&self) {
        #[cfg(target_os = "macos")]
        mac::hide_app_windows();
        #[cfg(windows)]
        win::hide_window();
    }

    #[func]
    fn now_us(&self) -> i64 {
        protocol::now_us() as i64
    }

    #[func]
    fn create_ring(&mut self, width: i64, height: i64, count: i64) -> Array<Rid> {
        let mut rids = Array::new();
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
            let queue_handle =
                rd.get_driver_resource(DriverResource::COMMAND_QUEUE, Rid::Invalid, 0);
            let Some(device) = (unsafe { mac::device_from_handle(device_handle) }) else {
                godot_error!("bridge: no Metal device");
                return rids;
            };
            self.queue = unsafe { mac::queue_from_handle(queue_handle) };
            self.slots.clear();
            for _ in 0..count {
                let Some(slot) = mac::create_slot(&device, width as usize, height as usize) else {
                    godot_error!("bridge: IOSurface slot creation failed");
                    return rids;
                };
                self.slots.push(slot);
            }
            self.rids = self
                .slots
                .iter()
                .map(|slot| {
                    rd.texture_create_from_extension(
                        TextureType::TYPE_2D,
                        DataFormat::R8G8B8A8_UNORM,
                        TextureSamples::SAMPLES_1,
                        TextureUsageBits::CAN_COPY_TO_BIT | TextureUsageBits::SAMPLING_BIT,
                        slot.native_handle,
                        width as u64,
                        height as u64,
                        1,
                        1,
                    )
                })
                .collect();
            self.generation += 1;
            *link.ring.lock().unwrap() = RingState::new(count as usize);
            link.send(&ToHost::Surfaces {
                view: 0,
                generation: self.generation,
                width: width as u32,
                height: height as u32,
                ids: self.slots.iter().map(|slot| slot.id()).collect(),
            });
        }
        // UNTESTED. Slots are named from (pid, view, generation, index), so ids carries indices.
        #[cfg(windows)]
        {
            let generation = self.generation + 1;
            let handles = unsafe {
                self.win.create_ring(
                    rd.get_driver_resource(DriverResource::LOGICAL_DEVICE, Rid::Invalid, 0),
                    rd.get_driver_resource(DriverResource::COMMAND_QUEUE, Rid::Invalid, 0),
                    0,
                    generation,
                    width as u32,
                    height as u32,
                    count as u32,
                )
            };
            let Some(handles) = handles else {
                return rids;
            };
            self.rids = handles
                .into_iter()
                .map(|handle| {
                    rd.texture_create_from_extension(
                        TextureType::TYPE_2D,
                        DataFormat::R8G8B8A8_UNORM,
                        TextureSamples::SAMPLES_1,
                        TextureUsageBits::CAN_COPY_TO_BIT | TextureUsageBits::SAMPLING_BIT,
                        handle,
                        width as u64,
                        height as u64,
                        1,
                        1,
                    )
                })
                .collect();
            self.generation = generation;
            *link.ring.lock().unwrap() = RingState::new(count as usize);
            link.send(&ToHost::Surfaces {
                view: 0,
                generation,
                width: width as u32,
                height: height as u32,
                ids: (0..count as u32).collect(),
            });
        }
        for rid in &self.rids {
            rids.push(*rid);
        }
        rids
    }

    #[func]
    fn acquire_slot(&mut self) -> i64 {
        let Some(link) = &self.link else { return -1 };
        let next = self.seq + 1;
        match link.ring.lock().unwrap().acquire(next) {
            Some(slot) => {
                self.seq = next;
                slot as i64
            }
            None => -1,
        }
    }

    #[func]
    fn submit_frame(&mut self, slot: i64, cpu_ms: f64, render_submitted_us: i64) -> bool {
        let Some(link) = self.link.clone() else {
            return false;
        };
        let generation = self.generation;
        let seq = self.seq;
        #[cfg(target_os = "macos")]
        {
            let Some(queue) = &self.queue else {
                return false;
            };
            return mac::notify_when_queue_drains(queue, move || {
                let ready_us = protocol::now_us();
                link.send(&ToHost::Frame {
                    view: 0,
                    generation,
                    slot: slot as u32,
                    seq,
                    cpu_ms: cpu_ms as f32,
                    gpu_ms: (ready_us.saturating_sub(render_submitted_us as u64)) as f32 / 1000.0,
                    ready_us,
                });
            });
        }
        #[cfg(windows)]
        {
            return self.win.notify_when_queue_drains(move || {
                let ready_us = protocol::now_us();
                link.send(&ToHost::Frame {
                    view: 0,
                    generation,
                    slot: slot as u32,
                    seq,
                    cpu_ms: cpu_ms as f32,
                    gpu_ms: (ready_us.saturating_sub(render_submitted_us as u64)) as f32 / 1000.0,
                    ready_us,
                });
            });
        }
        #[allow(unreachable_code)]
        false
    }
}
