#!/usr/bin/env node
//
// Self-check for electron/nt4-record-client.cjs.
//
//   node electron/__checks__/nt4-client.check.cjs                    # tries 127.0.0.1:5810
//   node electron/__checks__/nt4-client.check.cjs --host 10.47.65.2  # a real robot
//   node electron/__checks__/nt4-client.check.cjs --fake             # force the built-in server
//
// If no NT4 server answers within --probe ms, the script starts its own minimal NT4 server
// in-process and verifies against that, so the check never hangs and never silently passes.
//
const { WebSocketServer } = require("ws");
const { encode } = require("@msgpack/msgpack");
const { Nt4RecordClient } = require("../nt4-record-client.cjs");

const PROTOCOL_V4_0 = "networktables.first.wpi.edu";
const UNANNOUNCED_TOPIC_ID = 9999;

const FAKE_TOPICS = [
  { id: 1, name: "/SmartDashboard/counter", type: "double", typeNum: 1 },
  { id: 2, name: "/SmartDashboard/mode", type: "string", typeNum: 4 },
  { id: 3, name: "/Odometry/Pose", type: "struct:Pose2d", typeNum: 5 },
  { id: 4, name: "/FMSInfo/FMSControlData", type: "int", typeNum: 2 },
  { id: 5, name: "/Drive/WheelPositions", type: "double[]", typeNum: 17 },
];

function parseArgs(argv) {
  const args = { host: "127.0.0.1", port: 5810, durationMs: 5000, probeMs: 3000, fake: false };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    const next = argv[i + 1];
    if (key === "--host") { args.host = next; i += 1; }
    else if (key === "--port") { args.port = Number(next); i += 1; }
    else if (key === "--duration") { args.durationMs = Number(next); i += 1; }
    else if (key === "--probe") { args.probeMs = Number(next); i += 1; }
    else if (key === "--fake") { args.fake = true; }
  }
  return args;
}

function describeValue(value) {
  if (value instanceof Uint8Array) return `<${value.length} bytes>`;
  if (Array.isArray(value)) return `[${value.length} items]`;
  if (typeof value === "string") {
    return value.length > 40 ? `"${value.slice(0, 40)}..."` : `"${value}"`;
  }
  if (typeof value === "bigint") return `${value}n`;
  return String(value);
}

function pad(text, width) {
  const s = String(text);
  return s.length >= width ? s : s + " ".repeat(width - s.length);
}

// ---------------------------------------------------------------------------
// Minimal fake NT4 server (fallback so this check is never a no-op)
// ---------------------------------------------------------------------------

function startFakeServer() {
  return new Promise((resolve) => {
    const server = new WebSocketServer({
      host: "127.0.0.1",
      port: 0,
      handleProtocols: (protocols) => (protocols.has(PROTOCOL_V4_0) ? PROTOCOL_V4_0 : false),
    });

    server.on("connection", (socket) => {
      socket.send(
        JSON.stringify(
          FAKE_TOPICS.map((topic) => ({
            method: "announce",
            params: { name: topic.name, id: topic.id, type: topic.type, properties: { persistent: false } },
          })),
        ),
      );

      let tick = 0;
      const timestampBase = 1_234_000_000;

      const timer = setInterval(() => {
        if (socket.readyState !== socket.OPEN) return;
        tick += 1;
        const timestampUs = timestampBase + tick * 20_000;

        // Several msgpack values concatenated into ONE binary frame. A client using
        // decode() instead of decodeMulti() only ever sees the first of these.
        const frame = Buffer.concat([
          Buffer.from(encode([1, timestampUs, 1, tick * 0.5])),
          Buffer.from(encode([2, timestampUs, 4, tick % 2 === 0 ? "teleop" : "auto"])),
          Buffer.from(encode([3, timestampUs, 5, new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])])),
          Buffer.from(encode([4, timestampUs, 2, tick])),
          Buffer.from(encode([5, timestampUs, 17, [0.1, 0.2, 0.3, 0.4]])),
          // A value for a topic the server never announced: must be dropped, not emitted.
          Buffer.from(encode([UNANNOUNCED_TOPIC_ID, timestampUs, 1, 42])),
        ]);
        socket.send(frame, { binary: true });
      }, 20);
      timer.unref?.();

      socket.on("message", (data, isBinary) => {
        if (!isBinary) return; // subscribe frame; the fake server sends everything regardless
        // Echo an RTT response so the client's clock-offset path gets exercised.
        socket.send(encode([-1, timestampBase + tick * 20_000, 2, Date.now() * 1000]), { binary: true });
      });

      socket.on("close", () => clearInterval(timer));
    });

    server.on("listening", () => {
      const { port } = server.address();
      resolve({ server, host: "127.0.0.1", port });
    });
  });
}

// ---------------------------------------------------------------------------
// Regression cases
//
// These always run, whatever --host points at: they stand up their own throwaway servers
// so each past defect stays nailed down. A fix without a check is how this comes back.
// ---------------------------------------------------------------------------

const REGRESSION_TOPICS = [
  { id: 11, name: "/reg/a", type: "double", typeNum: 1 },
  { id: 12, name: "/reg/b", type: "double", typeNum: 1 },
  { id: 13, name: "/reg/c", type: "double", typeNum: 1 },
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref?.());

function startScriptedServer(onConnection) {
  return new Promise((resolve) => {
    const server = new WebSocketServer({
      host: "127.0.0.1",
      port: 0,
      handleProtocols: (protocols) => (protocols.has(PROTOCOL_V4_0) ? PROTOCOL_V4_0 : false),
    });
    server.on("connection", onConnection);
    server.on("listening", () => resolve({ server, port: server.address().port }));
  });
}

function announceRegressionTopics(socket) {
  socket.send(
    JSON.stringify(
      REGRESSION_TOPICS.map((topic) => ({
        method: "announce",
        params: { name: topic.name, id: topic.id, type: topic.type, properties: {} },
      })),
    ),
  );
}

// One websocket frame carrying all three values, concatenated msgpack.
function regressionValueFrame(timestampUs) {
  return Buffer.concat(
    REGRESSION_TOPICS.map((topic) =>
      Buffer.from(encode([topic.id, timestampUs, topic.typeNum, topic.id])),
    ),
  );
}

// REGRESSION: a listener that throws must not escape into ws's message dispatch.
//
// This is the exact shape of main.cjs's broadcastToWindows hitting a destroyed webContents
// (routine: it happens whenever a dashboard window closes mid-broadcast). Both the 'value'
// consumer and the 'error' consumer throw, because NtRecorder's error handler emits 'status'
// too -- so a naive "report the failure" path re-enters the very chain that just threw and
// the second throw lands uncaught in the Electron main process, killing the dashboard.
async function regressionListenerThrowIsContained() {
  const failures = [];
  let uncaught = null;
  const onUncaught = (error) => { uncaught = error; };
  process.once("uncaughtException", onUncaught);

  const { server, port } = await startScriptedServer((socket) => {
    announceRegressionTopics(socket);
    setTimeout(() => {
      if (socket.readyState === socket.OPEN) socket.send(regressionValueFrame(1000), { binary: true });
    }, 30).unref?.();
  });

  const client = new Nt4RecordClient({ host: "127.0.0.1", port });
  client.on("value", () => { throw new Error("Object has been destroyed"); });
  client.on("error", () => { throw new Error("Object has been destroyed"); });

  client.connect();
  const opened = await waitForOpen(client, 3000);
  await sleep(300);

  const stats = client.getStats();
  client.close();
  server.close();
  process.off("uncaughtException", onUncaught);

  if (!opened) failures.push("[regression:listener-throw] never connected");
  if (uncaught) {
    failures.push(`[regression:listener-throw] uncaught exception escaped: ${uncaught.message}`);
  }
  if (stats.valueCount === 0) failures.push("[regression:listener-throw] no values decoded");
  if (stats.listenerErrorCount === 0) {
    failures.push("[regression:listener-throw] listener throws were not counted");
  }
  return failures;
}

// REGRESSION: a throwing listener must not truncate the frame.
//
// Delivery used to happen from inside the decodeMulti GENERATOR, so one listener throwing
// aborted the generator and silently discarded every remaining msgpack value in the frame --
// and miscounted the loss as a decodeError. Two frames of three values, a listener that
// throws on the middle topic: every topic must still arrive twice, in BOTH consumers, and
// nothing may be booked as a decode error.
async function regressionThrowDoesNotTruncateFrame() {
  const failures = [];

  const { server, port } = await startScriptedServer((socket) => {
    announceRegressionTopics(socket);
    setTimeout(() => {
      if (socket.readyState !== socket.OPEN) return;
      socket.send(regressionValueFrame(1000), { binary: true });
      socket.send(regressionValueFrame(2000), { binary: true });
    }, 30).unref?.();
  });

  const badListenerSaw = new Map();
  const goodListenerSaw = new Map();
  const bump = (map, name) => map.set(name, (map.get(name) ?? 0) + 1);

  const client = new Nt4RecordClient({ host: "127.0.0.1", port });
  client.on("error", () => {});
  client.on("value", (sample) => {
    bump(badListenerSaw, sample.name);
    if (sample.name === "/reg/b") throw new Error("downstream consumer blew up");
  });
  // A well-behaved second consumer registered after the bad one: EventEmitter.emit() would
  // have abandoned it entirely the moment the first listener threw.
  client.on("value", (sample) => bump(goodListenerSaw, sample.name));

  client.connect();
  const opened = await waitForOpen(client, 3000);
  await sleep(300);

  const stats = client.getStats();
  client.close();
  server.close();

  if (!opened) failures.push("[regression:frame-truncation] never connected");

  REGRESSION_TOPICS.forEach((topic) => {
    const bad = badListenerSaw.get(topic.name) ?? 0;
    const good = goodListenerSaw.get(topic.name) ?? 0;
    if (bad !== 2) {
      failures.push(`[regression:frame-truncation] throwing consumer saw ${topic.name} ${bad}x, expected 2`);
    }
    if (good !== 2) {
      failures.push(`[regression:frame-truncation] good consumer saw ${topic.name} ${good}x, expected 2`);
    }
  });

  if (stats.valueCount !== 6) {
    failures.push(`[regression:frame-truncation] valueCount ${stats.valueCount}, expected 6`);
  }
  // The accounting matters: a value lost to a listener throw is not a decode error.
  if (stats.decodeErrorCount !== 0) {
    failures.push(`[regression:frame-truncation] listener throw booked as ${stats.decodeErrorCount} decode errors`);
  }
  if (stats.listenerErrorCount !== 2) {
    failures.push(`[regression:frame-truncation] listenerErrorCount ${stats.listenerErrorCount}, expected 2`);
  }
  return failures;
}

// REGRESSION: null in a 'properties' update means DELETE the property (NT4 spec).
//
// It used to be merged with a spread, storing the null literally -- and nt-recorder
// serializes topic.properties verbatim into the WPILOG entry metadata, so the recorded log
// misstated the topic's properties.
async function regressionPropertyDeletion() {
  const failures = [];

  const { server, port } = await startScriptedServer((socket) => {
    socket.send(
      JSON.stringify([
        {
          method: "announce",
          params: { name: "/reg/props", id: 21, type: "double", properties: { persistent: false } },
        },
      ]),
    );
    setTimeout(() => {
      if (socket.readyState !== socket.OPEN) return;
      socket.send(
        JSON.stringify([
          { method: "properties", params: { name: "/reg/props", ack: false, update: { persistent: true, retained: true } } },
        ]),
      );
      socket.send(
        JSON.stringify([
          { method: "properties", params: { name: "/reg/props", ack: false, update: { persistent: null } } },
        ]),
      );
    }, 30).unref?.();
  });

  const client = new Nt4RecordClient({ host: "127.0.0.1", port });
  client.on("error", () => {});
  client.connect();
  const opened = await waitForOpen(client, 3000);
  await sleep(300);

  const topic = client.getAnnouncedTopics().find((entry) => entry.name === "/reg/props");
  client.close();
  server.close();

  if (!opened) failures.push("[regression:property-delete] never connected");
  if (!topic) {
    failures.push("[regression:property-delete] topic was never announced");
    return failures;
  }
  if ("persistent" in topic.properties) {
    failures.push(
      `[regression:property-delete] null update did not delete the property: ${JSON.stringify(topic.properties)}`,
    );
  }
  if (topic.properties.retained !== true) {
    failures.push(
      `[regression:property-delete] non-null update lost: ${JSON.stringify(topic.properties)}`,
    );
  }
  return failures;
}

async function runRegressions() {
  const cases = [
    ["listener throw contained (no uncaught exception)", regressionListenerThrowIsContained],
    ["listener throw does not truncate the frame", regressionThrowDoesNotTruncateFrame],
    ["null properties update deletes the property", regressionPropertyDeletion],
  ];

  const failures = [];
  for (const [label, run] of cases) {
    let caseFailures;
    try {
      caseFailures = await run();
    } catch (error) {
      caseFailures = [`[regression] ${label} threw: ${error.stack || error.message}`];
    }
    console.log(`  ${caseFailures.length === 0 ? "ok  " : "FAIL"}  ${label}`);
    failures.push(...caseFailures);
  }
  return failures;
}

// ---------------------------------------------------------------------------

function waitForOpen(client, timeoutMs) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      client.off("open", onOpen);
      resolve(false);
    }, timeoutMs);
    const onOpen = () => {
      clearTimeout(timer);
      resolve(true);
    };
    client.once("open", onOpen);
  });
}

function collect(client, durationMs) {
  return new Promise((resolve) => {
    const samples = [];
    const byName = new Map();

    const onValue = (sample) => {
      if (samples.length < 20) samples.push(sample);
      byName.set(sample.name, (byName.get(sample.name) ?? 0) + 1);
    };

    client.on("value", onValue);
    setTimeout(() => {
      client.off("value", onValue);
      resolve({ samples, byName });
    }, durationMs).unref?.();
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  console.log("[check] regressions:");
  const regressionFailures = await runRegressions();
  console.log("");

  let fake = null;
  let host = args.host;
  let port = args.port;
  let mode = "live";

  if (args.fake) {
    fake = await startFakeServer();
    host = fake.host;
    port = fake.port;
    mode = "fake";
    console.log(`[check] using built-in fake NT4 server on ${host}:${port} (--fake)`);
  }

  let client = new Nt4RecordClient({ host, port });
  client.on("error", (error) => console.log(`[check] client error: ${error.message}`));
  client.connect();

  let opened = await waitForOpen(client, args.probeMs);

  if (!opened && !fake) {
    console.log(`[check] no NT4 server answered at ${host}:${port} within ${args.probeMs} ms`);
    client.close();
    fake = await startFakeServer();
    host = fake.host;
    port = fake.port;
    mode = "fake";
    console.log(`[check] falling back to the built-in fake NT4 server on ${host}:${port}`);
    client = new Nt4RecordClient({ host, port });
    client.on("error", (error) => console.log(`[check] client error: ${error.message}`));
    client.connect();
    opened = await waitForOpen(client, args.probeMs);
  }

  if (!opened) {
    console.log("[check] FAIL: could not open a websocket to any NT4 server");
    regressionFailures.forEach((failure) => console.log(`[check] FAIL: ${failure}`));
    client.close();
    fake?.server.close();
    process.exit(1);
  }

  console.log(`[check] connected to ws://${host}:${port} (${mode}); collecting for ${args.durationMs} ms`);
  const { samples, byName } = await collect(client, args.durationMs);

  const topics = client.getAnnouncedTopics();
  const stats = client.getStats();

  console.log("");
  console.log(`announced topics : ${client.topicCount}`);
  console.log(`values received  : ${stats.valueCount}`);
  console.log(`values dropped   : ${stats.droppedValueCount} (unannounced topic id)`);
  console.log(`type mismatches  : ${stats.typeMismatchCount}`);
  console.log(`decode errors    : ${stats.decodeErrorCount}`);
  console.log(`listener errors  : ${stats.listenerErrorCount}`);
  console.log(`best rtt (us)    : ${stats.bestRttUs}`);
  console.log("");

  console.log("first 20 topics:");
  topics.slice(0, 20).forEach((topic) => {
    console.log(`  ${pad(topic.type, 22)} ${topic.name}`);
  });
  if (topics.length > 20) console.log(`  ... and ${topics.length - 20} more`);
  console.log("");

  console.log("first 20 values:");
  samples.forEach((sample) => {
    console.log(
      `  ${pad(sample.timestampUs, 14)} ${pad(sample.type, 18)} ${pad(sample.name, 44)} ${describeValue(sample.value)}`,
    );
  });
  console.log("");

  const structTopics = topics.filter((topic) => topic.type.startsWith("struct:"));
  if (structTopics.length) {
    console.log(`struct-typed topics: ${structTopics.length}`);
    structTopics.slice(0, 5).forEach((topic) => console.log(`  ${topic.type} ${topic.name}`));
    console.log("");
  }

  const failures = [...regressionFailures];
  if (client.topicCount === 0) failures.push("no topics announced");
  if (stats.valueCount === 0) failures.push("no values received");
  if (stats.decodeErrorCount > 0) failures.push(`${stats.decodeErrorCount} decode errors`);
  // Nothing in this script throws from a listener, so any count here is a real consumer bug.
  if (stats.listenerErrorCount > 0) failures.push(`${stats.listenerErrorCount} listener errors`);
  if (samples.some((sample) => !sample.name)) failures.push("emitted a value with no name");

  if (mode === "fake") {
    if (client.topicCount !== FAKE_TOPICS.length) {
      failures.push(`expected ${FAKE_TOPICS.length} topics, saw ${client.topicCount}`);
    }
    // One value per announced topic per frame proves decodeMulti is in use; decode()
    // would have yielded only the first element of each frame.
    FAKE_TOPICS.forEach((topic) => {
      if (!byName.has(topic.name)) failures.push(`never saw a value for ${topic.name}`);
    });
    if (stats.droppedValueCount === 0) failures.push("unannounced-topic value was not dropped/counted");
    if (stats.typeMismatchCount > 0) failures.push(`${stats.typeMismatchCount} type mismatches against known-good types`);
    const pose = samples.find((sample) => sample.name === "/Odometry/Pose");
    if (!pose) failures.push("no /Odometry/Pose sample");
    else if (!(pose.value instanceof Uint8Array)) failures.push("struct value did not decode to Uint8Array");
    else if (pose.type !== "struct:Pose2d") failures.push(`struct type string lost: ${pose.type}`);
    const counter = samples.find((sample) => sample.name === "/SmartDashboard/counter");
    if (counter && counter.timestampUs < 1_234_000_000) failures.push("server timestamp was not passed through");
  }

  client.close();
  fake?.server.close();

  if (failures.length) {
    failures.forEach((failure) => console.log(`[check] FAIL: ${failure}`));
    process.exit(1);
  }

  console.log(`[check] OK (${mode})`);
  process.exit(0);
}

main().catch((error) => {
  console.log(`[check] FAIL: ${error.stack || error.message}`);
  process.exit(1);
});
