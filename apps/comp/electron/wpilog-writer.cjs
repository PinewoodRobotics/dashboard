const fs = require("fs");
const fsp = require("fs/promises");
const path = require("path");

const MAGIC = Buffer.from("WPILOG", "ascii");
const VERSION = 0x0100;
const FLUSH_THRESHOLD_BYTES = 64 * 1024;

/**
 * Hard ceiling on bytes buffered in this process while the OS write stream is saturated.
 * On a slow volume (USB stick, network share) the stream can absorb far less than NT
 * produces; growing forever would OOM the main process mid-match. Failing the session at a
 * fixed backlog loses the recording loudly instead of taking the driver station down.
 */
// Ceiling on bytes buffered for a disk that cannot keep up. Real-robot load (561 channels,
// ~7,000 records/s) peaks at ~75 KB of backlog on a healthy disk, so this is ~100x headroom
// while keeping the main process's footprint during a backlog event modest — the observed
// RSS spike runs several times the accounted backlog, so a larger ceiling buys nothing but
// a bigger crater.
const MAX_BACKLOG_BYTES = 8 * 1024 * 1024;
// How long close() waits for a stream to drain before declaring the volume dead. Generous
// for a slow USB stick, short enough that quitting the app never feels hung.
const CLOSE_TIMEOUT_MS = 5000;

const CONTROL_ENTRY_ID = 0;
const CONTROL_START = 0;
const CONTROL_FINISH = 1;
const CONTROL_SET_METADATA = 2;

const MAX_INT64 = 0x7fffffffffffffffn;
const MIN_INT64 = -0x8000000000000000n;

/**
 * Minimum number of bytes needed to hold an unsigned value little-endian.
 * Accepts a JS number (integral) or a BigInt, and MUST agree between the two: the encoded
 * record header may not depend on which JS type the caller happened to hand us.
 *
 * The thresholds are exact powers of 256 (every one of them is exactly representable as a
 * double, unlike 2^56-1), compared with `<`, so the number path covers the full 7-byte range
 * instead of stopping at 2^53-1.
 */
function unsignedByteLength(value) {
  if (typeof value === "bigint") {
    let remaining = value >> 8n;
    let length = 1;
    while (remaining > 0n) {
      remaining >>= 8n;
      length += 1;
    }
    return length;
  }

  if (value < 0x100) return 1;
  if (value < 0x10000) return 2;
  if (value < 0x1000000) return 3;
  if (value < 0x100000000) return 4;
  if (value < 0x10000000000) return 5;
  if (value < 0x1000000000000) return 6;
  if (value < 0x100000000000000) return 7;
  return 8;
}

function writeUnsignedLE(target, offset, value, length) {
  if (typeof value === "bigint") {
    let remaining = value;
    for (let i = 0; i < length; i += 1) {
      target[offset + i] = Number(remaining & 0xffn);
      remaining >>= 8n;
    }
    return;
  }

  // Deliberately not using bitwise ops: they coerce to int32 and would corrupt
  // timestamps above 2^31.
  let remaining = value;
  for (let i = 0; i < length; i += 1) {
    target[offset + i] = remaining % 256;
    remaining = Math.floor(remaining / 256);
  }
}

/** Normalize a timestamp argument to a non-negative number or BigInt. */
function normalizeTimestamp(timestampUs) {
  if (typeof timestampUs === "bigint") {
    return timestampUs < 0n ? 0n : timestampUs;
  }
  if (typeof timestampUs !== "number" || !Number.isFinite(timestampUs)) {
    return 0;
  }
  const truncated = Math.trunc(timestampUs);
  return truncated < 0 ? 0 : truncated;
}

function toBigInt64(value) {
  let result;
  if (typeof value === "bigint") {
    result = value;
  } else if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new TypeError("int64 value must be finite");
    }
    result = BigInt(Math.trunc(value));
  } else if (typeof value === "boolean") {
    result = value ? 1n : 0n;
  } else if (typeof value === "string" && value.trim() !== "") {
    result = BigInt(value.trim());
  } else {
    throw new TypeError(`cannot encode ${typeof value} as int64`);
  }

  if (result > MAX_INT64 || result < MIN_INT64) {
    throw new RangeError(`int64 value out of range: ${result}`);
  }
  return result;
}

function toNumber(value) {
  if (typeof value === "number") return value;
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "boolean") return value ? 1 : 0;
  throw new TypeError(`cannot encode ${typeof value} as a number`);
}

function toElementArray(value, type) {
  if (Array.isArray(value)) return value;
  if (ArrayBuffer.isView(value) && !(value instanceof DataView)) return Array.from(value);
  if (value === null || value === undefined) return [];
  throw new TypeError(`${type} value must be an array`);
}

/** Copy any byte-ish input into a standalone Buffer (never aliases the caller's memory). */
function toRawBytes(value, type) {
  if (Buffer.isBuffer(value)) return Buffer.from(value);
  if (value instanceof Uint8Array) return Buffer.from(value);
  if (value instanceof ArrayBuffer) return Buffer.from(new Uint8Array(value));
  if (ArrayBuffer.isView(value)) {
    return Buffer.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  }
  if (Array.isArray(value)) {
    // A plain Array reaching the raw-bytes fallback means the type string is an array type
    // this writer does not recognize (e.g. an unmapped NT4 "int[]"). Buffer.from() would
    // happily coerce every element to a single byte and destroy the data with no error at
    // all -- and nobody would find out until they tried to fit a model off the log months
    // later. Silent truncation is never an acceptable failure mode here.
    throw new TypeError(
      `cannot encode an Array as raw bytes for type "${type}": unrecognized array type ` +
        "(map it to boolean[]/int64[]/float[]/double[]/string[] before writing)",
    );
  }
  if (typeof value === "string") return Buffer.from(value, "utf8");
  if (value === null || value === undefined) return Buffer.alloc(0);
  throw new TypeError(`cannot encode ${typeof value} as raw bytes for type "${type}"`);
}

/**
 * Encode a single NT value into its WPILOG payload bytes.
 * Unknown types (raw, msgpack, protobuf, struct:..., structschema, ...) pass through verbatim.
 */
function encodeValue(type, value) {
  switch (type) {
    case "boolean":
      return Buffer.from([value ? 1 : 0]);

    case "int64": {
      const out = Buffer.allocUnsafe(8);
      out.writeBigInt64LE(toBigInt64(value), 0);
      return out;
    }

    case "float": {
      const out = Buffer.allocUnsafe(4);
      out.writeFloatLE(toNumber(value), 0);
      return out;
    }

    case "double": {
      const out = Buffer.allocUnsafe(8);
      out.writeDoubleLE(toNumber(value), 0);
      return out;
    }

    case "string":
    case "json":
      return Buffer.from(typeof value === "string" ? value : String(value ?? ""), "utf8");

    case "boolean[]": {
      const items = toElementArray(value, type);
      const out = Buffer.allocUnsafe(items.length);
      for (let i = 0; i < items.length; i += 1) {
        out[i] = items[i] ? 1 : 0;
      }
      return out;
    }

    case "int64[]": {
      const items = toElementArray(value, type);
      const out = Buffer.allocUnsafe(items.length * 8);
      for (let i = 0; i < items.length; i += 1) {
        out.writeBigInt64LE(toBigInt64(items[i]), i * 8);
      }
      return out;
    }

    case "float[]": {
      const items = toElementArray(value, type);
      const out = Buffer.allocUnsafe(items.length * 4);
      for (let i = 0; i < items.length; i += 1) {
        out.writeFloatLE(toNumber(items[i]), i * 4);
      }
      return out;
    }

    case "double[]": {
      const items = toElementArray(value, type);
      const out = Buffer.allocUnsafe(items.length * 8);
      for (let i = 0; i < items.length; i += 1) {
        out.writeDoubleLE(toNumber(items[i]), i * 8);
      }
      return out;
    }

    case "string[]": {
      const items = toElementArray(value, type);
      const encoded = items.map((item) =>
        Buffer.from(typeof item === "string" ? item : String(item ?? ""), "utf8"),
      );
      let size = 4;
      for (const item of encoded) {
        size += 4 + item.length;
      }
      const out = Buffer.allocUnsafe(size);
      out.writeUInt32LE(encoded.length, 0);
      let offset = 4;
      for (const item of encoded) {
        out.writeUInt32LE(item.length, offset);
        offset += 4;
        item.copy(out, offset);
        offset += item.length;
      }
      return out;
    }

    default:
      return toRawBytes(value, type);
  }
}

/** u32-length-prefixed UTF-8, as used inside control-record payloads. */
function encodePrefixedString(text) {
  const bytes = Buffer.from(typeof text === "string" ? text : String(text ?? ""), "utf8");
  const out = Buffer.allocUnsafe(4 + bytes.length);
  out.writeUInt32LE(bytes.length, 0);
  bytes.copy(out, 4);
  return out;
}

/**
 * Byte-exact WPILOG v1.0 writer.
 *
 * Records are accumulated in memory and handed to the write stream in ~64 KB chunks so a
 * 50 Hz x 500-topic NT stream does not issue a syscall per sample.
 */
class WpilogWriter {
  #drainListener;

  constructor(filePath, extraHeader = "") {
    this.filePath = filePath;
    this.extraHeader = extraHeader ?? "";
    this.stream = null;
    this.isOpen = false;
    this.isClosed = false;
    this.streamError = null;

    this.nextEntryId = 1;
    this.startedEntries = 0;
    this.records = 0;
    this.totalBytes = 0;

    this.pending = [];
    this.pendingBytes = 0;
    // True between a stream.write() that returned false and its 'drain'. While set we stop
    // issuing writes so the stream's own buffer cannot grow without bound.
    this.draining = false;
    this.#drainListener = () => this.#onDrain();
  }

  get bytesWritten() {
    return this.totalBytes;
  }

  get entryCount() {
    return this.startedEntries;
  }

  get recordCount() {
    return this.records;
  }

  /**
   * Bytes not yet accepted by the OS: our own pending buffer plus whatever the stream is
   * still holding. The recorder surfaces this so a slow disk is visible before it fails.
   */
  get backlogBytes() {
    const streamBacklog = this.stream ? this.stream.writableLength : 0;
    return this.pendingBytes + streamBacklog;
  }

  /** Ceiling at which the writer fails the session rather than growing forever. */
  get maxBacklogBytes() {
    return MAX_BACKLOG_BYTES;
  }

  /** First stream-level error seen, or null. Callers use it for disk-failure handling. */
  get lastError() {
    return this.streamError;
  }

  async open() {
    if (this.isOpen) {
      throw new Error("WpilogWriter is already open");
    }

    await fsp.mkdir(path.dirname(this.filePath), { recursive: true });

    const stream = fs.createWriteStream(this.filePath, { flags: "w" });
    await new Promise((resolve, reject) => {
      const onError = (error) => {
        stream.off("open", onOpen);
        reject(error);
      };
      const onOpen = () => {
        stream.off("error", onError);
        resolve();
      };
      stream.once("error", onError);
      stream.once("open", onOpen);
    });

    stream.on("error", (error) => this.#failStream(error));

    this.stream = stream;
    this.isOpen = true;

    const extraBytes = Buffer.from(this.extraHeader, "utf8");
    const header = Buffer.allocUnsafe(MAGIC.length + 2 + 4 + extraBytes.length);
    MAGIC.copy(header, 0);
    header.writeUInt16LE(VERSION, MAGIC.length);
    header.writeUInt32LE(extraBytes.length, MAGIC.length + 2);
    extraBytes.copy(header, MAGIC.length + 6);
    this.#enqueue(header);
  }

  startEntry(name, type, metadata, timestampUs) {
    this.#assertWritable();

    const entryId = this.nextEntryId;
    const head = Buffer.allocUnsafe(5);
    head.writeUInt8(CONTROL_START, 0);
    head.writeUInt32LE(entryId, 1);

    this.#writeRecord(
      CONTROL_ENTRY_ID,
      Buffer.concat([
        head,
        encodePrefixedString(name),
        encodePrefixedString(type),
        encodePrefixedString(metadata ?? ""),
      ]),
      timestampUs,
    );

    // Commit the id only once the Start record was actually accepted, so a rejected write
    // cannot burn an entry id or inflate entryCount.
    this.nextEntryId += 1;
    this.startedEntries += 1;
    return entryId;
  }

  finishEntry(entryId, timestampUs) {
    const payload = Buffer.allocUnsafe(5);
    payload.writeUInt8(CONTROL_FINISH, 0);
    payload.writeUInt32LE(entryId, 1);
    this.#writeRecord(CONTROL_ENTRY_ID, payload, timestampUs);
  }

  setMetadata(entryId, metadata, timestampUs) {
    const head = Buffer.allocUnsafe(5);
    head.writeUInt8(CONTROL_SET_METADATA, 0);
    head.writeUInt32LE(entryId, 1);
    this.#writeRecord(
      CONTROL_ENTRY_ID,
      Buffer.concat([head, encodePrefixedString(metadata ?? "")]),
      timestampUs,
    );
  }

  appendValue(entryId, type, value, timestampUs) {
    this.#writeRecord(entryId, encodeValue(type, value), timestampUs);
  }

  async flush() {
    if (this.streamError) {
      throw this.streamError;
    }
    if (!this.stream || this.isClosed) {
      return;
    }

    while (this.pendingBytes > 0 || this.draining) {
      if (this.streamError) {
        throw this.streamError;
      }
      if (this.draining) {
        await this.#waitForDrain();
        continue;
      }

      const chunk = this.#takePending();
      if (!chunk) {
        break;
      }
      // Await the write callback, not just 'drain': flush() is a durability barrier, and a
      // write that fits under the high-water mark returns true while still in flight.
      await new Promise((resolve, reject) => {
        const stream = this.stream;
        const onError = (error) => {
          stream.off("error", onError);
          reject(this.streamError ?? error);
        };
        stream.once("error", onError);
        const accepted = stream.write(chunk, (error) => {
          stream.off("error", onError);
          if (error) {
            reject(this.streamError ?? error);
          } else {
            resolve();
          }
        });
        if (!accepted) {
          this.#markDraining();
        }
      });
    }

    if (this.streamError) {
      throw this.streamError;
    }
  }

  async close() {
    if (this.isClosed) {
      return;
    }

    const stream = this.stream;
    this.isClosed = true;

    if (!stream) {
      return;
    }

    stream.off("drain", this.#drainListener);
    this.draining = false;

    // If the stream already failed, do not try to push more bytes at it; just end it and
    // let the stored error surface below.
    const chunk = this.streamError ? null : this.#takePending();
    this.pending = [];
    this.pendingBytes = 0;

    // Never reject for any reason other than this.streamError: closing an already-broken
    // stream must still tear it down, and an unhandled rejection here would take the
    // Electron main process with it.
    // ...and never hang. A volume that has stopped responding (an unplugged stick, a dead
    // network share) leaves bytes pinned in the stream's own buffer, and stream.end()'s
    // callback then never fires. Waiting on that forever wedges stop(), which means no
    // sidecar, no new session, and — because quit awaits shutdown — an Electron app that
    // cannot be closed. Bound the wait and destroy the stream instead; whatever was still
    // buffered was never going to reach the disk anyway.
    await new Promise((resolve) => {
      let settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        stream.off("error", onError);
        if (error) this.#failStream(error);
        resolve();
      };
      const onError = (error) => finish(error);
      const timer = setTimeout(() => {
        finish(
          new Error(
            `Timed out after ${CLOSE_TIMEOUT_MS}ms closing ${this.filePath}: the volume ` +
              `stopped accepting writes. ${stream.writableLength} buffered bytes were lost.`,
          ),
        );
        stream.destroy();
      }, CLOSE_TIMEOUT_MS);
      timer.unref?.();

      stream.once("error", onError);
      try {
        stream.end(chunk ?? undefined, () => finish(null));
      } catch (error) {
        finish(error);
      }
    });

    this.stream = null;

    if (this.streamError) {
      throw this.streamError;
    }
  }

  /**
   * Throw if this writer can no longer durably record. Called before every record so a
   * failed disk or a closed file can never be mistaken for a healthy recording: the
   * recorder's failure path only fires if something actually throws at it.
   */
  #assertWritable() {
    if (this.streamError) {
      throw this.streamError;
    }
    if (this.isClosed) {
      throw new Error(`WpilogWriter is closed: ${this.filePath}`);
    }
    if (!this.isOpen || !this.stream) {
      throw new Error(`WpilogWriter is not open: ${this.filePath}`);
    }
  }

  #writeRecord(entryId, payload, timestampUs) {
    this.#assertWritable();

    const timestamp = normalizeTimestamp(timestampUs);

    const idLength = unsignedByteLength(entryId);
    const sizeLength = unsignedByteLength(payload.length);
    const timestampLength = unsignedByteLength(timestamp);

    if (idLength > 4) {
      throw new RangeError(`entry id does not fit in 4 bytes: ${entryId}`);
    }
    if (sizeLength > 4) {
      throw new RangeError(`payload size does not fit in 4 bytes: ${payload.length}`);
    }
    if (timestampLength > 8) {
      throw new RangeError(`timestamp does not fit in 8 bytes: ${timestamp}`);
    }

    const header = Buffer.allocUnsafe(1 + idLength + sizeLength + timestampLength);
    header[0] = (idLength - 1) | ((sizeLength - 1) << 2) | ((timestampLength - 1) << 4);
    let offset = 1;
    writeUnsignedLE(header, offset, entryId, idLength);
    offset += idLength;
    writeUnsignedLE(header, offset, payload.length, sizeLength);
    offset += sizeLength;
    writeUnsignedLE(header, offset, timestamp, timestampLength);

    this.#enqueue(header);
    this.#enqueue(payload);
    this.records += 1;
  }

  #enqueue(buffer) {
    this.pending.push(buffer);
    this.pendingBytes += buffer.length;
    this.totalBytes += buffer.length;

    if (this.pendingBytes >= FLUSH_THRESHOLD_BYTES) {
      this.#writePending();
    }
  }

  #writePending() {
    if (!this.stream || this.isClosed || this.streamError) {
      return;
    }

    this.#enforceBacklogCeiling();

    if (this.draining) {
      // The stream is saturated: hold the bytes in `pending` rather than piling them into
      // the stream's internal buffer, which has no ceiling of its own.
      return;
    }

    const chunk = this.#takePending();
    if (!chunk) {
      return;
    }

    let accepted;
    try {
      accepted = this.stream.write(chunk);
    } catch (error) {
      this.#failStream(error);
      throw this.streamError;
    }

    if (!accepted) {
      this.#markDraining();
    }
  }

  #markDraining() {
    if (this.draining) {
      return;
    }
    this.draining = true;
    this.stream.once("drain", this.#drainListener);
  }

  #onDrain() {
    this.draining = false;
    if (this.isClosed || this.streamError || !this.stream) {
      return;
    }
    if (this.pendingBytes > 0) {
      try {
        this.#writePending();
      } catch {
        // Already recorded in this.streamError; the next append throws it at the caller.
        // Nothing may throw out of an event handler here or it becomes an uncaught
        // exception in the Electron main process.
      }
    }
  }

  #waitForDrain() {
    return new Promise((resolve, reject) => {
      const stream = this.stream;
      if (!stream) {
        resolve();
        return;
      }
      const cleanup = () => {
        stream.off("drain", onDrain);
        stream.off("error", onError);
      };
      const onDrain = () => {
        cleanup();
        resolve();
      };
      const onError = (error) => {
        cleanup();
        reject(this.streamError ?? error);
      };
      stream.once("drain", onDrain);
      stream.once("error", onError);
    });
  }

  #enforceBacklogCeiling() {
    const backlog = this.backlogBytes;
    if (backlog <= MAX_BACKLOG_BYTES) {
      return;
    }
    this.#failStream(
      new Error(
        `WpilogWriter backlog exceeded ${MAX_BACKLOG_BYTES} bytes (${backlog} buffered) ` +
          `writing ${this.filePath}: the storage device cannot keep up with the NT stream`,
      ),
    );
    throw this.streamError;
  }

  /** Record a fatal stream failure and drop the backlog so it cannot keep growing. */
  #failStream(error) {
    if (!this.streamError) {
      this.streamError = error instanceof Error ? error : new Error(String(error));
    }
    this.pending = [];
    this.pendingBytes = 0;
    this.draining = false;
  }

  #takePending() {
    if (this.pending.length === 0) {
      return null;
    }
    const chunk = this.pending.length === 1 ? this.pending[0] : Buffer.concat(this.pending, this.pendingBytes);
    this.pending = [];
    this.pendingBytes = 0;
    return chunk;
  }
}

module.exports = {
  WpilogWriter,
  encodeValue,
  MAX_BACKLOG_BYTES,
};
