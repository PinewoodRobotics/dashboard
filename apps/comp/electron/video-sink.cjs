const path = require("path");
const fs = require("fs");
const { EventEmitter } = require("events");
const { promises: fsp } = require("fs");

/**
 * Append-only writer for the field-camera webm chunks that stream in from the
 * renderer's MediaRecorder. Deliberately dumb: it owns a write stream, counts
 * bytes, and surfaces stream errors instead of throwing them at the event loop.
 *
 * "Append-only" is meant literally, including across open() calls. The renderer
 * may tear its camera down and bring it back mid-session (a tab switch used to do
 * exactly that), which re-opens this sink on the same path; opening with flags "w"
 * would silently destroy everything captured so far. So open() always extends and
 * seeds bytesWritten from what is already on disk. NtRecorder guarantees the path
 * is unused when a session starts, so there is nothing stale to append to.
 */
class VideoSink extends EventEmitter {
  constructor(filePath) {
    super();
    this.filePath = filePath;
    this.stream = null;
    this.isOpen = false;
    this.lastError = null;
    this.pendingBytes = 0;
  }

  get bytesWritten() {
    return this.pendingBytes;
  }

  async open() {
    if (this.isOpen) return;

    await fsp.mkdir(path.dirname(this.filePath), { recursive: true });

    // Whatever is already on disk stays there and still counts as ours.
    const existingBytes = await this.#existingSize();

    await new Promise((resolve, reject) => {
      const stream = fs.createWriteStream(this.filePath, { flags: "a" });
      const onError = (error) => {
        stream.removeListener("open", onOpen);
        reject(error);
      };
      const onOpen = () => {
        stream.removeListener("error", onError);
        this.stream = stream;
        this.isOpen = true;
        this.lastError = null;
        this.pendingBytes = existingBytes;
        stream.on("error", (error) => this.#onStreamError(error));
        resolve();
      };
      stream.once("error", onError);
      stream.once("open", onOpen);
    });
  }

  /**
   * @param {Uint8Array | Buffer | ArrayBuffer} chunk
   */
  async append(chunk) {
    if (!this.isOpen || !this.stream) {
      throw new Error("Video sink is not open.");
    }
    if (this.lastError) {
      throw this.lastError;
    }

    const buffer = toBuffer(chunk);
    if (buffer.length === 0) return;

    const flushed = this.stream.write(buffer);
    this.pendingBytes += buffer.length;

    if (!flushed) {
      await this.#waitForDrain();
    }
  }

  async close() {
    const stream = this.stream;
    this.isOpen = false;
    this.stream = null;

    if (!stream) return;

    await new Promise((resolve) => {
      stream.once("close", resolve);
      stream.once("error", () => resolve());
      stream.end();
    });
  }

  async #existingSize() {
    try {
      const stat = await fsp.stat(this.filePath);
      return stat.isFile() ? stat.size : 0;
    } catch {
      return 0;
    }
  }

  #waitForDrain() {
    return new Promise((resolve, reject) => {
      const stream = this.stream;
      if (!stream) {
        resolve();
        return;
      }
      const onDrain = () => {
        stream.removeListener("error", onError);
        resolve();
      };
      const onError = (error) => {
        stream.removeListener("drain", onDrain);
        reject(error);
      };
      stream.once("drain", onDrain);
      stream.once("error", onError);
    });
  }

  #onStreamError(error) {
    this.lastError = error instanceof Error ? error : new Error(String(error));
    this.isOpen = false;
    this.emit("error", this.lastError);
  }
}

function toBuffer(chunk) {
  if (Buffer.isBuffer(chunk)) return chunk;
  if (chunk instanceof ArrayBuffer) return Buffer.from(new Uint8Array(chunk));
  if (ArrayBuffer.isView(chunk)) {
    return Buffer.from(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
  }
  if (Array.isArray(chunk)) return Buffer.from(chunk);
  throw new Error("Unsupported video chunk type.");
}

module.exports = {
  VideoSink,
};
