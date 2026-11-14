const { EventEmitter } = require("events");
const WebSocket = require("ws");
const { decodeMulti, encode } = require("@msgpack/msgpack");

// NT 4.0 only. Requesting v4.1 would move RTT onto a second socket, which buys us
// nothing here and costs another connection against the robot.
const PROTOCOL_V4_0 = "networktables.first.wpi.edu";
const RECONNECT_DELAYS_MS = [1000, 2000, 4000, 5000];
const RTT_PERIOD_MS = 1000;
const RTT_TOPIC_ID = -1;
const RTT_TYPE_NUM = 2;

// Only used to sanity check decoding. The authoritative type string for the log is
// the one carried by the announce message (it is what holds "struct:Pose2d", "json", ...).
// Names here match the strings NT4 uses in announce messages.
const TYPE_NUM_NAMES = {
  0: "boolean",
  1: "double",
  2: "int",
  3: "float",
  4: "string",
  5: "raw",
  16: "boolean[]",
  17: "double[]",
  18: "int[]",
  19: "float[]",
  20: "string[]",
};

let clientCounter = 0;

/**
 * A dedicated NT4 client for the recorder. It subscribes to the empty-string prefix with
 * `all: true`, so every value change of every topic on the server is delivered, and it owns
 * its own socket so the live driver dashboard's client is left completely alone.
 */
class Nt4RecordClient extends EventEmitter {
  constructor({ host, port } = {}) {
    super();
    this.host = typeof host === "string" ? host.trim() : "";
    this.port = Number.isFinite(port) ? Number(port) : 5810;
    this.clientId = `pwrup-recorder-${process.pid}-${++clientCounter}`;

    this.socket = null;
    this.topics = new Map();
    this.closedIntentionally = false;
    this.reconnectAttempt = 0;
    this.reconnectHandle = null;
    this.rttHandle = null;
    this.subUid = 1;

    this.lastRttSentUs = 0;
    this.bestRttUs = -1;
    this.serverTimeOffsetUs = 0;

    this.valueCount = 0;
    this.droppedValueCount = 0;
    this.typeMismatchCount = 0;
    this.decodeErrorCount = 0;
    // A downstream consumer throwing is a consumer bug, NOT a decode failure. Keeping the
    // two apart matters: decodeErrorCount is what tells us the wire format went wrong.
    this.listenerErrorCount = 0;
  }

  get connected() {
    return this.socket !== null && this.socket.readyState === WebSocket.OPEN;
  }

  get topicCount() {
    return this.topics.size;
  }

  getAnnouncedTopics() {
    const list = [];
    this.topics.forEach((topic) => {
      // Copy the properties: nt-recorder serializes them into log metadata and must not be
      // able to mutate our live view of the topic (nor see it change underneath it).
      list.push({ name: topic.name, type: topic.type, properties: { ...topic.properties } });
    });
    return list;
  }

  getStats() {
    return {
      valueCount: this.valueCount,
      droppedValueCount: this.droppedValueCount,
      typeMismatchCount: this.typeMismatchCount,
      decodeErrorCount: this.decodeErrorCount,
      listenerErrorCount: this.listenerErrorCount,
      bestRttUs: this.bestRttUs,
      serverTimeOffsetUs: this.serverTimeOffsetUs,
    };
  }

  connect() {
    this.closedIntentionally = false;

    if (!this.host) {
      return;
    }

    if (this.socket || this.reconnectHandle) {
      return;
    }

    this.#openSocket();
  }

  close() {
    this.closedIntentionally = true;
    this.#clearReconnect();
    this.#stopRtt();

    const socket = this.socket;
    this.socket = null;
    this.topics.clear();

    if (!socket) return;

    socket.removeAllListeners();
    // ws throws if it emits 'error' with no listener, and tearing down a half-open socket
    // routinely does exactly that. That must never reach the Electron main process.
    socket.on("error", () => {});
    try {
      if (socket.readyState === WebSocket.CONNECTING) {
        socket.terminate();
      } else {
        socket.close();
      }
    } catch {
      // socket already dead; nothing to do
    }
  }

  #openSocket() {
    const url = `ws://${this.host}:${this.port}/nt/${this.clientId}`;
    let socket;

    try {
      socket = new WebSocket(url, [PROTOCOL_V4_0], { handshakeTimeout: 5000 });
    } catch (error) {
      this.#emitError(error);
      this.#scheduleReconnect();
      return;
    }

    this.socket = socket;
    socket.binaryType = "nodebuffer";

    socket.on("open", () => {
      if (this.socket !== socket) return;
      // The server reassigns topic ids on every connection, so nothing from the previous
      // session is valid any more. The clock estimate is just as stale: if the robot
      // rebooted, its uptime clock restarted, and keeping the old best-RTT offset would
      // stamp everything we generate hundreds of seconds into an epoch that no longer
      // exists. Re-measure from scratch.
      this.topics.clear();
      this.bestRttUs = -1;
      this.serverTimeOffsetUs = 0;
      this.reconnectAttempt = 0;
      this.#sendSubscribeAll();
      this.#startRtt();
      this.#safeEmit("open");
    });

    socket.on("message", (data, isBinary) => {
      if (this.socket !== socket) return;
      if (isBinary) {
        this.#handleBinaryFrame(data);
      } else {
        this.#handleTextFrame(data);
      }
    });

    socket.on("error", (error) => {
      if (this.socket !== socket) return;
      this.#emitError(error);
    });

    socket.on("close", (code, reason) => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.topics.clear();
      this.#stopRtt();
      socket.removeAllListeners();
      socket.on("error", () => {});

      const reasonText = reason && reason.length ? reason.toString() : `closed (code ${code})`;
      // Reconnect is scheduled BEFORE delivery so a throwing 'close' consumer cannot leave
      // the client permanently disconnected mid-match.
      this.#scheduleReconnect();
      this.#safeEmit("close", reasonText);
    });
  }

  #scheduleReconnect() {
    if (this.closedIntentionally || this.reconnectHandle || !this.host) {
      return;
    }

    const index = Math.min(this.reconnectAttempt, RECONNECT_DELAYS_MS.length - 1);
    const delay = RECONNECT_DELAYS_MS[index];
    this.reconnectAttempt += 1;

    this.reconnectHandle = setTimeout(() => {
      this.reconnectHandle = null;
      if (this.closedIntentionally || this.socket) return;
      this.#openSocket();
    }, delay);
    this.reconnectHandle.unref?.();
  }

  #clearReconnect() {
    if (this.reconnectHandle) {
      clearTimeout(this.reconnectHandle);
      this.reconnectHandle = null;
    }
    this.reconnectAttempt = 0;
  }

  #sendSubscribeAll() {
    // The empty-string prefix matches every topic on the server. `all: true` delivers every
    // value change rather than only the latest, which is the whole point of a recording.
    this.#sendTextFrame({
      method: "subscribe",
      params: {
        topics: [""],
        subuid: this.subUid++,
        options: { prefix: true, all: true, topicsonly: false },
      },
    });
  }

  #sendTextFrame(message) {
    if (!this.connected) return;
    try {
      this.socket.send(JSON.stringify([message]));
    } catch (error) {
      this.#emitError(error);
    }
  }

  #startRtt() {
    this.#stopRtt();
    this.rttHandle = setInterval(() => this.#sendRtt(), RTT_PERIOD_MS);
    this.rttHandle.unref?.();
    this.#sendRtt();
  }

  #stopRtt() {
    if (this.rttHandle) {
      clearInterval(this.rttHandle);
      this.rttHandle = null;
    }
  }

  #sendRtt() {
    if (!this.connected) return;
    const nowUs = Math.round(performance.timeOrigin * 1000 + performance.now() * 1000);
    this.lastRttSentUs = nowUs;
    try {
      this.socket.send(encode([RTT_TOPIC_ID, 0, RTT_TYPE_NUM, nowUs]));
    } catch (error) {
      this.#emitError(error);
    }
  }

  #handleRtt(serverTimeUs, echoedClientTimeUs) {
    const sentUs = Number(echoedClientTimeUs) || this.lastRttSentUs;
    if (!sentUs) return;
    const nowUs = Math.round(performance.timeOrigin * 1000 + performance.now() * 1000);
    const rttUs = nowUs - sentUs;
    if (rttUs < 0) return;
    if (this.bestRttUs === -1 || rttUs < this.bestRttUs) {
      this.bestRttUs = rttUs;
      this.serverTimeOffsetUs = nowUs - rttUs / 2 - Number(serverTimeUs);
    }
  }

  #handleTextFrame(data) {
    let messages;
    try {
      messages = JSON.parse(typeof data === "string" ? data : data.toString("utf8"));
    } catch (error) {
      this.decodeErrorCount += 1;
      this.#emitError(error);
      return;
    }

    if (!Array.isArray(messages)) return;

    messages.forEach((message) => {
      if (!message || typeof message !== "object") return;
      const params = message.params ?? {};
      // Per message, so one malformed entry cannot cost us the rest of the frame.
      try {
        switch (message.method) {
          case "announce":
            this.#handleAnnounce(params);
            break;
          case "unannounce":
            this.#handleUnannounce(params);
            break;
          case "properties":
            this.#handleProperties(params);
            break;
          default:
            // Nothing else is meaningful to a pure subscriber.
            break;
        }
      } catch (error) {
        this.decodeErrorCount += 1;
        this.#emitError(error);
      }
    });
  }

  #handleAnnounce(params) {
    if (typeof params.id !== "number" || typeof params.name !== "string") return;

    const properties =
      params.properties && typeof params.properties === "object" ? { ...params.properties } : {};

    const topic = {
      id: params.id,
      name: params.name,
      type: typeof params.type === "string" ? params.type : "raw",
      properties,
    };
    this.topics.set(topic.id, topic);
    this.#safeEmit("announce", { ...topic, properties: { ...properties } });
  }

  #handleUnannounce(params) {
    if (typeof params.id !== "number") return;
    const topic = this.topics.get(params.id);
    this.topics.delete(params.id);
    this.#safeEmit("unannounce", {
      id: params.id,
      name: topic ? topic.name : params.name ?? null,
    });
  }

  #handleProperties(params) {
    if (typeof params.name !== "string") return;
    if (!params.update || typeof params.update !== "object") return;

    this.topics.forEach((topic) => {
      if (topic.name !== params.name) return;

      // NT4: a null value in a properties update means DELETE THIS PROPERTY. A plain spread
      // would store the null literally, and nt-recorder serializes topic.properties verbatim
      // into the WPILOG entry metadata -- so the recorded log would misstate the topic.
      const next = { ...topic.properties };
      for (const [key, value] of Object.entries(params.update)) {
        if (value === null) {
          delete next[key];
        } else {
          next[key] = value;
        }
      }
      topic.properties = next;
      // AdvantageKit sets a topic's "unit" property immediately AFTER publishing it, so
      // this message always trails the announce. A consumer that only reads properties at
      // announce time loses every unit on the robot — emit the change so the log can be
      // updated in place.
      this.#safeEmit("properties", { name: topic.name, properties: { ...next } });
    });
  }

  #handleBinaryFrame(data) {
    // A single websocket frame routinely carries MANY concatenated msgpack values.
    // decode() would silently return only the first one and drop the rest.
    //
    // Decode the WHOLE frame first, into an array. Delivering from inside the decodeMulti
    // generator would couple the two: a downstream listener throwing aborts the generator,
    // silently discarding every remaining value in the frame (and miscounting the loss as a
    // decode error). Draining first means delivery cannot cost us samples.
    const messages = [];
    try {
      for (const message of decodeMulti(this.#asBytes(data))) {
        messages.push(message);
      }
    } catch (error) {
      // Genuine wire corruption. Whatever decoded cleanly ahead of it is still good, so it
      // is delivered below rather than thrown away with the bad tail.
      this.decodeErrorCount += 1;
      this.#emitError(error);
    }

    for (const message of messages) {
      this.#handleValueMessage(message);
    }
  }

  #handleValueMessage(message) {
    if (!Array.isArray(message) || message.length !== 4) {
      this.decodeErrorCount += 1;
      return;
    }

    const topicId = Number(message[0]);
    const timestampUs = Number(message[1]);
    const typeNum = Number(message[2]);
    const value = message[3];

    if (topicId === RTT_TOPIC_ID) {
      this.#handleRtt(timestampUs, value);
      return;
    }

    const topic = this.topics.get(topicId);
    if (!topic) {
      // Never emit a value we cannot name; the log would get a garbage channel.
      this.droppedValueCount += 1;
      return;
    }

    const expected = TYPE_NUM_NAMES[typeNum];
    if (expected && !this.#typesAgree(expected, topic.type)) {
      this.typeMismatchCount += 1;
    }

    this.valueCount += 1;
    this.#safeEmit("value", {
      id: topicId,
      name: topic.name,
      type: topic.type,
      timestampUs,
      value,
    });
  }

  #typesAgree(typeNumName, announcedType) {
    if (typeNumName === announcedType) return true;
    if (typeNumName === "raw") {
      // Everything that travels as binary announces itself more specifically.
      return (
        announcedType === "msgpack" ||
        announcedType === "protobuf" ||
        announcedType === "rpc" ||
        announcedType === "structschema" ||
        announcedType.startsWith("struct:") ||
        announcedType.startsWith("proto:") ||
        announcedType.startsWith("photonstruct:")
      );
    }
    if (typeNumName === "string") return announcedType === "json";
    if (typeNumName === "int") return announcedType === "int64";
    if (typeNumName === "int[]") return announcedType === "int64[]";
    return false;
  }

  #asBytes(data) {
    if (Buffer.isBuffer(data)) return data;
    if (Array.isArray(data)) return Buffer.concat(data);
    if (data instanceof ArrayBuffer) return Buffer.from(data);
    if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
    return Buffer.from(data);
  }

  /**
   * Deliver an event to each listener in its own try/catch.
   *
   * Everything this client emits is emitted from inside ws's socket callbacks, so a throw
   * that escapes lands in `Receiver.receiverOnMessage` with nothing above it but the event
   * loop -- an uncaught exception in the Electron main process. `main.cjs`'s
   * broadcastToWindows throws "Object has been destroyed" whenever a dashboard window is
   * closed while a broadcast is in flight, which happens routinely, so this is not
   * hypothetical.
   *
   * Isolating listeners individually (rather than one try around `emit`) also means one bad
   * consumer cannot cost a well-behaved consumer its samples: EventEmitter.emit() abandons
   * the remaining listeners as soon as one throws.
   *
   * rawListeners() (not listeners()) is deliberate: it returns the once() wrappers, so
   * one-shot listeners still unregister themselves when invoked. It also returns a copy, so
   * listeners added or removed during dispatch cannot corrupt the iteration.
   */
  #safeEmit(event, payload) {
    const listeners = this.rawListeners(event);
    for (const listener of listeners) {
      try {
        if (payload === undefined) {
          listener.call(this);
        } else {
          listener.call(this, payload);
        }
      } catch (error) {
        this.listenerErrorCount += 1;
        this.#emitError(error);
      }
    }
  }

  #emitError(error) {
    const wrapped = error instanceof Error ? error : new Error(String(error));
    const listeners = this.rawListeners("error");

    // An 'error' event with no listener throws out of EventEmitter itself, which would take
    // down the Electron main process.
    if (listeners.length === 0) {
      console.warn("[nt4-record-client]", wrapped.message);
      return;
    }

    for (const listener of listeners) {
      try {
        listener.call(this, wrapped);
      } catch (nested) {
        // Terminal on purpose: this is the bottom of the error path. Routing back through
        // #emitError (or #safeEmit) would re-enter the very listener chain that just threw,
        // and that second throw would escape into ws's message dispatch. Log and stop.
        this.listenerErrorCount += 1;
        const message = nested instanceof Error ? nested.message : String(nested);
        console.warn("[nt4-record-client] error listener threw:", message);
      }
    }
  }
}

module.exports = {
  Nt4RecordClient,
  TYPE_NUM_NAMES,
};
