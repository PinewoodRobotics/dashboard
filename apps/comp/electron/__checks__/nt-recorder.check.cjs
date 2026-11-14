/**
 * Drives NtRecorder end-to-end against stub module A (wpilog writer) and
 * module B (NT4 client) implementations, so the orchestration logic can be
 * verified without Electron, a robot, or the real writer.
 *
 *   node electron/__checks__/nt-recorder.check.cjs
 */
const os = require("os");
const path = require("path");
const assert = require("assert");
const { promises: fsp } = require("fs");
const { EventEmitter } = require("events");
const { NtRecorder, MARKER_CHANNEL, CONNECTED_CHANNEL } = require("../nt-recorder.cjs");

const GRACE_MS = 120;
const VIDEO_TAIL_MS = 200;
const STATUS_TICK_MS = 250;
const ENABLED_TOPIC = "/AdvantageKit/DriverStation/Enabled";
const SIM_RUNNING_TOPIC = "/AdvantageKit/RealOutputs/MatchStatus/Running";
// Anything at or above this is epoch microseconds, i.e. the wrong clock domain.
// NT server timestamps are uptime microseconds and stay far below it.
const EPOCH_US_SENTINEL = 1e12;

/** The clock module B samples the RTT with, so offsets subtract cleanly. */
function localNowUs() {
  return performance.timeOrigin * 1000 + performance.now() * 1000;
}

// ------------------------------------------------------------------- stubs

class StubWriter {
  constructor(filePath, extraHeader) {
    this.filePath = filePath;
    this.extraHeader = extraHeader;
    this.records = []; // { kind, entryId, name, type, value, timestampUs }
    this.entries = new Map();
    this.nextEntryId = 1;
    this.closed = false;
    this.opened = false;
    this.bytes = 0;
    this.failOnChannel = null;
    this.failStartOnChannel = null;
    // Module A latches async stream errors here instead of throwing them at the event
    // loop; the recorder has to poll it or a dead disk goes unnoticed.
    this.lastError = null;
    this.pendingBytes = 0;
  }

  get bytesWritten() {
    return this.bytes;
  }
  get entryCount() {
    return this.entries.size;
  }
  get recordCount() {
    return this.records.length;
  }

  async open() {
    this.opened = true;
    await fsp.mkdir(path.dirname(this.filePath), { recursive: true });
    await fsp.writeFile(this.filePath, "WPILOG-stub");
    this.bytes = 11;
  }

  /**
   * Simulate the volume going away mid-session: the write stream errors
   * asynchronously and the writer latches it, while synchronous appendValue calls
   * keep returning normally. Only polling can catch this.
   */
  breakStream(error) {
    this.lastError = error;
  }

  startEntry(name, type, metadata, timestampUs) {
    assert.ok(this.opened, "startEntry before open");
    assert.ok(!this.closed, "startEntry after close");
    if (this.failStartOnChannel && name === this.failStartOnChannel) {
      throw new Error("ENOSPC: simulated start failure");
    }
    const entryId = this.nextEntryId++;
    this.entries.set(entryId, { name, type });
    this.records.push({ kind: "start", entryId, name, type, metadata, timestampUs });
    this.bytes += 32 + name.length;
    return entryId;
  }

  finishEntry(entryId, timestampUs) {
    this.records.push({ kind: "finish", entryId, timestampUs });
  }

  setMetadata(entryId, metadata, timestampUs) {
    this.records.push({ kind: "metadata", entryId, metadata, timestampUs });
  }

  appendValue(entryId, type, value, timestampUs) {
    assert.ok(!this.closed, "appendValue after close");
    const entry = this.entries.get(entryId);
    assert.ok(entry, `appendValue for unknown entry ${entryId}`);
    if (this.failOnChannel && entry.name === this.failOnChannel) {
      throw new Error("ENOSPC: simulated disk full");
    }
    this.records.push({ kind: "value", entryId, name: entry.name, type, value, timestampUs });
    this.bytes += 16;
  }

  async flush() {
    if (this.lastError) throw this.lastError;
  }

  async close() {
    this.closed = true;
  }
}

class StubClient extends EventEmitter {
  constructor({ host, port }) {
    super();
    this.host = host;
    this.port = port;
    this.connected = false;
    this.closed = false;
    this.topics = new Map(); // id -> {name, type, properties}
    // Module B leaves these untouched until the first NT 4.0 RTT round-trip completes;
    // bestRttUs === -1 is how "the server clock is still unknown" is expressed.
    this.bestRttUs = -1;
    this.serverTimeOffsetUs = 0;
    StubClient.instances.push(this);
  }

  getStats() {
    return {
      valueCount: 0,
      droppedValueCount: 0,
      typeMismatchCount: 0,
      decodeErrorCount: 0,
      bestRttUs: this.bestRttUs,
      serverTimeOffsetUs: this.serverTimeOffsetUs,
    };
  }

  connect() {
    this.connectCalls = (this.connectCalls ?? 0) + 1;
  }

  close() {
    this.closed = true;
    this.connected = false;
  }

  get topicCount() {
    return this.topics.size;
  }

  getAnnouncedTopics() {
    return [...this.topics.values()].map((t) => ({ ...t }));
  }

  // --- test drivers -------------------------------------------------------

  open() {
    this.connected = true;
    this.emit("open");
  }

  drop(reason = "socket closed") {
    this.connected = false;
    this.topics.clear();
    this.emit("close", reason);
  }

  /** Pretend the RTT heartbeat settled with the server `serverUptimeUs` into its own uptime. */
  syncClock(serverUptimeUs, rttUs = 2000) {
    this.bestRttUs = rttUs;
    this.serverTimeOffsetUs = localNowUs() - serverUptimeUs;
  }

  announce(id, name, type, properties = {}) {
    this.topics.set(id, { id, name, type, properties });
    this.emit("announce", { id, name, type, properties });
  }

  value(id, value, timestampUs) {
    const topic = this.topics.get(id);
    assert.ok(topic, `value for unannounced topic id ${id}`);
    this.emit("value", { id, name: topic.name, type: topic.type, timestampUs, value });
  }
}
StubClient.instances = [];

const settingsManager = {
  snapshot: {
    settings: { networkTables: { host: "127.0.0.1", port: 5810 } },
  },
  getSnapshot() {
    return this.snapshot;
  },
  on() {},
  off() {},
};

// -------------------------------------------------------------------- helpers

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function currentClient() {
  return StubClient.instances[StubClient.instances.length - 1];
}

function writerFor(recorder) {
  return recorder.session?.writer ?? lastWriter;
}

let lastWriter = null;

function assertStartBeforeValue(records) {
  const started = new Set();
  for (const record of records) {
    if (record.kind === "start") {
      started.add(record.entryId);
    } else if (record.kind === "value") {
      assert.ok(started.has(record.entryId), `value for entry ${record.entryId} before its Start record`);
    }
  }
}

const checks = [];
function check(label, fn) {
  fn();
  checks.push({ label });
}

/**
 * A fresh recorder on its own temp dir with its own settings, for the regression
 * cases below - they need to drive host changes, clock states and start-before-connect
 * without disturbing the long-lived recorder above.
 *
 * The real VideoSink is used on purpose: the truncation regression is only meaningful
 * against the actual file it opens.
 */
async function newRig({ host = "127.0.0.1", port = 5810, writerHook = null, ...overrides } = {}) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "pwrup-recorder-rig-"));
  const settings = {
    snapshot: { settings: { networkTables: { host, port } } },
    getSnapshot() {
      return this.snapshot;
    },
    on() {},
    off() {},
  };
  const writers = [];
  const recorder = new NtRecorder({
    settingsManager: settings,
    recordingsDir: dir,
    autoStopGraceMs: GRACE_MS,
    videoTailTimeoutMs: VIDEO_TAIL_MS,
    createClient: (opts) => new StubClient(opts),
    createWriter: (filePath, extraHeader) => {
      const writer = new StubWriter(filePath, extraHeader);
      writers.push(writer);
      writerHook?.(writer);
      return writer;
    },
    ...overrides,
  });

  const dispose = async () => {
    await recorder.shutdown();
    await fsp.rm(dir, { recursive: true, force: true });
  };

  return { dir, settings, recorder, writers, dispose };
}

function timestampsOf(writer) {
  return writer.records.map((r) => r.timestampUs);
}

function markersOf(writer) {
  return writer.records.filter((r) => r.name === MARKER_CHANNEL && r.kind === "value");
}

// ---------------------------------------------------------------------- tests

async function main() {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "pwrup-recorder-check-"));

  const recorder = new NtRecorder({
    settingsManager,
    recordingsDir: dir,
    autoStopGraceMs: GRACE_MS,
    videoTailTimeoutMs: VIDEO_TAIL_MS,
    createClient: (opts) => new StubClient(opts),
    createWriter: (filePath, extraHeader) => {
      lastWriter = new StubWriter(filePath, extraHeader);
      return lastWriter;
    },
  });

  const statuses = [];
  recorder.on("status", (status) => statuses.push({ at: Date.now(), status }));

  // -- 1. initialize keeps a client connected while idle ---------------------
  recorder.initialize();
  const client = currentClient();
  assert.ok(client, "client created on initialize");
  assert.strictEqual(client.connectCalls, 1, "connect called once");
  assert.strictEqual(recorder.getStatus().isRecording, false);

  client.open();
  client.announce(1, "/Swerve/Pose", "struct:Pose2d", { retained: true });
  client.announce(2, "/Swerve/Speed", "double");
  client.announce(3, ENABLED_TOPIC, "boolean");
  client.value(1, new Uint8Array([1, 2, 3]), 1_000_000);
  client.value(2, 3.5, 1_000_100);

  assert.strictEqual(recorder.getStatus().isConnected, true, "connected while idle");
  assert.strictEqual(recorder.getStatus().sampleCount, 0, "idle values are not written");
  check("idle client stays connected and caches values", () => {});

  // -- 2. start seeds every announced topic ---------------------------------
  const startSummary = await recorder.start({ note: "  calibration run  " });
  const writer = writerFor(recorder);
  assert.strictEqual(startSummary.note, "calibration run", "note trimmed");
  assert.strictEqual(recorder.getStatus().isRecording, true);
  assert.ok(JSON.parse(writer.extraHeader).sessionId === startSummary.id, "extra header carries session id");
  assert.strictEqual(JSON.parse(writer.extraHeader).kind, "nt-client-recording");

  const startedChannels = writer.records.filter((r) => r.kind === "start").map((r) => r.name);
  assert.ok(startedChannels.includes("NT:/Swerve/Pose"), "NT: prefixed channel");
  assert.ok(startedChannels.includes(MARKER_CHANNEL), "marker channel");
  assert.ok(startedChannels.includes(CONNECTED_CHANNEL), "connected channel");
  const seeded = writer.records.filter((r) => r.kind === "value" && r.name === "NT:/Swerve/Speed");
  assert.strictEqual(seeded.length, 1, "seeded the cached value at session start");
  assert.strictEqual(seeded[0].value, 3.5);
  const markers = writer.records.filter((r) => r.name === MARKER_CHANNEL && r.kind === "value");
  assert.ok(markers[0].value.startsWith("session start"), "session start marker");
  check("start seeds announced topics, markers, Start-before-value", () =>
    assertStartBeforeValue(writer.records),
  );

  await assert.rejects(() => recorder.start(), /already in progress/, "double start rejects");

  // -- 3. streaming ---------------------------------------------------------
  client.value(2, 4.5, 1_100_000);
  client.value(2, 5.5, 1_200_000);
  assert.strictEqual(recorder.getStatus().sampleCount, 2);
  assert.ok(recorder.getStatus().samplesPerSecond >= 0);

  // a zero timestamp falls back to the previous one rather than the epoch
  client.value(2, 6.5, 0);
  const zeroTs = writer.records.filter((r) => r.name === "NT:/Swerve/Speed").pop();
  assert.ok(zeroTs.timestampUs > 0, "zero timestamp substituted");
  check("streaming values written with server timestamps", () => {});

  // -- 4. reconnect keeps one entry per topic name --------------------------
  const poseEntryId = writer.records.find((r) => r.kind === "start" && r.name === "NT:/Swerve/Pose").entryId;
  client.drop("network down");
  assert.strictEqual(recorder.getStatus().isConnected, false);
  assert.strictEqual(recorder.getStatus().hadConnectionLoss, true, "connection loss recorded");

  client.open();
  // server reassigns ids on reconnect
  client.announce(77, "/Swerve/Pose", "struct:Pose2d", { retained: true });
  client.announce(79, "/Swerve/Speed", "double");
  client.announce(80, ENABLED_TOPIC, "boolean");
  client.value(77, new Uint8Array([9]), 2_000_000);
  const poseValues = writer.records.filter((r) => r.kind === "value" && r.name === "NT:/Swerve/Pose");
  assert.strictEqual(
    poseValues[poseValues.length - 1].entryId,
    poseEntryId,
    "reconnect reuses the entry id for the same topic name",
  );
  const startCount = writer.records.filter((r) => r.kind === "start" && r.name === "NT:/Swerve/Pose").length;
  assert.strictEqual(startCount, 1, "no duplicate Start record after reconnect");
  check("mid-session reconnect keeps one channel per topic name", () => {});

  // -- 5. a brand-new topic gets its entry lazily ---------------------------
  // NT4 announces integers as "int"/"int[]" — the wire vocabulary, NOT the WPILOG one. Using
  // WPILOG spellings here would hide the fact that the recorder has to translate them.
  client.announce(78, "/Vision/Tags", "int[]");
  client.value(78, [1, 2, 3], 2_100_000);
  const tagRecords = writer.records.filter((r) => r.name === "NT:/Vision/Tags");
  assert.strictEqual(tagRecords[0].kind, "start", "Start precedes the first value for a new topic");
  assert.strictEqual(tagRecords[0].type, "int64[]", 'NT "int[]" is logged as WPILOG "int64[]"');
  assert.strictEqual(tagRecords[1].kind, "value");
  check("new mid-session topic creates its entry lazily", () => {});

  // -- 5b. scalar ints map too, and do not thrash their entry ---------------
  client.announce(81, "/Match/Points", "int");
  client.value(81, 12, 2_110_000);
  client.value(81, 13, 2_120_000);
  client.value(81, 14, 2_130_000);
  const pointRecords = writer.records.filter((r) => r.name === "NT:/Match/Points");
  assert.strictEqual(pointRecords[0].kind, "start");
  assert.strictEqual(pointRecords[0].type, "int64", 'NT "int" is logged as WPILOG "int64"');
  assert.strictEqual(
    pointRecords.filter((r) => r.kind === "start").length,
    1,
    "mapped type must not read as a type change on every sample",
  );
  assert.strictEqual(pointRecords.filter((r) => r.kind === "value").length, 3);
  check("NT int types are translated to WPILOG int64 without entry thrash", () => {});

  // -- 6. video sink --------------------------------------------------------
  await recorder.beginVideo({ deviceLabel: "Field Cam", mimeType: "video/webm;codecs=vp9" });
  await recorder.appendVideoChunk(new Uint8Array([1, 2, 3, 4]));
  await recorder.appendVideoChunk(new Uint8Array([5, 6]));
  const videoStatus = recorder.getStatus().video;
  assert.strictEqual(videoStatus.active, true);
  assert.strictEqual(videoStatus.deviceLabel, "Field Cam");
  assert.strictEqual(videoStatus.bytesWritten, 6);
  check("video sink appends chunks and reports bytes", () => {});

  // -- 7. stop writes the sidecar and closes the writer ---------------------
  const summary = await recorder.stop();
  assert.strictEqual(writer.closed, true, "writer closed on stop");
  assert.strictEqual(recorder.getStatus().isRecording, false);
  assert.strictEqual(summary.hadConnectionLoss, true);
  assert.strictEqual(summary.videoBytes, 6);
  assert.ok(summary.videoStartOffsetMs !== null);
  assert.ok(summary.endedAtIso, "endedAtIso set");
  assert.ok(summary.firstServerTimestampUs > 0, "first server timestamp recorded in sidecar");
  const sidecar = JSON.parse(await fsp.readFile(path.join(dir, `${summary.id}.json`), "utf8"));
  assert.strictEqual(sidecar.id, summary.id);
  const videoStat = await fsp.stat(path.join(dir, `${summary.id}.webm`));
  assert.strictEqual(videoStat.size, 6, "webm bytes hit disk");
  assert.strictEqual(await recorder.stop(), null, "stop is no-op safe");
  check("stop closes the writer and writes the sidecar", () => {});

  // -- 8. auto-record on enable --------------------------------------------
  recorder.setAutoRecord(true);
  assert.strictEqual(recorder.getStatus().autoRecord, true);

  client.value(80, true, 3_000_000);
  await sleep(20);
  const autoStatus = recorder.getStatus();
  assert.strictEqual(autoStatus.isRecording, true, "auto-record started on enable");
  assert.strictEqual(autoStatus.robotEnabled, true);
  assert.strictEqual(recorder.session.autoStarted, true, "autoStarted flag set");

  // disable, then re-enable inside the grace window: the stop must be cancelled
  client.value(80, false, 3_100_000);
  await sleep(GRACE_MS / 2);
  client.value(80, true, 3_150_000);
  await sleep(GRACE_MS * 1.5);
  assert.strictEqual(recorder.getStatus().isRecording, true, "re-enable cancels the pending auto-stop");

  // disable for real
  client.value(80, false, 3_200_000);
  await sleep(GRACE_MS * 2 + 60);
  const autoSummary = await recorder.listSessions();
  assert.strictEqual(recorder.getStatus().isRecording, false, "auto-stop fired after the grace period");
  assert.strictEqual(autoSummary[0].autoStarted, true, "auto session recorded as autoStarted");
  check("auto-record starts on enable and auto-stops after a cancellable grace", () => {});

  // -- 9. status throttling -------------------------------------------------
  statuses.length = 0;
  await recorder.start();
  const transitionCount = statuses.length;
  assert.strictEqual(transitionCount >= 1, true, "start emits status immediately");
  const afterStart = Date.now();
  const streamWriter = writerFor(recorder);
  for (let i = 0; i < 500; i += 1) {
    client.value(79, i, 4_000_000 + i * 1000);
  }
  assert.strictEqual(statuses.length, transitionCount, "value floods do not emit status");
  await sleep(1000);
  const emittedWhileRecording = statuses.filter((s) => s.at > afterStart).length;
  assert.ok(emittedWhileRecording <= 7, `status throttled to ~4 Hz (saw ${emittedWhileRecording})`);
  assert.ok(emittedWhileRecording >= 2, `status still ticks while recording (saw ${emittedWhileRecording})`);
  check("status is throttled to ~4 Hz but immediate on transitions", () => {});

  // -- 10. disk failure stops recording without crashing --------------------
  statuses.length = 0;
  streamWriter.failOnChannel = "NT:/Swerve/Speed";
  client.value(79, 99, 5_000_000);
  await sleep(50);
  const failed = recorder.getStatus();
  assert.strictEqual(failed.isRecording, false, "disk failure stops recording");
  assert.ok(/ENOSPC/.test(failed.lastError ?? ""), `lastError surfaced (${failed.lastError})`);
  assert.strictEqual(streamWriter.closed, true, "writer closed on the error path");
  const sessions = await recorder.listSessions();
  assert.ok(sessions.length >= 3, "every session listed");
  assert.ok(sessions[0].id >= sessions[1].id, "sessions newest first");
  check("disk write failure stops recording, closes the writer, surfaces lastError", () => {});

  // -- 11. session management ----------------------------------------------
  await assert.rejects(() => recorder.deleteSession("../../etc/passwd"), /Invalid session id/);
  const victim = sessions[sessions.length - 1].id;
  await recorder.deleteSession(victim);
  const remaining = await recorder.listSessions();
  assert.ok(!remaining.some((s) => s.id === victim), "session deleted");
  check("session listing and deletion (with id validation)", () => {});

  // -- 12. settings rebind --------------------------------------------------
  const previousClient = currentClient();
  settingsManager.snapshot = { settings: { networkTables: { host: "10.47.65.2", port: 5810 } } };
  recorder.updateSettingsSnapshot(settingsManager.snapshot);
  const rebound = currentClient();
  assert.notStrictEqual(rebound, previousClient, "client rebound on host change");
  assert.strictEqual(previousClient.closed, true, "old client closed");
  assert.strictEqual(recorder.getStatus().host, "10.47.65.2");

  recorder.updateSettingsSnapshot(settingsManager.snapshot);
  assert.strictEqual(currentClient(), rebound, "identical settings do not rebind");
  check("settings snapshot rebinds the client only when host/port changes", () => {});

  await recorder.shutdown();
  await fsp.rm(dir, { recursive: true, force: true });

  // ============================ regressions ================================
  // Each block below pins a defect that shipped once. They run on their own rigs
  // because they need host changes, clock states and start-before-connect.

  // -- 13. REGRESSION: one clock domain per log -----------------------------
  // The headline use case is arming a recording BEFORE the robot connects. The
  // recorder used to stamp its own records with Date.now() * 1000 (epoch us) while
  // NT value frames carry server-uptime us, so such a log spanned ~55 years between
  // its own Start records and its first real sample.
  {
    const rig = await newRig();
    rig.recorder.initialize();
    const c = currentClient();

    // Nothing has connected: no announces, no values, no RTT offset.
    assert.strictEqual(rig.recorder.getStatus().isConnected, false);
    await rig.recorder.start({ note: "armed before the robot booted" });
    const w = rig.writers[0];

    const preConnect = timestampsOf(w);
    assert.ok(preConnect.length > 0, "start wrote records");
    for (const ts of preConnect) {
      assert.ok(
        ts < EPOCH_US_SENTINEL,
        `pre-connection record stamped with epoch microseconds (${ts}) - wrong clock domain`,
      );
      assert.strictEqual(ts, 0, `pre-connection records sit at the origin of the server domain (saw ${ts})`);
    }

    // Robot turns up 12.5 s into its own uptime and the RTT heartbeat settles.
    c.open();
    c.syncClock(12_500_000);
    c.announce(1, "/Swerve/Speed", "double");
    c.value(1, 1.5, 12_500_000);

    await sleep(120); // real time passes with no further NT traffic
    const summary = await rig.recorder.stop();
    const all = timestampsOf(w);
    const span = Math.max(...all) - Math.min(...all);
    assert.ok(span < 3600 * 1_000_000, `log spans ${span} us; the two clock domains are back`);
    assert.ok(
      all.every((ts) => ts < EPOCH_US_SENTINEL),
      "no record may carry epoch microseconds",
    );

    // Records generated locally AFTER the clock is known are converted into server time.
    const stopMarker = markersOf(w).pop();
    assert.ok(stopMarker.value.startsWith("session stop"), "stop marker written");
    assert.ok(
      Math.abs(stopMarker.timestampUs - 12_500_000) < 5_000_000,
      `locally-triggered records converted into server uptime (saw ${stopMarker.timestampUs})`,
    );
    // Strictly ahead of the last sample by roughly the real elapsed time: the offset was
    // actually applied, rather than the last server stamp merely being echoed back.
    assert.ok(
      stopMarker.timestampUs > 12_500_000 + 50_000,
      `local elapsed time converted through serverTimeOffsetUs (saw ${stopMarker.timestampUs})`,
    );
    assert.ok(summary.firstServerTimestampUs > 0);
    await rig.dispose();
    check("start-before-connect keeps the whole log in the NT server clock domain", () => {});
  }

  // -- 14. REGRESSION: a host change clears the previous robot's state -------
  // #ensureClient replaced the client but kept this.topics / this.latestValues, so a
  // START pressed before the new client announced seeded the log with another
  // machine's data. #teardownClient also removed listeners before close(), so the
  // 'close' event never arrived and the UI kept showing NT CONNECTED.
  {
    const rig = await newRig({ host: "10.47.65.2" });
    rig.recorder.initialize();
    const oldClient = currentClient();
    oldClient.open();
    oldClient.syncClock(30_000_000);
    oldClient.announce(1, "/Real/Robot/Pose", "double");
    oldClient.value(1, 7.25, 30_000_000);
    assert.strictEqual(rig.recorder.getStatus().isConnected, true);
    assert.ok(rig.recorder.getStatus().topicCount > 0);

    rig.settings.snapshot = { settings: { networkTables: { host: "127.0.0.1", port: 5810 } } };
    rig.recorder.updateSettingsSnapshot(rig.settings.snapshot);

    // DEFECT 3
    assert.strictEqual(
      rig.recorder.getStatus().isConnected,
      false,
      "isConnected must be cleared when a live client is torn down for a host change",
    );
    assert.strictEqual(rig.recorder.getStatus().host, "127.0.0.1");
    assert.notStrictEqual(currentClient(), oldClient, "a new client was created");

    // DEFECT 2: START before the new client announces anything.
    await rig.recorder.start();
    const w = rig.writers[0];
    assert.strictEqual(
      w.records.filter((r) => r.name === "NT:/Real/Robot/Pose").length,
      0,
      "the previous host's topic leaked into the new log",
    );
    assert.strictEqual(
      w.records.filter((r) => r.kind === "start" && r.name.startsWith("NT:")).length,
      0,
      "no NT channels may be seeded from a host we are not connected to",
    );
    assert.strictEqual(rig.recorder.getStatus().topicCount, 0, "topic count reset with the host");
    // The old server's clock went with it, so nothing is stamped in its domain either.
    assert.ok(timestampsOf(w).every((ts) => ts === 0), "the old server's clock did not survive the swap");

    await rig.recorder.stop();
    await rig.dispose();
    check("host change clears stale topics, values, clock and the connected flag", () => {});
  }

  // -- 15. REGRESSION: stop() captures the video tail -----------------------
  // The sink used to close before the renderer was told to stop MediaRecorder, so the
  // trailing chunk - the one that closes the final webm cluster - was thrown away and
  // the sidecar recorded a stale videoBytes.
  {
    const rig = await newRig();
    rig.recorder.initialize();
    const c = currentClient();
    c.open();
    c.syncClock(1_000_000);
    await rig.recorder.start();
    await rig.recorder.beginVideo({ deviceLabel: "Field Cam", mimeType: "video/webm" });
    await rig.recorder.appendVideoChunk(new Uint8Array([1, 2, 3, 4]));

    // A renderer that behaves like MediaRecorder: it only learns to stop from the
    // status broadcast, and its last chunk arrives some time after that.
    let tail = null;
    rig.recorder.on("status", (status) => {
      if (status.isRecording || tail) return;
      tail = (async () => {
        await sleep(40);
        await rig.recorder.appendVideoChunk(new Uint8Array([9, 9, 9, 9, 9, 9]));
        await rig.recorder.endVideo();
      })();
    });

    const summary = await rig.recorder.stop();
    await tail;
    assert.ok(tail, "the renderer was told to stop before the sink closed");
    assert.strictEqual(summary.videoBytes, 10, "sidecar videoBytes includes the trailing chunk");
    const bytes = await fsp.readFile(path.join(rig.dir, `${summary.id}.webm`));
    assert.deepStrictEqual(
      [...bytes],
      [1, 2, 3, 4, 9, 9, 9, 9, 9, 9],
      "the trailing chunk must reach the file",
    );
    await rig.dispose();
    check("stop waits for the renderer's trailing video chunk before closing the sink", () => {});
  }

  // -- 15b. ...but the wait is bounded ---------------------------------------
  {
    const rig = await newRig();
    rig.recorder.initialize();
    await rig.recorder.start();
    await rig.recorder.beginVideo({ deviceLabel: "Field Cam", mimeType: "video/webm" });
    await rig.recorder.appendVideoChunk(new Uint8Array([1, 2, 3, 4]));

    // No listener: the renderer is wedged or already dead.
    const startedAt = Date.now();
    const summary = await rig.recorder.stop();
    const waitedMs = Date.now() - startedAt;
    assert.ok(waitedMs >= VIDEO_TAIL_MS - 25, `waited for the tail (${waitedMs} ms)`);
    assert.ok(waitedMs < VIDEO_TAIL_MS + 2000, `wait is bounded (${waitedMs} ms)`);
    assert.strictEqual(summary.videoBytes, 4, "what was captured still lands");
    assert.ok(/did not stop in time/.test(rig.recorder.getStatus().lastError ?? ""), "timeout reported");
    await rig.dispose();
    check("an unresponsive renderer cannot hang stop(); the tail wait expires", () => {});
  }

  // -- 16. REGRESSION: re-opening a session's video never truncates ----------
  // Leaving and re-entering the Record app called endVideo() then beginVideo(), and
  // beginVideo re-opened the same path with flags:"w", destroying the whole capture.
  {
    const rig = await newRig();
    rig.recorder.initialize();
    await rig.recorder.start();
    await rig.recorder.beginVideo({ deviceLabel: "Field Cam", mimeType: "video/webm" });
    await rig.recorder.appendVideoChunk(new Uint8Array([1, 2, 3, 4]));
    await rig.recorder.endVideo();

    await sleep(60); // time passes while the tab is away

    // Tab switch back: the camera remounts and re-opens the SAME path.
    await rig.recorder.beginVideo({ deviceLabel: "Field Cam", mimeType: "video/webm" });
    assert.strictEqual(
      rig.recorder.getStatus().video.bytesWritten,
      4,
      "a re-open must keep the bytes already captured",
    );
    await rig.recorder.appendVideoChunk(new Uint8Array([5, 6]));
    await rig.recorder.endVideo();

    const summary = await rig.recorder.stop();
    const bytes = await fsp.readFile(path.join(rig.dir, `${summary.id}.webm`));
    assert.deepStrictEqual([...bytes], [1, 2, 3, 4, 5, 6], "re-open truncated the video");
    assert.strictEqual(summary.videoBytes, 6);
    assert.ok(
      summary.videoStartOffsetMs < 50,
      `videoStartOffsetMs still describes the first frame (saw ${summary.videoStartOffsetMs})`,
    );
    await rig.dispose();
    check("re-opening a session's video appends instead of truncating", () => {});
  }

  // -- 17. REGRESSION: an async disk failure is noticed ---------------------
  // The writer latches stream errors into lastError instead of throwing them at the
  // event loop; nothing polled it and nothing called flush(), so a full disk left the
  // UI showing "recording" while nothing landed.
  {
    const rig = await newRig();
    rig.recorder.initialize();
    const c = currentClient();
    c.open();
    c.syncClock(1_000_000);
    c.announce(1, "/Swerve/Speed", "double");
    await rig.recorder.start();
    const w = rig.writers[0];
    c.value(1, 1.0, 1_100_000);

    w.pendingBytes = 4096;
    assert.strictEqual(rig.recorder.getStatus().writeBacklogBytes, 4096, "writer backlog surfaced");

    // The volume goes away. appendValue keeps returning normally.
    w.breakStream(new Error("ENOSPC: no space left on device"));
    c.value(1, 2.0, 1_200_000);
    assert.strictEqual(rig.recorder.getStatus().isRecording, true, "not detectable synchronously");

    await sleep(STATUS_TICK_MS * 3);
    const status = rig.recorder.getStatus();
    assert.strictEqual(status.isRecording, false, "polling writer.lastError must fail the session");
    assert.ok(/Log write failed/.test(status.lastError ?? ""), `clear message (${status.lastError})`);
    assert.ok(/ENOSPC/.test(status.lastError ?? ""), `cause preserved (${status.lastError})`);
    assert.strictEqual(w.closed, true, "writer closed on the failure path");
    const listed = await rig.recorder.listSessions();
    assert.strictEqual(listed.length, 1);
    assert.ok(listed[0].endedAtIso, "the failed session still got its sidecar");
    await rig.dispose();
    check("an async writer/disk error fails the session instead of silently dropping data", () => {});
  }

  // -- 18. REGRESSION: an aborted start still writes its sidecar ------------
  // #abortSession closed the writer but never wrote <id>.json, leaving an orphan
  // .wpilog the session browser could not describe.
  {
    const rig = await newRig({
      writerHook: (writer) => {
        writer.failStartOnChannel = "NT:/Swerve/Speed";
      },
    });
    rig.recorder.initialize();
    const c = currentClient();
    c.open();
    c.syncClock(1_000_000);
    c.announce(1, "/Swerve/Speed", "double");
    c.value(1, 1.0, 1_000_000);

    await assert.rejects(() => rig.recorder.start(), /simulated start failure/, "start propagates");
    assert.strictEqual(rig.writers[0].closed, true, "aborted start closes the writer");
    assert.strictEqual(rig.recorder.getStatus().isRecording, false);

    const listed = await rig.recorder.listSessions();
    assert.strictEqual(listed.length, 1, "the log that was created is listed");
    const sidecar = JSON.parse(await fsp.readFile(path.join(rig.dir, `${listed[0].id}.json`), "utf8"));
    assert.strictEqual(sidecar.aborted, true, "aborted sessions are marked as such");
    assert.ok(/simulated start failure/.test(sidecar.error ?? ""), "sidecar records why it died");
    assert.ok(sidecar.endedAtIso, "sidecar is closed out");
    assert.notStrictEqual(listed[0].incomplete, true, "no orphan .wpilog without a sidecar");
    await rig.dispose();
    check("an aborted start writes a sidecar instead of orphaning the log", () => {});
  }

  // -- 19. simulator enable fallback ----------------------------------------
  // PWRDrive's NT server publishes neither of the two real enable signals, so without
  // this fallback auto-record could not be exercised against the simulator at all.
  {
    const rig = await newRig();
    rig.recorder.initialize();
    const c = currentClient();
    c.open();
    c.syncClock(1_000_000);
    rig.recorder.setAutoRecord(true);

    c.announce(1, SIM_RUNNING_TOPIC, "boolean");
    c.value(1, true, 1_000_000);
    await sleep(30);
    let status = rig.recorder.getStatus();
    assert.strictEqual(status.isRecording, true, "the simulator's enable signal arms auto-record");
    assert.strictEqual(status.robotEnabledSource, "simulator", "status reflects the source");
    assert.strictEqual(rig.recorder.session.autoStarted, true);

    // A real DriverStation signal outranks it, and the simulator one cannot override it.
    c.announce(2, ENABLED_TOPIC, "boolean");
    c.value(2, false, 1_100_000);
    await sleep(20);
    status = rig.recorder.getStatus();
    assert.strictEqual(status.robotEnabledSource, "advantagekit", "the real signal takes over");
    assert.strictEqual(status.robotEnabled, false);

    c.value(1, true, 1_200_000);
    status = rig.recorder.getStatus();
    assert.strictEqual(status.robotEnabled, false, "the simulator signal must not override the DriverStation");
    assert.strictEqual(status.robotEnabledSource, "advantagekit");

    await sleep(GRACE_MS * 2 + 80);
    assert.strictEqual(rig.recorder.getStatus().isRecording, false, "auto-stop still fires");
    await rig.dispose();
    check("simulator MatchStatus/Running arms auto-record, ranked below the real signals", () => {});
  }

  for (const { label } of checks) console.log(`  ok  ${label}`);
  console.log(`\n${checks.length} checks passed`);
}

let completed = false;

// Node exits 0 and completely silently when a promise can never settle and no handles
// are left (an unref'd timer inside an awaited loop does exactly that). Without this
// guard such a hang reads as a pass.
process.on("exit", (code) => {
  if (!completed && code === 0) {
    console.error("\nFAILED: the check exited before finishing - an await never settled.");
    process.exitCode = 1;
  }
});

main().then(
  () => {
    completed = true;
    process.exit(0);
  },
  (error) => {
    completed = true;
    console.error("\nFAILED:", error?.stack ?? error);
    process.exit(1);
  },
);
