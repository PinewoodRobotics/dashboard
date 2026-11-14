#!/usr/bin/env node
/**
 * Self-check for wpilog-writer.cjs.
 *
 * Writes a WPILOG exercising every value type the recorder can emit, re-reads it with an
 * independent in-file parser, and asserts every record round-trips byte-for-byte.
 *
 * The same file is then re-read by PWRDrive's Python reader
 * (~/Developer/FIR/src/PWRDrive/scripts/logs/wpilog.py) in the verify stage.
 *
 * Usage: node electron/__checks__/wpilog-writer.check.cjs [outPath]
 */

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { WpilogWriter, encodeValue, MAX_BACKLOG_BYTES } = require("../wpilog-writer.cjs");

const outPath =
  process.argv[2] ?? path.join(os.tmpdir(), "pwrup-wpilog-check", "wpilog-writer.check.wpilog");

const EXTRA_HEADER = JSON.stringify({
  source: "pwrup-comp-dashboard",
  kind: "nt-client-recording",
  version: 1,
  note: "self-check é→𝄞",
});

const BASE_TS = 1_700_000_000_000_000; // ~2023 epoch microseconds: forces a 7-byte timestamp

// name, type, [values...] — every value is asserted on read-back.
const CASES = [
  ["NT:/check/boolean", "boolean", [true, false, true]],
  ["NT:/check/int64", "int64", [0, -1, 42, -9007199254740993n, 9223372036854775807n, -9223372036854775808n]],
  ["NT:/check/float", "float", [0, 1.5, -2.25, 3.4028234663852886e38]],
  ["NT:/check/double", "double", [0, -1.7976931348623157e308, Math.PI]],
  ["NT:/check/string", "string", ["", "hello", "unicode éü中文 𝄞"]],
  ["NT:/check/json", "json", ['{"a":1}', "{}"]],
  ["NT:/check/boolean[]", "boolean[]", [[], [true], [false, true, false]]],
  ["NT:/check/int64[]", "int64[]", [[], [1, -1], [9007199254740993n, -9007199254740993n]]],
  ["NT:/check/float[]", "float[]", [[], [1.5, -2.5]]],
  ["NT:/check/double[]", "double[]", [[], [1, 2, 3], [-0.5]]],
  ["NT:/check/string[]", "string[]", [[], [""], ["a", "", "中文"]]],
  ["NT:/check/raw", "raw", [new Uint8Array([]), new Uint8Array([0, 1, 2, 253, 254, 255])]],
  ["NT:/check/msgpack", "msgpack", [Buffer.from([0x81, 0xa1, 0x61, 0x01])]],
  ["NT:/check/struct", "struct:Pose2d", [new Uint8Array(24).fill(0x5a)]],
  ["NT:/check/structschema", "structschema", [Buffer.from("double x;double y", "utf8")]],
  ["NT:/check/protobuf", "proto:Pose2d", [new Uint8Array([0x08, 0x96, 0x01])]],
];

// ---------------------------------------------------------------------------
// Independent reader (deliberately written from the spec, not from the writer)
// ---------------------------------------------------------------------------

function readRecords(filePath) {
  const buf = fs.readFileSync(filePath);
  assert.strictEqual(buf.subarray(0, 6).toString("ascii"), "WPILOG", "bad magic");
  assert.strictEqual(buf.readUInt16LE(6), 0x0100, "bad version");
  const extraLength = buf.readUInt32LE(8);
  const extraHeader = buf.subarray(12, 12 + extraLength).toString("utf8");

  const records = [];
  let offset = 12 + extraLength;
  while (offset < buf.length) {
    const header = buf[offset];
    offset += 1;
    assert.strictEqual(header & 0x80, 0, "header bit 7 must be zero");
    const idLength = (header & 0x03) + 1;
    const sizeLength = ((header >> 2) & 0x03) + 1;
    const tsLength = ((header >> 4) & 0x07) + 1;

    const entryId = Number(readUintLE(buf, offset, idLength));
    offset += idLength;
    const payloadSize = Number(readUintLE(buf, offset, sizeLength));
    offset += sizeLength;
    const timestampUs = readUintLE(buf, offset, tsLength);
    offset += tsLength;

    const payload = buf.subarray(offset, offset + payloadSize);
    assert.ok(offset + payloadSize <= buf.length, "truncated payload");
    offset += payloadSize;

    records.push({ entryId, timestampUs, payload, idLength, sizeLength, tsLength });
  }
  return { extraHeader, records };
}

function readUintLE(buf, offset, length) {
  let value = 0n;
  for (let i = length - 1; i >= 0; i -= 1) {
    value = (value << 8n) | BigInt(buf[offset + i]);
  }
  return value;
}

function parseControl(payload) {
  const type = payload[0];
  if (type === 0) {
    let offset = 1;
    const entryId = payload.readUInt32LE(offset);
    offset += 4;
    const read = () => {
      const length = payload.readUInt32LE(offset);
      offset += 4;
      const text = payload.subarray(offset, offset + length).toString("utf8");
      offset += length;
      return text;
    };
    const name = read();
    const valueType = read();
    const metadata = read();
    assert.strictEqual(offset, payload.length, "trailing bytes in Start record");
    return { control: "start", entryId, name, type: valueType, metadata };
  }
  if (type === 1) {
    assert.strictEqual(payload.length, 5, "Finish record must be 5 bytes");
    return { control: "finish", entryId: payload.readUInt32LE(1) };
  }
  if (type === 2) {
    const entryId = payload.readUInt32LE(1);
    const length = payload.readUInt32LE(5);
    const metadata = payload.subarray(9, 9 + length).toString("utf8");
    assert.strictEqual(9 + length, payload.length, "trailing bytes in SetMetadata record");
    return { control: "setMetadata", entryId, metadata };
  }
  throw new Error(`unknown control type ${type}`);
}

function decodeValue(payload, type) {
  switch (type) {
    case "boolean":
      return payload[0] !== 0;
    case "int64":
      return payload.readBigInt64LE(0);
    case "float":
      return payload.readFloatLE(0);
    case "double":
      return payload.readDoubleLE(0);
    case "string":
    case "json":
      return payload.toString("utf8");
    case "boolean[]":
      return Array.from(payload, (byte) => byte !== 0);
    case "int64[]": {
      const out = [];
      for (let i = 0; i < payload.length; i += 8) out.push(payload.readBigInt64LE(i));
      return out;
    }
    case "float[]": {
      const out = [];
      for (let i = 0; i < payload.length; i += 4) out.push(payload.readFloatLE(i));
      return out;
    }
    case "double[]": {
      const out = [];
      for (let i = 0; i < payload.length; i += 8) out.push(payload.readDoubleLE(i));
      return out;
    }
    case "string[]": {
      const count = payload.readUInt32LE(0);
      const out = [];
      let offset = 4;
      for (let i = 0; i < count; i += 1) {
        const length = payload.readUInt32LE(offset);
        offset += 4;
        out.push(payload.subarray(offset, offset + length).toString("utf8"));
        offset += length;
      }
      assert.strictEqual(offset, payload.length, "trailing bytes in string[] payload");
      return out;
    }
    default:
      return Buffer.from(payload);
  }
}

// ---------------------------------------------------------------------------
// Expectation helpers
// ---------------------------------------------------------------------------

function expected(type, value) {
  switch (type) {
    case "int64":
      return typeof value === "bigint" ? value : BigInt(value);
    case "int64[]":
      return value.map((item) => (typeof item === "bigint" ? item : BigInt(item)));
    case "float":
      return Math.fround(value);
    case "float[]":
      return value.map((item) => Math.fround(item));
    default:
      if (isBytes(type)) return Buffer.from(value);
      return value;
  }
}

function isBytes(type) {
  return ![
    "boolean",
    "int64",
    "float",
    "double",
    "string",
    "json",
    "boolean[]",
    "int64[]",
    "float[]",
    "double[]",
    "string[]",
  ].includes(type);
}

// ---------------------------------------------------------------------------
// Regression checks
//
// Every case below is a defect that shipped once and was demonstrated with a reproduction.
// They write their own scratch files so the main log at `outPath` stays exactly what
// PWRDrive's Python reader consumes.
// ---------------------------------------------------------------------------

const REGRESSION_DIR = path.join(path.dirname(outPath), "regression");

function regressionPath(name) {
  return path.join(REGRESSION_DIR, name);
}

async function freshWriter(name, extraHeader = "") {
  const filePath = regressionPath(name);
  fs.rmSync(filePath, { force: true });
  const writer = new WpilogWriter(filePath, extraHeader);
  await writer.open();
  return writer;
}

/**
 * REGRESSION (defect 1): an array value for a type this writer does not recognize used to be
 * fed to Buffer.from(), which coerces every element to a single byte. encodeValue("int[]",
 * [1000, 2000, -3000]) returned 3 bytes (e8 d0 48) instead of 24 -- silent, total data loss
 * in a calibration log. Unrecognized array types must throw, exactly like a bad scalar does.
 */
function checkUnknownArrayTypeThrows() {
  const cases = [
    ["int[]", [1000, 2000, -3000]],
    ["int[]", []],
    ["bogus[]", [1, 2, 3]],
    ["raw", [1, 2, 3]],
    ["struct:Pose2d[]", [{ x: 1 }]],
  ];
  for (const [type, value] of cases) {
    assert.throws(
      () => encodeValue(type, value),
      /unrecognized array type/,
      `encodeValue(${JSON.stringify(type)}, Array) must throw, never truncate`,
    );
  }

  // ...while every array type the writer *does* know still encodes at full width, and raw
  // byte containers still pass through verbatim.
  assert.strictEqual(encodeValue("int64[]", [1000, 2000, -3000]).length, 24);
  assert.deepStrictEqual(encodeValue("int64[]", [1000, 2000, -3000]), (() => {
    const out = Buffer.alloc(24);
    out.writeBigInt64LE(1000n, 0);
    out.writeBigInt64LE(2000n, 8);
    out.writeBigInt64LE(-3000n, 16);
    return out;
  })());
  assert.strictEqual(encodeValue("double[]", [1, 2, 3]).length, 24);
  assert.deepStrictEqual(encodeValue("raw", new Uint8Array([1, 2, 3])), Buffer.from([1, 2, 3]));
  assert.deepStrictEqual(encodeValue("raw", Buffer.from([1, 2, 3])), Buffer.from([1, 2, 3]));
  assert.deepStrictEqual(
    encodeValue("raw", new Uint8Array([1, 2, 3]).buffer),
    Buffer.from([1, 2, 3]),
  );
}

/**
 * REGRESSION (defect 2): the stream 'error' handler stored the error and returned, and
 * #writePending only guarded the synchronous stream.write() call. After an async ENOSPC every
 * appendValue() still returned normally, so the recorder believed it was recording to a dead
 * file. Once the stream has errored, the very next record must throw at the caller.
 */
async function checkStreamErrorSurfaces() {
  const writer = await freshWriter("stream-error.wpilog");
  const entryId = writer.startEntry("NT:/regression/err", "double", "", 1000);
  writer.appendValue(entryId, "double", 1.5, 2000);
  await writer.flush();

  assert.strictEqual(writer.lastError, null, "healthy writer reports no error");

  // A stream failure that arrives asynchronously, the way ENOSPC/EIO does.
  const failure = new Error("ENOSPC: no space left on device, write");
  failure.code = "ENOSPC";
  writer.stream.destroy(failure);
  await new Promise((resolve) => setTimeout(resolve, 50));

  assert.ok(writer.lastError, "lastError must expose the async stream failure");
  assert.strictEqual(writer.lastError.code, "ENOSPC", "lastError must be the original error");

  const recordsBefore = writer.recordCount;
  assert.throws(
    () => writer.appendValue(entryId, "double", 2.5, 3000),
    /ENOSPC/,
    "appendValue after a stream error must throw, not pretend to record",
  );
  assert.throws(
    () => writer.startEntry("NT:/regression/after-err", "double", "", 4000),
    /ENOSPC/,
    "startEntry after a stream error must throw",
  );
  assert.throws(
    () => writer.finishEntry(entryId, 4000),
    /ENOSPC/,
    "finishEntry after a stream error must throw",
  );
  assert.throws(
    () => writer.setMetadata(entryId, "{}", 4000),
    /ENOSPC/,
    "setMetadata after a stream error must throw",
  );
  assert.strictEqual(writer.recordCount, recordsBefore, "failed records must not be counted");

  await assert.rejects(() => writer.flush(), /ENOSPC/, "flush must still rethrow");
  await assert.rejects(() => writer.close(), /ENOSPC/, "close must still rethrow");
  assert.strictEqual(writer.lastError.code, "ENOSPC", "lastError survives close");
}

/**
 * REGRESSION (defect 3): #writePending discarded stream.write()'s boolean, so the 64 KB
 * auto-flush path never waited for 'drain'. 3000 x 64 KB appends left 196.6 MB sitting in the
 * stream's internal buffer (RSS 401 MB, 0.1 MB on disk, lastError null) -- unbounded
 * main-process growth with no signal at all.
 *
 * Two halves: a producer the device can keep up with must still write everything with a tiny
 * backlog, and a producer it cannot must fail loudly with memory bounded by the ceiling.
 */
async function checkBackpressure() {
  // (a) Realistic load -- 500 topics x 50 Hz x 20 s, delivered in websocket-sized batches.
  const writer = await freshWriter("backpressure-ok.wpilog");
  const entryId = writer.startEntry("NT:/regression/Velocity", "double", "", 1000);
  let peakBacklog = 0;
  const SAMPLES = 500000;
  for (let i = 0; i < SAMPLES; i += 1) {
    writer.appendValue(entryId, "double", i / 7, 2000 + i * 40);
    if (writer.backlogBytes > peakBacklog) peakBacklog = writer.backlogBytes;
    if (i % 500 === 0) await new Promise((resolve) => setImmediate(resolve));
  }
  await writer.flush();
  const reportedBytes = writer.bytesWritten;
  const onDisk = fs.statSync(writer.filePath).size;
  await writer.close();

  assert.strictEqual(writer.lastError, null, "healthy load must not error");
  assert.strictEqual(onDisk, reportedBytes, "every byte of a healthy load must reach the disk");
  assert.ok(
    peakBacklog < 1024 * 1024,
    `backpressure must keep a healthy load's backlog small, saw ${peakBacklog} bytes`,
  );

  // (b) Pathological burst -- the exact shape of the original reproduction.
  const burst = await freshWriter("backpressure-burst.wpilog");
  const burstEntry = burst.startEntry("NT:/regression/burst", "raw", "", 1000);
  const blob = Buffer.alloc(64 * 1024, 0xab);
  let burstPeak = 0;
  let thrown = null;
  let accepted = 0;
  try {
    for (let i = 0; i < 3000; i += 1) {
      burst.appendValue(burstEntry, "raw", blob, 2000 + i);
      accepted += 1;
      if (burst.backlogBytes > burstPeak) burstPeak = burst.backlogBytes;
    }
  } catch (error) {
    thrown = error;
  }

  assert.ok(thrown, "an unservable burst must fail the session instead of buffering forever");
  assert.match(String(thrown.message), /backlog exceeded/, "the failure must name the backlog");
  assert.ok(burst.lastError, "the backlog failure must be visible via lastError");
  assert.ok(
    burstPeak <= MAX_BACKLOG_BYTES + 64 * 1024,
    `buffered bytes must stay at the ceiling (${MAX_BACKLOG_BYTES}), peaked at ${burstPeak}`,
  );
  // The pre-fix writer swallowed all 3000 appends (196.6 MB resident); anything near that is
  // the defect returning.
  assert.ok(burstPeak < 64 * 1024 * 1024, `runaway buffering: ${burstPeak} bytes`);
  assert.throws(
    () => burst.appendValue(burstEntry, "double", 1, 9999),
    /backlog exceeded/,
    "appends after a backlog failure must keep throwing",
  );
  await assert.rejects(() => burst.close(), /backlog exceeded/);

  return { peakBacklog, burstPeak, burstAccepted: accepted, healthySamples: SAMPLES };
}

/**
 * REGRESSION (defect 4): unsignedByteLength's JS-number path jumped from "<= 0x1fffffffffffff
 * -> 7" straight to 8, skipping most of the real 7-byte range, so the bytes on disk depended
 * on whether the caller passed a number or a BigInt. Length must be minimal and identical for
 * both representations.
 */
async function checkTimestampLengthIsTypeIndependent() {
  const boundaries = [
    [0, 1],
    [1, 1],
    [0xff, 1],
    [0x100, 2],
    [0xffffff, 3],
    [0x100000000, 5],
    [0xffffffffff, 5],
    [0x1000000000000, 7],
    [0x1fffffffffffff, 7], // 2^53-1: the old cutoff
    [0x20000000000000, 7], // 2^53: the old code jumped to 8 here for numbers only
    [0x80000000000000, 7],
    [0xff000000000000, 7],
  ];

  const writer = await freshWriter("timestamp-widths.wpilog");
  const entryId = writer.startEntry("NT:/regression/ts", "boolean", "", 0);
  for (const [timestamp] of boundaries) {
    writer.appendValue(entryId, "boolean", true, timestamp);
    writer.appendValue(entryId, "boolean", true, BigInt(timestamp));
  }
  await writer.close();

  const { records } = readRecords(writer.filePath);
  const valueRecords = records.filter((record) => record.entryId !== 0);
  assert.strictEqual(valueRecords.length, boundaries.length * 2);

  for (let i = 0; i < boundaries.length; i += 1) {
    const [timestamp, wantLength] = boundaries[i];
    const asNumber = valueRecords[i * 2];
    const asBigInt = valueRecords[i * 2 + 1];
    assert.strictEqual(
      asNumber.tsLength,
      asBigInt.tsLength,
      `timestamp ${timestamp} encodes to ${asNumber.tsLength} bytes as a number but ` +
        `${asBigInt.tsLength} as a BigInt`,
    );
    assert.strictEqual(
      asNumber.tsLength,
      wantLength,
      `timestamp ${timestamp} must use the minimal ${wantLength}-byte field`,
    );
    assert.strictEqual(asNumber.timestampUs, BigInt(timestamp), "timestamp value round-trip");
    assert.strictEqual(asBigInt.timestampUs, BigInt(timestamp), "BigInt timestamp round-trip");
  }

  // 8 bytes only once the value genuinely needs them (BigInt only -- 2^56 exceeds 7 bytes).
  const wide = await freshWriter("timestamp-wide.wpilog");
  const wideEntry = wide.startEntry("NT:/regression/ts8", "boolean", "", 0);
  wide.appendValue(wideEntry, "boolean", true, 0x100000000000000n);
  wide.appendValue(wideEntry, "boolean", true, 0xffffffffffffffffn);
  await wide.close();
  const wideValues = readRecords(wide.filePath).records.filter((r) => r.entryId !== 0);
  assert.deepStrictEqual(
    wideValues.map((r) => r.tsLength),
    [8, 8],
    "timestamps past 2^56 need the full 8-byte field",
  );
}

/**
 * REGRESSION (defect 5): records appended after close() were silently accepted -- recordCount
 * and totalBytes kept incrementing while the bytes went nowhere, and flush() did not complain.
 */
async function checkPostCloseAppendsThrow() {
  const writer = await freshWriter("post-close.wpilog");
  const entryId = writer.startEntry("NT:/regression/closed", "double", "", 1000);
  writer.appendValue(entryId, "double", 1.5, 2000);
  await writer.close();

  const bytesAfterClose = writer.bytesWritten;
  const recordsAfterClose = writer.recordCount;
  const entriesAfterClose = writer.entryCount;
  const sizeAfterClose = fs.statSync(writer.filePath).size;
  assert.strictEqual(sizeAfterClose, bytesAfterClose, "close must land every byte");

  assert.throws(
    () => writer.appendValue(entryId, "double", 2.5, 3000),
    /closed/,
    "appendValue after close must throw",
  );
  assert.throws(
    () => writer.startEntry("NT:/regression/late", "double", "", 3000),
    /closed/,
    "startEntry after close must throw",
  );
  assert.throws(() => writer.finishEntry(entryId, 3000), /closed/, "finishEntry after close");
  assert.throws(() => writer.setMetadata(entryId, "{}", 3000), /closed/, "setMetadata after close");

  assert.strictEqual(writer.recordCount, recordsAfterClose, "recordCount must not drift");
  assert.strictEqual(writer.bytesWritten, bytesAfterClose, "bytesWritten must not drift");
  assert.strictEqual(writer.entryCount, entriesAfterClose, "entryCount must not drift");
  assert.strictEqual(fs.statSync(writer.filePath).size, sizeAfterClose, "file must not change");

  await writer.flush(); // still a safe no-op
  await writer.close(); // idempotent

  // Writing before open() is the same class of mistake.
  const unopened = new WpilogWriter(regressionPath("never-opened.wpilog"), "");
  assert.throws(
    () => unopened.startEntry("NT:/regression/early", "double", "", 1000),
    /not open/,
    "records before open() must throw",
  );
}

async function runRegressionChecks() {
  fs.mkdirSync(REGRESSION_DIR, { recursive: true });
  checkUnknownArrayTypeThrows();
  await checkStreamErrorSurfaces();
  const backpressure = await checkBackpressure();
  await checkTimestampLengthIsTypeIndependent();
  await checkPostCloseAppendsThrow();
  return backpressure;
}

// ---------------------------------------------------------------------------

async function main() {
  fs.rmSync(outPath, { force: true });

  const writer = new WpilogWriter(outPath, EXTRA_HEADER);
  await writer.open();

  const entries = [];
  let timestamp = BASE_TS;

  // Every entry gets a Start record, all its values, then a Finish.
  for (const [name, type, values] of CASES) {
    const entryId = writer.startEntry(name, type, `{"case":"${type}"}`, timestamp);
    entries.push({ entryId, name, type, values });
    timestamp += 1;
  }

  // A SetMetadata record on the first entry, and a small-timestamp record to exercise
  // 1-byte timestamp packing.
  writer.setMetadata(entries[0].entryId, '{"revised":true}', timestamp);
  timestamp += 1;
  writer.appendValue(entries[0].entryId, "boolean", true, 7);

  for (const entry of entries) {
    for (const value of entry.values) {
      writer.appendValue(entry.entryId, entry.type, value, timestamp);
      timestamp += 1;
    }
  }

  // Enough records to cross the 64 KB buffered-write threshold at least twice.
  const bulkEntry = writer.startEntry("NT:/check/bulk", "double", "", timestamp);
  timestamp += 1;
  const BULK_COUNT = 20000;
  for (let i = 0; i < BULK_COUNT; i += 1) {
    writer.appendValue(bulkEntry, "double", i / 3, timestamp);
    timestamp += 20000;
  }

  writer.finishEntry(bulkEntry, timestamp);
  for (const entry of entries) {
    writer.finishEntry(entry.entryId, timestamp);
  }

  await writer.flush();
  const reportedBytes = writer.bytesWritten;
  const reportedRecords = writer.recordCount;
  const reportedEntries = writer.entryCount;
  await writer.close();

  // --- read back -----------------------------------------------------------
  const onDiskBytes = fs.statSync(outPath).size;
  assert.strictEqual(onDiskBytes, reportedBytes, "bytesWritten must match the file size");

  const { extraHeader, records } = readRecords(outPath);
  assert.strictEqual(extraHeader, EXTRA_HEADER, "extra header round-trip");
  assert.strictEqual(records.length, reportedRecords, "recordCount must match records on disk");

  const starts = new Map();
  let controlCount = 0;
  let finishCount = 0;
  let metadataCount = 0;
  const valuesByEntry = new Map();

  for (const record of records) {
    if (record.entryId === 0) {
      controlCount += 1;
      const control = parseControl(record.payload);
      if (control.control === "start") {
        starts.set(control.entryId, control);
      } else if (control.control === "finish") {
        finishCount += 1;
      } else {
        metadataCount += 1;
        assert.strictEqual(control.metadata, '{"revised":true}');
      }
      continue;
    }
    const start = starts.get(record.entryId);
    assert.ok(start, `value record for unknown entry ${record.entryId}`);
    if (!valuesByEntry.has(record.entryId)) valuesByEntry.set(record.entryId, []);
    valuesByEntry.get(record.entryId).push(decodeValue(record.payload, start.type));
  }

  assert.strictEqual(starts.size, reportedEntries, "entryCount must match Start records");
  assert.strictEqual(finishCount, entries.length + 1, "one Finish per entry");
  assert.strictEqual(metadataCount, 1, "one SetMetadata record");

  for (const entry of entries) {
    const start = starts.get(entry.entryId);
    assert.strictEqual(start.name, entry.name);
    assert.strictEqual(start.type, entry.type);

    const decoded = valuesByEntry.get(entry.entryId);
    const wanted = entry.values.map((value) => expected(entry.type, value));
    // The first entry has one extra boolean written at timestamp 7.
    const actual = entry.entryId === entries[0].entryId ? decoded.slice(1) : decoded;
    assert.deepStrictEqual(actual, wanted, `value round-trip failed for ${entry.name}`);
  }

  // Direct encodeValue() spot checks for the fiddly cases.
  assert.strictEqual(encodeValue("boolean[]", []).length, 0, "empty boolean[] is zero bytes");
  assert.strictEqual(encodeValue("string", "").length, 0, "empty string has no length prefix");
  assert.deepStrictEqual(
    encodeValue("string[]", []),
    Buffer.from([0, 0, 0, 0]),
    "empty string[] is a zero count",
  );
  assert.deepStrictEqual(
    encodeValue("string", "abc"),
    Buffer.from("abc", "utf8"),
    "string values carry no length prefix",
  );
  assert.deepStrictEqual(
    encodeValue("int64", -9007199254740993n),
    Buffer.from([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xdf, 0xff]),
    "BigInt int64 beyond 2^53",
  );
  assert.deepStrictEqual(
    encodeValue("raw", new Uint8Array([0xde, 0xad])),
    Buffer.from([0xde, 0xad]),
    "raw bytes pass through verbatim",
  );

  // Header bitfield packing: length-minus-one, minimal lengths.
  const smallTsRecord = records.find((r) => r.entryId !== 0 && r.tsLength === 1);
  assert.ok(smallTsRecord, "expected a record with a 1-byte timestamp");
  assert.strictEqual(smallTsRecord.timestampUs, 7n);
  assert.ok(
    records.some((r) => r.tsLength === 7),
    "expected 7-byte timestamps for epoch-microsecond values",
  );
  assert.ok(
    records.every((r) => r.idLength === 1),
    "entry ids under 256 must use a 1-byte id field",
  );

  const bigTs = records.reduce((max, r) => (r.timestampUs > max ? r.timestampUs : max), 0n);
  assert.ok(bigTs > 0xffffffffn, "expected timestamps beyond 32 bits");

  const backpressure = await runRegressionChecks();

  const summary = {
    file: outPath,
    bytes: onDiskBytes,
    records: records.length,
    controlRecords: controlCount,
    valueRecords: records.length - controlCount,
    entries: starts.size,
    types: CASES.map(([, type]) => type),
    maxTimestampUs: bigTs.toString(),
    bulkSamples: BULK_COUNT,
    regressions: {
      unknownArrayTypeThrows: true,
      streamErrorSurfacesToCaller: true,
      postCloseAppendThrows: true,
      timestampWidthTypeIndependent: true,
      backpressure: {
        healthySamples: backpressure.healthySamples,
        healthyPeakBacklogBytes: backpressure.peakBacklog,
        burstPeakBacklogBytes: backpressure.burstPeak,
        burstAcceptedBeforeFailing: backpressure.burstAccepted,
        ceilingBytes: MAX_BACKLOG_BYTES,
      },
    },
  };

  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
  process.stdout.write("wpilog-writer check: OK\n");
}

main().catch((error) => {
  process.stderr.write(`wpilog-writer check: FAILED\n${error && error.stack ? error.stack : error}\n`);
  process.exit(1);
});
