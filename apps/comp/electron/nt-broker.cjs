const { EventEmitter } = require("events");
const { NetworkTables } = require("ntcore-ts-client");

class NtBroker extends EventEmitter {
  constructor() {
    super();
    this.snapshot = null;
    this.client = null;
    this.clientKey = "";
    this.removeConnectionListener = null;
    this.isConnected = false;
    this.nextSubscriptionId = 1;
    this.subscriptions = new Map();
    this.topicEntries = new Map();
    this.publisherEntries = new Map();
    this.watchdogHandle = null;
    this.connectAttemptStart = null;
  }

  initialize(snapshot) {
    this.snapshot = snapshot;
    this.#ensureClient();
  }

  updateSettingsSnapshot(snapshot) {
    this.snapshot = snapshot;
    this.#rebindClient();
  }

  subscribe(sender, params) {
    const subscriptionId = this.nextSubscriptionId++;
    const entry = this.#ensureTopicEntry(params);
    entry.subscribers.set(subscriptionId, sender);
    this.subscriptions.set(subscriptionId, {
      senderId: sender.id,
      topicPath: params.topicPath,
    });

    this.#bindTopicEntry(entry);

    return {
      subscriptionId,
      initial: {
        subscriptionId,
        topicPath: entry.topicPath,
        value: entry.hasValue ? entry.lastValue : entry.defaultValue,
        hasValue: entry.hasValue,
        isConnected: this.isConnected,
      },
    };
  }

  unsubscribe(subscriptionId) {
    const meta = this.subscriptions.get(subscriptionId);
    if (!meta) return;

    this.subscriptions.delete(subscriptionId);
    const entry = this.topicEntries.get(meta.topicPath);
    if (!entry) return;

    entry.subscribers.delete(subscriptionId);

    if (entry.subscribers.size === 0) {
      if (entry.topic && entry.subUid !== null) {
        entry.topic.unsubscribe(entry.subUid);
      }
      this.topicEntries.delete(meta.topicPath);
    }
  }

  cleanupRenderer(senderId) {
    const subscriptionIds = [];
    this.subscriptions.forEach((meta, subscriptionId) => {
      if (meta.senderId === senderId) {
        subscriptionIds.push(subscriptionId);
      }
    });

    subscriptionIds.forEach((subscriptionId) => this.unsubscribe(subscriptionId));
  }

  async publish(params) {
    this.#ensureClient();

    if (!this.client || !this.isConnected) {
      throw new Error("NetworkTables is not connected.");
    }

    const key = params.topicPath;
    let publisher = this.publisherEntries.get(key);

    if (!publisher) {
      publisher = {
        topic: this.client.createTopic(params.topicPath, params.typeInfo, params.defaultValue),
        publishPromise: null,
      };
      this.publisherEntries.set(key, publisher);
    }

    if (!publisher.publishPromise) {
      publisher.publishPromise = publisher.topic.publish().catch((error) => {
        publisher.publishPromise = null;
        throw error;
      });
    }

    await publisher.publishPromise;
    await this.#ensureServerTimeSynced();
    publisher.topic.setValue(params.value);
  }

  // ntcore-ts-client only runs RTT time sync on NT 4.0. On NT 4.1 the server-time offset
  // stays 0, so values are stamped with this process's uptime and the robot's ntcore
  // server silently drops any value older than the topic's current one.
  async #ensureServerTimeSynced() {
    const socket = this.client?.client?.messenger?.socket;
    if (!socket || typeof socket.heartbeat !== "function" || socket.bestRtt !== -1) return;

    socket.heartbeat();
    const deadline = Date.now() + 1000;
    while (socket.bestRtt === -1 && Date.now() < deadline) {
      // eslint-disable-next-line no-await-in-loop
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    if (socket.bestRtt === -1) {
      throw new Error("NetworkTables server time sync timed out.");
    }
  }

  stop() {
    this.topicEntries.forEach((entry) => {
      if (entry.topic && entry.subUid !== null) {
        entry.topic.unsubscribe(entry.subUid);
      }
    });
    this.topicEntries.clear();
    this.publisherEntries.clear();
    this.subscriptions.clear();

    if (this.removeConnectionListener) {
      this.removeConnectionListener();
      this.removeConnectionListener = null;
    }

    this.#stopWatchdog();
    this.client = null;
    this.clientKey = "";
    this.isConnected = false;
  }

  #ensureTopicEntry(params) {
    let entry = this.topicEntries.get(params.topicPath);
    if (!entry) {
      entry = {
        topicPath: params.topicPath,
        typeInfo: params.typeInfo,
        defaultValue: params.defaultValue,
        topic: null,
        subUid: null,
        lastValue: params.defaultValue,
        hasValue: false,
        subscribers: new Map(),
      };
      this.topicEntries.set(params.topicPath, entry);
    }
    return entry;
  }

  #ensureClient() {
    const host = this.snapshot?.settings?.networkTables?.host?.trim() ?? "";
    const port = this.snapshot?.settings?.networkTables?.port ?? 5810;
    const nextKey = host ? `${host}:${port}` : "";

    if (!host) {
      this.#setConnectionState(false);
      return;
    }

    if (this.client && this.clientKey === nextKey) {
      return;
    }

    if (this.removeConnectionListener) {
      this.removeConnectionListener();
      this.removeConnectionListener = null;
    }

    this.client = NetworkTables.getInstanceByURI(host, port);
    this.clientKey = nextKey;
    this.publisherEntries.clear();
    this.removeConnectionListener = this.client.addRobotConnectionListener((connected) => {
      this.#setConnectionState(connected);
    }, true);

    this.#startWatchdog();
  }

  #rebindClient() {
    this.topicEntries.forEach((entry) => {
      if (entry.topic && entry.subUid !== null) {
        entry.topic.unsubscribe(entry.subUid);
      }
      entry.topic = null;
      entry.subUid = null;
    });

    this.publisherEntries.clear();
    this.#stopWatchdog();
    this.client = null;
    this.clientKey = "";

    if (this.removeConnectionListener) {
      this.removeConnectionListener();
      this.removeConnectionListener = null;
    }

    this.#ensureClient();

    this.topicEntries.forEach((entry) => {
      this.#bindTopicEntry(entry);
    });

    if (!this.client) {
      this.#setConnectionState(false);
    }
  }

  #bindTopicEntry(entry) {
    this.#ensureClient();

    if (!this.client || entry.topic) {
      return;
    }

    const topic = this.client.createTopic(entry.topicPath, entry.typeInfo, entry.defaultValue);
    const subUid = topic.subscribe((nextValue) => {
      if (nextValue === null || nextValue === undefined) {
        return;
      }

      entry.lastValue = nextValue;
      entry.hasValue = true;
      this.#broadcastEntry(entry);
    });

    entry.topic = topic;
    entry.subUid = subUid;
  }

  #startWatchdog() {
    this.#stopWatchdog();
    this.connectAttemptStart = null;
    this.watchdogHandle = setInterval(() => {
      if (!this.client) return;
      try {
        const socket = this.client.client?.messenger?.socket;
        if (!socket) return;
        if (this.isConnected) {
          this.connectAttemptStart = null;
          return;
        }
        if (socket.readyState === 0 /* CONNECTING */) {
          if (this.connectAttemptStart === null) {
            this.connectAttemptStart = Date.now();
          } else {
            const timeoutMs = (this.snapshot?.settings?.reconnectTimeoutSeconds ?? 10) * 1000;
            if (Date.now() - this.connectAttemptStart >= timeoutMs) {
              this.connectAttemptStart = null;
              try { socket.close(); } catch { /* ignore */ }
            }
          }
        } else {
          this.connectAttemptStart = null;
        }
      } catch {
        // ignore watchdog errors
      }
    }, 1000);
    this.watchdogHandle.unref?.();
  }

  #stopWatchdog() {
    if (this.watchdogHandle) {
      clearInterval(this.watchdogHandle);
      this.watchdogHandle = null;
    }
    this.connectAttemptStart = null;
  }

  #setConnectionState(connected) {
    if (this.isConnected === connected) {
      this.topicEntries.forEach((entry) => this.#broadcastEntry(entry));
      return;
    }

    this.isConnected = connected;
    const socket = this.client?.client?.messenger?.socket;
    if (connected && socket && typeof socket.bestRtt === "number") {
      socket.bestRtt = -1;
    }
    this.topicEntries.forEach((entry) => this.#broadcastEntry(entry));
  }

  #broadcastEntry(entry) {
    entry.subscribers.forEach((sender, subscriptionId) => {
      if (!sender || sender.isDestroyed()) {
        this.unsubscribe(subscriptionId);
        return;
      }

      sender.send("blitz:nt:update", {
        subscriptionId,
        topicPath: entry.topicPath,
        value: entry.hasValue ? entry.lastValue : entry.defaultValue,
        hasValue: entry.hasValue,
        isConnected: this.isConnected,
      });
    });
  }
}

module.exports = {
  NtBroker,
};
