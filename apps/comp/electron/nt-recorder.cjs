const fs = require("fs");
const path = require("path");
const { EventEmitter } = require("events");
const { promises: fsp } = require("fs");
const { VideoSink } = require("./video-sink.cjs");

const STATUS_INTERVAL_MS = 250;
const RATE_WINDOW_MS = 2000;
const RATE_BUCKET_MS = 250;
const RATE_BUCKET_COUNT = RATE_WINDOW_MS / RATE_BUCKET_MS;
const AUTO_STOP_GRACE_MS = 5000;
// How long stop() waits for the renderer to push MediaRecorder's trailing chunk(s)
// and call endVideo(). The renderer may be slow, backgrounded or already gone, so
// this is a bound, not a contract.
const VIDEO_TAIL_TIMEOUT_MS = 3000;
const VIDEO_TAIL_POLL_MS = 25;
// A flush that has not settled in this long means the volume is hung rather than slow.
const FLUSH_STALL_TIMEOUT_MS = 10_000;
const CHANNEL_PREFIX = "NT:";
const MARKER_CHANNEL = "PWRUP:/Recorder/Marker";
const CONNECTED_CHANNEL = "PWRUP:/Recorder/Connected";
const ENABLED_TOPIC = "/AdvantageKit/DriverStation/Enabled";
const FMS_CONTROL_TOPIC = "/FMSInfo/FMSControlData";
// The simulator's enable signal. PWRDrive's own NT server publishes neither of the two
// real signals above, so without this fallback auto-record cannot be exercised against
// the simulator at all. Deliberately ranked last: on a real robot the DriverStation and
// FMS topics are authoritative and this one must never override them.
const SIM_RUNNING_TOPIC = "/AdvantageKit/RealOutputs/MatchStatus/Running";
const SESSION_ID_PATTERN = /^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:-\d+)?$/;
// Rank of each enable signal; a lower-ranked source never overrides a higher-ranked one.
const ENABLED_SOURCE_RANK = { advantagekit: 3, fms: 2, simulator: 1 };

function defaultCreateClient(options) {
  const { Nt4RecordClient } = require("./nt4-record-client.cjs");
  return new Nt4RecordClient(options);
}

function defaultCreateWriter(filePath, extraHeader) {
  const { WpilogWriter } = require("./wpilog-writer.cjs");
  return new WpilogWriter(filePath, extraHeader);
}

function defaultCreateVideoSink(filePath) {
  return new VideoSink(filePath);
}

// require("electron") resolves to a path string when running under plain node,
// which keeps this module usable from the __checks__ scripts.
function loadElectron() {
  try {
    const electron = require("electron");
    return electron && typeof electron === "object" ? electron : null;
  } catch {
    return null;
  }
}

function pad2(value) {
  return String(value).padStart(2, "0");
}

function formatSessionId(date) {
  return (
    `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}` +
    `_${pad2(date.getHours())}-${pad2(date.getMinutes())}-${pad2(date.getSeconds())}`
  );
}

function errorMessage(error) {
  if (!error) return "Unknown error";
  return typeof error === "string" ? error : String(error.message ?? error);
}

/**
 * NT4 and WPILOG name integer types differently — NT4 announces "int" / "int[]" where the
 * data log spells them "int64" / "int64[]". That is the only divergence between the two
 * vocabularies; every other NT type string (including "json", "msgpack", "protobuf",
 * "struct:Pose2d" and friends) is already a valid WPILOG type and passes through untouched.
 * Getting this wrong makes every integer topic on the robot unwritable.
 */
/** Socket-level errors from the reconnect loop: expected whenever the robot is not up. */
const CONNECTION_ERROR_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "ETIMEDOUT",
  "EHOSTUNREACH",
  "EHOSTDOWN",
  "ENETUNREACH",
  "ENETDOWN",
  "ENOTFOUND",
  "EAI_AGAIN",
  "EPIPE",
]);

function isConnectionError(error) {
  return Boolean(error) && CONNECTION_ERROR_CODES.has(error.code);
}

function ntTypeToWpilogType(ntType) {
  if (ntType === "int") return "int64";
  if (ntType === "int[]") return "int64[]";
  return ntType;
}

/**
 * Owns the recording lifecycle: an always-on NT4 client (module B) feeding a
 * wpilog writer (module A) that only exists while a session is running.
 *
 * The client is connected whenever a host is configured, recording or not, so
 * pressing start is instantaneous and auto-record-on-enable can work at all.
 */
class NtRecorder extends EventEmitter {
  constructor({
    settingsManager,
    recordingsDir,
    createClient = defaultCreateClient,
    createWriter = defaultCreateWriter,
    createVideoSink = defaultCreateVideoSink,
    autoStopGraceMs = AUTO_STOP_GRACE_MS,
    videoTailTimeoutMs = VIDEO_TAIL_TIMEOUT_MS,
  }) {
    super();
    this.settingsManager = settingsManager ?? null;
    this.recordingsDir = recordingsDir;
    this.createClient = createClient;
    this.createWriter = createWriter;
    this.createVideoSink = createVideoSink;
    this.autoStopGraceMs = autoStopGraceMs;
    this.videoTailTimeoutMs = videoTailTimeoutMs;

    this.snapshot = null;
    this.client = null;
    this.clientKey = "";
    this.host = "";
    this.port = 5810;
    this.isConnected = false;

    this.topics = new Map(); // topic name -> { name, type, properties }
    this.latestValues = new Map(); // topic name -> { type, value, timestampUs }
    this.lastServerTimestampUs = 0;

    this.autoRecord = false;
    this.robotEnabled = false;
    this.enabledSource = null; // "advantagekit" | "fms"
    this.autoStopHandle = null;

    this.session = null;
    this.lastError = null;

    this.statusTickHandle = null;
    this.statusTrailingHandle = null;
    this.lastStatusEmitMs = 0;

    this.onSettingsChange = (snapshot) => this.updateSettingsSnapshot(snapshot);
    this.isShuttingDown = false;
    // Set when the socket opened before any server clock was known; the connect marker
    // waits here until the first sample supplies a real timestamp.
    this.pendingConnectedMarker = false;
  }

  initialize() {
    this.snapshot = this.settingsManager?.getSnapshot?.() ?? null;
    if (typeof this.settingsManager?.on === "function") {
      this.settingsManager.on("change", this.onSettingsChange);
    }
    this.#ensureClient();
    this.#emitStatus(true);
  }

  updateSettingsSnapshot(snapshot) {
    this.snapshot = snapshot;
    this.#ensureClient();
  }

  getStatus() {
    const session = this.session;
    const recording = Boolean(session) && !session.stopping;

    return {
      isRecording: recording,
      isConnected: this.isConnected,
      host: this.host,
      port: this.port,
      sessionId: session ? session.id : null,
      startedAtIso: session ? session.startedAtIso : null,
      elapsedMs: session ? Date.now() - session.startedAtMs : 0,
      bytesWritten: session ? this.#sessionBytes(session) : 0,
      topicCount: this.#topicCount(),
      sampleCount: session ? session.sampleCount : 0,
      samplesPerSecond: session ? this.#samplesPerSecond(session) : 0,
      hadConnectionLoss: session ? session.hadConnectionLoss : false,
      autoRecord: this.autoRecord,
      robotEnabled: this.robotEnabled,
      // "advantagekit" | "fms" | "simulator" | null - which NT topic the enable state
      // came from, so the UI can say why auto-record is (not) arming.
      robotEnabledSource: this.enabledSource,
      recordingsDir: this.recordingsDir,
      lastError: this.lastError,
      // Bytes the writer has buffered but not yet handed to the OS. A number that
      // climbs and stays up means the disk is not keeping up.
      writeBacklogBytes: session ? this.#writerBacklogBytes(session) : 0,
      video: session && session.video ? this.#videoStatus(session) : null,
    };
  }

  setAutoRecord(enabled) {
    const next = Boolean(enabled);
    if (next === this.autoRecord) return this.getStatus();

    this.autoRecord = next;
    if (!next) this.#cancelAutoStop();
    this.#emitStatus(true);
    return this.getStatus();
  }

  setRecordingsDir(absPath) {
    if (typeof absPath !== "string" || !path.isAbsolute(absPath)) {
      throw new Error("Recordings directory must be an absolute path.");
    }
    if (absPath === this.recordingsDir) return this.getStatus();

    // An in-flight session keeps writing to the paths it was created with.
    this.recordingsDir = absPath;
    this.#emitStatus(true);
    return this.getStatus();
  }

  async start({ note = null, autoStarted = false } = {}) {
    if (this.session) {
      throw new Error("A recording is already in progress.");
    }

    await fsp.mkdir(this.recordingsDir, { recursive: true });

    const startedAt = new Date();
    const id = this.#allocateSessionId(startedAt);
    const startedAtIso = startedAt.toISOString();
    const logPath = path.join(this.recordingsDir, `${id}.wpilog`);
    const extraHeader = JSON.stringify({
      source: "pwrup-comp-dashboard",
      kind: "nt-client-recording",
      version: 1,
      host: this.host,
      port: this.port,
      startedAtIso,
      sessionId: id,
    });

    const writer = this.createWriter(logPath, extraHeader);
    await writer.open();

    const session = {
      id,
      logPath,
      sidecarPath: path.join(this.recordingsDir, `${id}.json`),
      videoPath: path.join(this.recordingsDir, `${id}.webm`),
      startedAtMs: startedAt.getTime(),
      startedAtIso,
      writer,
      entries: new Map(), // channel name -> { entryId, type }
      sampleCount: 0,
      ntEntryCount: 0,
      firstServerTimestampUs: null,
      lastTimestampUs: 0,
      hadConnectionLoss: false,
      autoStarted: Boolean(autoStarted),
      note: typeof note === "string" && note.trim().length > 0 ? note.trim() : null,
      rateBuckets: [],
      video: null,
      stopping: false,
      failed: false,
      flushInFlight: false,
      flushStartedAtMs: 0,
      skippedSeedTopics: [],
    };
    this.session = session;
    this.lastError = null;

    // The seed batch is one snapshot, so it gets one timestamp. It must not be "now":
    // cached values were sampled a publish period plus RTT ago, so stamping the batch at
    // now and then streaming those older frames puts a backward step in every log.
    // Anchoring at the oldest value in the batch keeps the opening monotonic — every
    // later frame for a topic is necessarily newer than that topic's cached sample, which
    // is in turn no older than this minimum.
    // Entry ids are written per record in the minimum number of bytes, so ids 1..255 cost
    // one byte and everything above costs two. On the real robot 300 of 561 announced
    // topics never carry a value; letting those take the low ids pushes every one of the
    // ~7,000 records/s onto 2-byte ids and wastes exactly 1 byte per record — measured at
    // 3.67% of the file, about 25 MB over a 40-minute practice session. Seed the topics
    // that actually have data first. (This only bites when the client has been running
    // long enough to have cached values, which the always-on client makes the normal case.)
    const knownTopics = this.#knownTopics()
      .slice()
      .sort((a, b) => {
        const aHas = this.latestValues.has(a.name) ? 0 : 1;
        const bHas = this.latestValues.has(b.name) ? 0 : 1;
        return aHas - bHas;
      });
    const seedTimestamps = knownTopics
      .map((topic) => this.latestValues.get(topic.name)?.timestampUs)
      .filter((ts) => typeof ts === "number" && ts > 0);
    const nowUs = this.#timestampUs();
    const baseTimestampUs = seedTimestamps.length > 0 ? Math.min(nowUs, ...seedTimestamps) : nowUs;

    try {
      this.#ensureEntry(MARKER_CHANNEL, "string", "", baseTimestampUs);
      this.#ensureEntry(CONNECTED_CHANNEL, "boolean", "", baseTimestampUs);

      // Snapshot every topic the server has already announced so the log is
      // complete from t=0 rather than starting at the first change.
      for (const topic of knownTopics) {
        const channel = CHANNEL_PREFIX + topic.name;
        // A failing Start record means the WRITER is broken (bad disk, closed file), which
        // is fatal and must abort — so it stays outside the guard below.
        this.#ensureEntry(channel, topic.type, JSON.stringify(topic.properties ?? {}), baseTimestampUs);
        session.ntEntryCount += 1;

        const latest = this.latestValues.get(topic.name);
        // A topic can unannounce and re-announce with a DIFFERENT type while idle, leaving
        // a cached value that no longer matches the declared type. Trust the live announce
        // and drop the stale value rather than trying to encode it.
        if (latest !== undefined && latest.type !== topic.type) {
          // Say so in the log. Silently omitting a seed value is indistinguishable from a
          // topic that simply had no value yet, and an analyst would never know a sample
          // was discarded.
          session.skippedSeedTopics.push({
            name: topic.name,
            reason: `cached ${latest.type} does not match announced ${topic.type}`,
          });
        } else if (latest !== undefined) {
          try {
            // Seeded at session start: this is the value as of t0, not a new sample.
            this.#appendToEntry(channel, latest.value, baseTimestampUs);
          } catch (error) {
            // One unencodable cached value must not cost the whole recording — the live
            // stream is the point, and seeding is a nicety. But if the WRITER is what
            // failed, everything after this is doomed too, so let that propagate.
            if (session.writer.lastError) throw error;
            session.skippedSeedTopics.push({ name: topic.name, reason: errorMessage(error) });
          }
        }
      }

      if (session.skippedSeedTopics.length > 0) {
        this.#writeMarker(
          `seed skipped ${session.skippedSeedTopics.length} topic(s): ` +
            session.skippedSeedTopics.map((t) => t.name).join(", "),
          baseTimestampUs,
        );
      }

      this.#writeMarker(`session start ${id}`, baseTimestampUs);
      this.#appendToEntry(CONNECTED_CHANNEL, this.isConnected, baseTimestampUs);

      // When we seeded from cached values, that batch IS the start of the log and the
      // sidecar must say so — letting the first live frame set it instead reports a time
      // later than the file's own first record, and a consumer trusting it would clip the
      // whole snapshot. With nothing cached there is no server timestamp to claim yet, so
      // leave it for the first real frame.
      if (seedTimestamps.length > 0) {
        session.firstServerTimestampUs = baseTimestampUs;
      }
    } catch (error) {
      await this.#abortSession(session, error);
      throw error;
    }

    this.#startStatusTicker();
    this.#emitStatus(true);
    return this.#buildSummary(session, { endedAtIso: null, logBytes: this.#sessionBytes(session) });
  }

  async stop() {
    const session = this.session;
    if (!session || session.stopping) return null;

    session.stopping = true;
    this.#cancelAutoStop();
    this.#stopStatusTicker();
    // Broadcast isRecording=false FIRST: that status flip is the only signal the
    // renderer gets to stop its MediaRecorder, and MediaRecorder only emits its
    // trailing chunk (the one that closes the final webm cluster) on stop().
    this.#emitStatus(true);

    // ...then give those trailing chunks somewhere to land before the sink closes.
    await this.#awaitVideoTail(session);

    const endTimestampUs = this.#timestampUs();

    if (!session.failed) {
      try {
        this.#writeMarker("session stop", endTimestampUs);
      } catch (error) {
        this.lastError = errorMessage(error);
      }
    }

    await this.#teardownVideo(session, "session stop");

    if (!session.failed) {
      try {
        for (const entry of session.entries.values()) {
          session.writer.finishEntry(entry.entryId, endTimestampUs);
        }
      } catch (error) {
        this.lastError = errorMessage(error);
      }
    }

    // The writer must close and the sidecar must land even when the session
    // died on a disk error - that is the only record of what was captured.
    try {
      await session.writer.close();
    } catch (error) {
      this.lastError = errorMessage(error);
    }

    const endedAtIso = new Date().toISOString();
    const logBytes = await this.#statSize(session.logPath, this.#sessionBytes(session));
    const summary = this.#buildSummary(session, { endedAtIso, logBytes });

    try {
      await fsp.writeFile(session.sidecarPath, JSON.stringify(summary, null, 2), "utf8");
    } catch (error) {
      this.lastError = errorMessage(error);
    }

    this.session = null;
    this.#emitStatus(true);
    return summary;
  }

  async listSessions() {
    let names = [];
    try {
      names = await fsp.readdir(this.recordingsDir);
    } catch {
      return [];
    }

    const ids = new Set();
    for (const name of names) {
      const match = /^(.+)\.(?:wpilog|json)$/.exec(name);
      if (match && SESSION_ID_PATTERN.test(match[1])) ids.add(match[1]);
    }

    const summaries = [];
    for (const id of ids) {
      const summary = await this.#readSessionSummary(id);
      if (summary) summaries.push(summary);
    }

    summaries.sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
    return summaries;
  }

  async deleteSession(id) {
    this.#assertSessionId(id);
    if (this.session && this.session.id === id) {
      throw new Error("Cannot delete the session that is currently recording.");
    }

    for (const ext of [".wpilog", ".json", ".webm"]) {
      try {
        await fsp.unlink(path.join(this.recordingsDir, `${id}${ext}`));
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
    }
  }

  async revealSession(id) {
    this.#assertSessionId(id);
    const electron = loadElectron();
    if (!electron?.shell) {
      throw new Error("Revealing files requires the Electron shell.");
    }

    const logPath = path.join(this.recordingsDir, `${id}.wpilog`);
    const exists = await this.#statSize(logPath, null);
    electron.shell.showItemInFolder(exists === null ? this.recordingsDir : logPath);
  }

  async beginVideo({ deviceLabel = null, mimeType = null } = {}) {
    const session = this.session;
    if (!session || session.stopping) {
      throw new Error("Cannot record video while not recording.");
    }
    if (session.video && session.video.active) return;

    const sink = this.createVideoSink(session.videoPath);
    try {
      await sink.open();
    } catch (error) {
      this.lastError = `Video: ${errorMessage(error)}`;
      this.#emitStatus(true);
      throw error;
    }

    sink.on?.("error", (error) => {
      this.lastError = `Video: ${errorMessage(error)}`;
      void this.endVideo().catch(() => {});
    });

    // A re-open is a continuation of the same file, not a new video: the sink appends
    // and keeps its byte count, and the offset must still describe the FIRST frame.
    const previous = session.video;
    session.video = {
      sink,
      active: true,
      deviceLabel: deviceLabel ?? previous?.deviceLabel ?? null,
      mimeType: mimeType ?? previous?.mimeType ?? null,
      startOffsetMs: previous ? previous.startOffsetMs : Date.now() - session.startedAtMs,
      bytesWritten: sink.bytesWritten ?? 0,
    };

    this.#safeMarker(
      `${previous ? "video resume" : "video start"} ${deviceLabel ?? previous?.deviceLabel ?? "camera"}`,
    );
    this.#emitStatus(true);
  }

  async appendVideoChunk(chunk) {
    const video = this.session?.video;
    if (!video || !video.active || !video.sink) return;

    try {
      await video.sink.append(chunk);
      video.bytesWritten = video.sink.bytesWritten;
    } catch (error) {
      // A failed camera must not take the NT log down with it.
      this.lastError = `Video: ${errorMessage(error)}`;
      await this.endVideo();
    }
  }

  async endVideo() {
    const session = this.session;
    if (!session) return;
    await this.#teardownVideo(session, "video stop");
    this.#emitStatus(true);
  }

  async shutdown() {
    this.isShuttingDown = true;
    this.#cancelAutoStop();

    if (this.session) {
      try {
        await this.stop();
      } catch (error) {
        this.lastError = errorMessage(error);
      }
    }

    if (typeof this.settingsManager?.off === "function") {
      this.settingsManager.off("change", this.onSettingsChange);
    }

    this.#teardownClient();
    this.#stopStatusTicker();
    this.#clearStatusTrailing();
    this.removeAllListeners();
  }

  // ---------------------------------------------------------------- NT client

  #ensureClient() {
    const host = this.snapshot?.settings?.networkTables?.host?.trim() ?? "";
    const port = this.snapshot?.settings?.networkTables?.port ?? 5810;
    const nextKey = host ? `${host}:${port}` : "";

    this.host = host;
    this.port = port;

    if (!nextKey) {
      this.#teardownClient();
      this.#setConnected(false);
      return;
    }

    if (this.client && this.clientKey === nextKey) return;

    this.#teardownClient();
    this.clientKey = nextKey;

    const client = this.createClient({ host, port });
    this.client = client;

    client.on("open", () => this.#onClientOpen());
    client.on("close", (reason) => this.#onClientClose(reason));
    client.on("announce", (topic) => this.#onAnnounce(topic));
    client.on("unannounce", (topic) => this.#onUnannounce(topic));
    client.on("properties", (topic) => this.#onProperties(topic));
    client.on("value", (frame) => this.#onValue(frame));
    client.on("error", (error) => {
      // A robot that is off, rebooting or out of radio range makes the reconnect loop
      // emit ECONNREFUSED/ETIMEDOUT every second or so. That is not a recorder fault and
      // isConnected already says it, so it must not land in lastError — lastError is what
      // the UI shouts about, and reserving it for real failures (a full disk, a dead
      // volume) is the only way that warning stays worth reading.
      if (isConnectionError(error)) {
        this.#emitStatus(false);
        return;
      }
      this.lastError = errorMessage(error);
      this.#emitStatus(true);
    });

    client.connect();
  }

  #teardownClient() {
    const client = this.client;

    if (client) {
      try {
        client.removeAllListeners();
        client.close();
      } catch {
        // Ignore teardown failures; the socket is going away regardless.
      }

      // removeAllListeners() above guarantees the client's own 'close' event can never
      // reach #onClientClose, so the disconnect bookkeeping has to run by hand. Without
      // it the UI keeps showing NT CONNECTED against a host nothing is connected to.
      // Run it while this.client is still set so the marker is stamped in the OLD
      // server's clock domain, which is the domain the rest of the log is in.
      if (this.isConnected) this.#onClientClose("nt host changed");
    }

    this.client = null;
    this.clientKey = "";
    this.#setConnected(false);
    // Everything below came from the machine we just disconnected from: its topic list,
    // its cached values and its clock. Keeping any of it would let a START pressed before
    // the new client announces seed the session with another robot's data (and another
    // robot's timestamps).
    this.#resetServerState();
  }

  #resetServerState() {
    this.topics.clear();
    this.latestValues.clear();
    this.lastServerTimestampUs = 0;
    this.enabledSource = null;
    this.robotEnabled = false;
  }

  /** Do we have any basis for a server timestamp yet? */
  #clockKnown() {
    return this.#serverTimeOffsetUs() !== null || this.lastServerTimestampUs > 0;
  }

  #onClientOpen() {
    this.#setConnected(true);

    // At socket-open the clock estimate has just been reset and no sample has arrived, so
    // #timestampUs() has nothing to anchor to and would return 0. Stamping the connect
    // marker there puts a false "connected at t=0" record at the head of the log — worse
    // than the stale-epoch problem the reset fixed. Hold it until the first sample gives
    // us a real server timestamp.
    if (this.#clockKnown()) {
      this.#safeMarker("nt connected");
      this.#safeAppend(CONNECTED_CHANNEL, true);
      return;
    }
    this.pendingConnectedMarker = true;
  }

  /** Emit the deferred connect marker now that `timestampUs` is a real server time. */
  #flushPendingConnectedMarker(timestampUs) {
    if (!this.pendingConnectedMarker) return;
    this.pendingConnectedMarker = false;
    this.#writeMarker("nt connected", timestampUs);
    this.#appendToEntry(CONNECTED_CHANNEL, true, timestampUs);
  }

  /**
   * A topic's properties changed after it was announced. AdvantageKit does this for every
   * logged Measure — it publishes, then sets "unit" — so without this the units never
   * reach the log, and a unitless channel is a real problem for anyone fitting a model
   * against it later. WPILOG's SetMetadata record exists precisely for this.
   */
  #onProperties({ name, properties }) {
    if (typeof name !== "string") return;

    const known = this.topics.get(name);
    if (known) known.properties = properties ?? {};

    const session = this.session;
    if (!session || session.stopping || session.failed) return;

    const entry = session.entries.get(CHANNEL_PREFIX + name);
    if (!entry) return;

    const metadata = JSON.stringify(properties ?? {});
    if (metadata === entry.metadata) return;

    try {
      session.writer.setMetadata(entry.entryId, metadata, this.#timestampUs());
      entry.metadata = metadata;
    } catch (error) {
      this.#failSession(error);
    }
  }

  #onClientClose(reason) {
    // ws emits close after every refused reconnect, so a 60 s robot outage would otherwise
    // stamp ~20 identical "disconnected" markers. Only the real transition is news.
    const wasConnected = this.isConnected;
    if (wasConnected && this.session && !this.session.stopping) {
      this.session.hadConnectionLoss = true;
      this.#safeMarker(`nt disconnected${reason ? `: ${reason}` : ""}`);
      this.#safeAppend(CONNECTED_CHANNEL, false);
    }
    this.#setConnected(false);

    // Everything cached is tied to the server's uptime clock, and a robot that reboots
    // (or gets a redeploy between runs) comes back with that clock restarted near zero.
    // Holding on to pre-reboot values and the old high-water timestamp would anchor the
    // next session hundreds of seconds in the future and leave the log jumping backwards
    // mid-stream. The client re-announces everything on reconnect, so dropping it costs
    // nothing.
    this.latestValues.clear();
    this.lastServerTimestampUs = 0;
    this.pendingConnectedMarker = false;
  }

  #setConnected(connected) {
    if (this.isConnected === connected) return;
    this.isConnected = connected;
    this.#emitStatus(true);
  }

  #onAnnounce(topic) {
    if (!topic?.name) return;
    this.topics.set(topic.name, {
      name: topic.name,
      type: topic.type,
      properties: topic.properties ?? {},
    });
  }

  #onUnannounce(topic) {
    if (!topic?.name) return;
    // The topic map is keyed by name and deliberately survives an unannounce:
    // a reconnect must land back on the same entry id for the same channel.
    const known = this.topics.get(topic.name);
    if (known) known.announced = false;
  }

  #onValue(frame) {
    if (!frame || typeof frame.name !== "string") return;

    const timestampUs = Number.isFinite(frame.timestampUs) && frame.timestampUs > 0 ? frame.timestampUs : 0;
    if (timestampUs > this.lastServerTimestampUs) {
      this.lastServerTimestampUs = timestampUs;
    }

    this.latestValues.set(frame.name, {
      type: frame.type,
      value: frame.value,
      timestampUs,
    });
    if (!this.topics.has(frame.name)) {
      this.topics.set(frame.name, { name: frame.name, type: frame.type, properties: {} });
    }

    this.#writeValue(frame, timestampUs);
    this.#trackRobotEnabled(frame);
  }

  // ------------------------------------------------------------------ writing

  #writeValue(frame, timestampUs) {
    const session = this.session;
    if (!session || session.stopping || session.failed) return;

    const channel = CHANNEL_PREFIX + frame.name;
    // Substitute the previous timestamp when the server sends 0/absent so a
    // sample is never stamped at the epoch.
    const ts = timestampUs > 0 ? timestampUs : session.lastTimestampUs || this.#timestampUs();

    try {
      // This is the first server timestamp since the socket opened, so it is the earliest
      // honest time we can give the connect marker.
      this.#flushPendingConnectedMarker(ts);

      const known = this.topics.get(frame.name);
      const type = frame.type ?? known?.type;
      // Compare in WPILOG terms: entries store the mapped type, so comparing against the
      // raw NT type would report a spurious type change on every int sample.
      const wpilogType = typeof type === "string" && type.length > 0 ? ntTypeToWpilogType(type) : "raw";
      const existing = session.entries.get(channel);
      if (!existing) session.ntEntryCount += 1;
      if (!existing || existing.type !== wpilogType) {
        // Start must precede the first value for the channel; a mid-session
        // type change closes the old entry and opens a fresh one.
        if (existing) session.writer.finishEntry(existing.entryId, ts);
        this.#ensureEntry(channel, type, JSON.stringify(known?.properties ?? {}), ts, true);
      }

      this.#appendToEntry(channel, frame.value, ts);
      session.sampleCount += 1;
      if (session.firstServerTimestampUs === null) session.firstServerTimestampUs = ts;
      this.#recordRate(session);
    } catch (error) {
      this.#failSession(error);
    }
  }

  #ensureEntry(channel, type, metadata, timestampUs, replace = false) {
    const session = this.session;
    if (!session) return null;
    if (!replace && session.entries.has(channel)) return session.entries.get(channel);

    const resolvedType =
      typeof type === "string" && type.length > 0 ? ntTypeToWpilogType(type) : "raw";
    const entryId = session.writer.startEntry(channel, resolvedType, metadata ?? "", timestampUs);
    // Metadata is tracked so a later properties update can be diffed and turned into a
    // SetMetadata record instead of being written again unchanged.
    const entry = { entryId, type: resolvedType, metadata: metadata ?? "" };
    session.entries.set(channel, entry);
    return entry;
  }

  #appendToEntry(channel, value, timestampUs) {
    const session = this.session;
    const entry = session?.entries.get(channel);
    if (!entry) return;

    session.writer.appendValue(entry.entryId, entry.type, value, timestampUs);
    if (timestampUs > session.lastTimestampUs) session.lastTimestampUs = timestampUs;
  }

  #writeMarker(text, timestampUs = this.#timestampUs()) {
    this.#appendToEntry(MARKER_CHANNEL, text, timestampUs);
  }

  #safeMarker(text) {
    const session = this.session;
    if (!session || session.stopping || session.failed) return;
    try {
      this.#writeMarker(text);
    } catch (error) {
      this.#failSession(error);
    }
  }

  #safeAppend(channel, value) {
    const session = this.session;
    if (!session || session.stopping || session.failed) return;
    try {
      this.#appendToEntry(channel, value, this.#timestampUs());
    } catch (error) {
      this.#failSession(error);
    }
  }

  #failSession(error) {
    this.lastError = errorMessage(error);
    const session = this.session;
    if (!session || session.stopping) {
      this.#emitStatus(true);
      return;
    }

    session.failed = true;
    void this.stop().catch(() => {
      // stop() already funnels its own failures into lastError.
    });
  }

  async #abortSession(session, error) {
    this.lastError = errorMessage(error);
    session.stopping = true;
    session.failed = true;
    try {
      await session.writer.close();
    } catch {
      // Nothing more to do; the start already failed.
    }

    // writer.open() already created the .wpilog, so skipping the sidecar would leave an
    // orphan log with no <id>.json - a file the session browser cannot describe and the
    // operator cannot tell apart from a good recording.
    const endedAtIso = new Date().toISOString();
    const logBytes = await this.#statSize(session.logPath, this.#sessionBytes(session));
    try {
      const summary = {
        ...this.#buildSummary(session, { endedAtIso, logBytes }),
        aborted: true,
        error: this.lastError,
      };
      await fsp.writeFile(session.sidecarPath, JSON.stringify(summary, null, 2), "utf8");
    } catch {
      // Best effort: the start failure is already reported through lastError.
    }

    this.session = null;
    this.#stopStatusTicker();
    this.#emitStatus(true);
  }

  // -------------------------------------------------------------------- video

  /**
   * Wait (bounded) for the renderer to flush MediaRecorder's tail and call endVideo().
   * Closing the sink before that happens throws away the final chunk(s) and leaves the
   * .webm without its last cluster, which some players reject outright. The renderer is
   * untrusted here - it may be backgrounded, wedged or already destroyed - so the wait
   * always expires and stop() carries on regardless.
   */
  async #awaitVideoTail(session) {
    const video = session.video;
    if (!video || !video.active) return;

    const deadline = Date.now() + Math.max(0, this.videoTailTimeoutMs);
    // Deliberately NOT unref'd: this is a bounded wait that stop() is blocked on, and an
    // unref'd timer would let the process exit out from under an in-flight stop().
    while (session.video && session.video.active && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, VIDEO_TAIL_POLL_MS));
    }

    if (session.video && session.video.active) {
      this.lastError = "Video: renderer did not stop in time; the last chunk may be missing.";
    }
  }

  async #teardownVideo(session, markerText) {
    const video = session.video;
    if (!video || !video.active) return;

    video.active = false;
    try {
      await video.sink.close();
      video.bytesWritten = video.sink.bytesWritten;
    } catch (error) {
      this.lastError = `Video: ${errorMessage(error)}`;
    }
    video.sink = null;

    if (!session.failed) {
      try {
        this.#writeMarker(markerText);
      } catch (error) {
        this.lastError = errorMessage(error);
      }
    }
  }

  #videoStatus(session) {
    const video = session.video;
    return {
      active: video.active,
      deviceLabel: video.deviceLabel,
      bytesWritten: video.bytesWritten,
    };
  }

  // -------------------------------------------------------------- auto-record

  #trackRobotEnabled(frame) {
    let enabled = null;
    let source = null;

    if (frame.name === ENABLED_TOPIC) {
      enabled = Boolean(frame.value);
      source = "advantagekit";
    } else if (frame.name === FMS_CONTROL_TOPIC) {
      enabled = (Number(frame.value) & 1) === 1;
      source = "fms";
    } else if (frame.name === SIM_RUNNING_TOPIC) {
      // Simulator-only fallback (see SIM_RUNNING_TOPIC): PWRDrive publishes this and
      // nothing else, so it is the only way to exercise auto-record off-robot.
      enabled = Boolean(frame.value);
      source = "simulator";
    }

    if (enabled === null) return;

    // A lower-ranked signal never overrides a higher-ranked one that has already spoken.
    const currentRank = ENABLED_SOURCE_RANK[this.enabledSource] ?? 0;
    if (ENABLED_SOURCE_RANK[source] < currentRank) return;
    this.enabledSource = source;

    if (enabled === this.robotEnabled) return;

    this.robotEnabled = enabled;

    if (enabled) {
      this.#cancelAutoStop();
      if (this.autoRecord && !this.session && !this.isShuttingDown) {
        void this.start({ autoStarted: true }).catch((error) => {
          this.lastError = errorMessage(error);
          this.#emitStatus(true);
        });
      }
    } else if (this.autoRecord && this.session && !this.session.stopping) {
      this.#scheduleAutoStop();
    }

    this.#emitStatus(true);
  }

  #scheduleAutoStop() {
    this.#cancelAutoStop();
    this.autoStopHandle = setTimeout(() => {
      this.autoStopHandle = null;
      if (this.robotEnabled || !this.session) return;
      void this.stop().catch((error) => {
        this.lastError = errorMessage(error);
        this.#emitStatus(true);
      });
    }, this.autoStopGraceMs);
    this.autoStopHandle.unref?.();
  }

  #cancelAutoStop() {
    if (this.autoStopHandle) {
      clearTimeout(this.autoStopHandle);
      this.autoStopHandle = null;
    }
  }

  // ------------------------------------------------------------------- status

  #startStatusTicker() {
    this.#stopStatusTicker();
    this.statusTickHandle = setInterval(() => this.#onStatusTick(), STATUS_INTERVAL_MS);
    this.statusTickHandle.unref?.();
  }

  #onStatusTick() {
    this.#checkWriterHealth();
    void this.#flushWriter();
    this.#emitStatus(false);
  }

  /**
   * The writer buffers and writes asynchronously, so a full disk or an unmounted volume
   * surfaces as a stream error long after the appendValue() that caused it returned
   * cleanly. Nothing polls it for us: without this the UI would keep showing "recording"
   * while every byte goes nowhere.
   */
  #checkWriterHealth() {
    const session = this.session;
    if (!session || session.stopping || session.failed) return;

    const error = session.writer?.lastError;
    if (error) {
      this.#failSession(new Error(`Log write failed: ${errorMessage(error)}`));
    }
  }

  async #flushWriter() {
    const session = this.session;
    if (!session || session.stopping || session.failed) return;
    if (typeof session.writer?.flush !== "function") return;

    // Scoped to the session, not the recorder: a device that never completes a write
    // leaves this flush pending forever, and an instance-wide latch would then silently
    // disable the flush loop for every LATER session in the process.
    if (session.flushInFlight) {
      // A flush that never settles means the volume is hung (a yanked USB stick, a
      // network share that stopped answering). It never errors, so nothing else notices
      // until the backlog ceiling blows much later. Call it early and loudly.
      if (Date.now() - session.flushStartedAtMs >= FLUSH_STALL_TIMEOUT_MS) {
        this.#failSession(
          new Error(
            `Log write stalled: the recordings volume stopped responding for ` +
              `${Math.round(FLUSH_STALL_TIMEOUT_MS / 1000)}s.`,
          ),
        );
      }
      return;
    }

    session.flushInFlight = true;
    session.flushStartedAtMs = Date.now();
    try {
      // flush() rethrows any stream error it has latched, so this is both a
      // durability measure and a second disk-failure detector.
      await session.writer.flush();
    } catch (error) {
      if (this.session === session && !session.stopping && !session.failed) {
        this.#failSession(new Error(`Log write failed: ${errorMessage(error)}`));
      }
    } finally {
      session.flushInFlight = false;
    }
  }

  #writerBacklogBytes(session) {
    const writer = session.writer;
    if (!writer) return 0;
    const backlog = writer.backlogBytes ?? writer.pendingBytes;
    return typeof backlog === "number" && Number.isFinite(backlog) ? backlog : 0;
  }

  #stopStatusTicker() {
    if (this.statusTickHandle) {
      clearInterval(this.statusTickHandle);
      this.statusTickHandle = null;
    }
  }

  #clearStatusTrailing() {
    if (this.statusTrailingHandle) {
      clearTimeout(this.statusTrailingHandle);
      this.statusTrailingHandle = null;
    }
  }

  #emitStatus(immediate) {
    if (immediate) {
      this.#clearStatusTrailing();
      this.lastStatusEmitMs = Date.now();
      this.emit("status", this.getStatus());
      return;
    }

    const now = Date.now();
    const sinceMs = now - this.lastStatusEmitMs;
    if (sinceMs >= STATUS_INTERVAL_MS) {
      this.#clearStatusTrailing();
      this.lastStatusEmitMs = now;
      this.emit("status", this.getStatus());
      return;
    }

    if (this.statusTrailingHandle) return;
    this.statusTrailingHandle = setTimeout(() => {
      this.statusTrailingHandle = null;
      this.lastStatusEmitMs = Date.now();
      this.emit("status", this.getStatus());
    }, STATUS_INTERVAL_MS - sinceMs);
    this.statusTrailingHandle.unref?.();
  }

  #recordRate(session) {
    const bucket = Math.floor(Date.now() / RATE_BUCKET_MS);
    const last = session.rateBuckets[session.rateBuckets.length - 1];
    if (last && last.bucket === bucket) {
      last.count += 1;
    } else {
      session.rateBuckets.push({ bucket, count: 1 });
    }

    const oldest = bucket - RATE_BUCKET_COUNT + 1;
    while (session.rateBuckets.length > 0 && session.rateBuckets[0].bucket < oldest) {
      session.rateBuckets.shift();
    }
  }

  /**
   * Samples per second over a sliding window.
   *
   * The subtlety that makes this wrong if you rush it: the newest bucket is always
   * PARTIAL. Summing N buckets and dividing by a fixed N*RATE_BUCKET_MS reads high or low
   * depending on which end you get wrong, and either way sawtooths by a full bucket's
   * worth (12%) while the true rate is dead steady — which an operator reads as the
   * recorder losing samples. So divide by the time the retained buckets ACTUALLY cover:
   * from the oldest retained bucket's start to now.
   */
  #samplesPerSecond(session) {
    const nowMs = Date.now();
    const bucket = Math.floor(nowMs / RATE_BUCKET_MS);
    const oldest = bucket - RATE_BUCKET_COUNT + 1;

    let total = 0;
    for (const item of session.rateBuckets) {
      if (item.bucket >= oldest) total += item.count;
    }
    if (total === 0) return 0;

    // Never credit samples to time before the session began, or a run shorter than the
    // window reads low.
    const windowStartMs = Math.max(oldest * RATE_BUCKET_MS, session.startedAtMs);
    const elapsedMs = nowMs - windowStartMs;
    if (elapsedMs <= 0) return 0;
    return Math.round((total * 1000) / elapsedMs);
  }

  // -------------------------------------------------------------------- utils

  #topicCount() {
    if (typeof this.client?.topicCount === "number") return this.client.topicCount;
    return this.topics.size;
  }

  #knownTopics() {
    const fromClient = this.client?.getAnnouncedTopics?.();
    if (Array.isArray(fromClient) && fromClient.length > 0) {
      const merged = new Map();
      for (const topic of fromClient) {
        if (topic?.name) merged.set(topic.name, topic);
      }
      return [...merged.values()];
    }
    return [...this.topics.values()];
  }

  /**
   * Every timestamp in the log MUST be in the NT server's clock domain - server uptime
   * microseconds, the domain value frames arrive in. Records we generate ourselves
   * (Start records, markers, the connected channel, finish records) are triggered by
   * local events, so local time has to be translated, never used raw. Date.now() * 1000
   * is epoch microseconds; mixing it in puts our own records ~55 years away from the
   * first real sample and makes the log unplottable.
   *
   * Module B derives serverTimeOffsetUs from the NT 4.0 RTT heartbeat exactly for this:
   *   serverTimeUs ~= localNowUs - serverTimeOffsetUs
   *
   * When nothing has ever connected there is no offset and no server clock to place
   * anything on, so those records are stamped at 0 - the origin of the server's uptime
   * domain, which is before any sample the server can ever send. That keeps a
   * start-then-connect recording (the headline "arm it and let auto-record fire" case)
   * in one domain and monotonic, at the cost of collapsing pre-connection records onto
   * t=0. It is never the epoch.
   */
  #timestampUs() {
    const offsetUs = this.#serverTimeOffsetUs();
    if (offsetUs !== null) {
      const serverUs = Math.round(this.#localNowUs() - offsetUs);
      // Clamp so RTT jitter can never emit a timestamp behind a sample already written.
      return Math.max(serverUs > 0 ? serverUs : 0, this.lastServerTimestampUs);
    }
    if (this.lastServerTimestampUs > 0) return this.lastServerTimestampUs;
    return 0;
  }

  #serverTimeOffsetUs() {
    const stats = this.client?.getStats?.();
    if (!stats) return null;
    // bestRttUs stays -1 until the first RTT round-trip completes; until then
    // serverTimeOffsetUs is a meaningless 0 and "converting" with it would hand back
    // raw epoch microseconds - the exact bug this exists to prevent.
    if (!(Number(stats.bestRttUs) >= 0)) return null;
    const offset = Number(stats.serverTimeOffsetUs);
    return Number.isFinite(offset) ? offset : null;
  }

  #localNowUs() {
    // Same clock module B samples the RTT with, so the offset subtracts cleanly.
    if (typeof performance === "object" && performance && typeof performance.now === "function") {
      return performance.timeOrigin * 1000 + performance.now() * 1000;
    }
    return Date.now() * 1000;
  }

  #sessionBytes(session) {
    const bytes = session.writer?.bytesWritten;
    return typeof bytes === "number" ? bytes : 0;
  }

  #allocateSessionId(date) {
    const base = formatSessionId(date);
    const taken = (id) =>
      [".wpilog", ".json", ".webm"].some((ext) =>
        fs.existsSync(path.join(this.recordingsDir, `${id}${ext}`)),
      );

    let id = base;
    let suffix = 2;
    // Every extension counts, not just .wpilog: the video sink only ever appends (so it
    // can survive a renderer remount without truncating), which means a session must
    // never be handed a path that already has bytes at it.
    while (taken(id)) {
      id = `${base}-${suffix}`;
      suffix += 1;
    }
    return id;
  }

  #assertSessionId(id) {
    if (typeof id !== "string" || !SESSION_ID_PATTERN.test(id)) {
      throw new Error(`Invalid session id: ${String(id)}`);
    }
  }

  async #statSize(filePath, fallback) {
    try {
      const stat = await fsp.stat(filePath);
      return stat.size;
    } catch {
      return fallback;
    }
  }

  #buildSummary(session, { endedAtIso, logBytes }) {
    const video = session.video;
    return {
      id: session.id,
      logPath: session.logPath,
      logBytes,
      videoPath: video ? session.videoPath : null,
      videoBytes: video ? video.bytesWritten : null,
      videoStartOffsetMs: video ? video.startOffsetMs : null,
      startedAtIso: session.startedAtIso,
      endedAtIso,
      durationMs: (endedAtIso ? new Date(endedAtIso).getTime() : Date.now()) - session.startedAtMs,
      topicCount: session.ntEntryCount,
      sampleCount: session.sampleCount,
      host: this.host,
      port: this.port,
      hadConnectionLoss: session.hadConnectionLoss,
      autoStarted: session.autoStarted,
      note: session.note,
      firstServerTimestampUs: session.firstServerTimestampUs,
      lastServerTimestampUs: session.lastTimestampUs || null,
    };
  }

  async #readSessionSummary(id) {
    const logPath = path.join(this.recordingsDir, `${id}.wpilog`);
    const sidecarPath = path.join(this.recordingsDir, `${id}.json`);

    let parsed = null;
    try {
      parsed = JSON.parse(await fsp.readFile(sidecarPath, "utf8"));
    } catch {
      parsed = null;
    }

    const logBytes = await this.#statSize(logPath, null);
    if (!parsed && logBytes === null) return null;

    if (!parsed) {
      // A log with no sidecar means the app died mid-session; still list it.
      return {
        id,
        logPath,
        logBytes,
        videoPath: null,
        videoBytes: null,
        videoStartOffsetMs: null,
        startedAtIso: (await this.#statMtimeIso(logPath)) ?? new Date(0).toISOString(),
        endedAtIso: null,
        durationMs: 0,
        topicCount: 0,
        sampleCount: 0,
        host: "",
        port: 0,
        hadConnectionLoss: false,
        autoStarted: false,
        note: null,
        incomplete: true,
      };
    }

    const videoBytes = parsed.videoPath ? await this.#statSize(parsed.videoPath, parsed.videoBytes ?? null) : null;
    return {
      ...parsed,
      id,
      logPath,
      logBytes: logBytes ?? parsed.logBytes ?? 0,
      videoPath: videoBytes === null ? null : parsed.videoPath,
      videoBytes,
    };
  }

  async #statMtimeIso(filePath) {
    try {
      const stat = await fsp.stat(filePath);
      return stat.mtime.toISOString();
    } catch {
      return null;
    }
  }
}

module.exports = {
  NtRecorder,
  AUTO_STOP_GRACE_MS,
  MARKER_CHANNEL,
  CONNECTED_CHANNEL,
  CHANNEL_PREFIX,
};
