const { contextBridge, ipcRenderer } = require("electron");

const settingsCallbacks = new Map();
let nextSettingsCallbackId = 1;

const ntCallbacks = new Map();
const autobahnCallbacks = new Map();
const autobahnStatusCallbacks = new Map();
let nextAutobahnStatusCallbackId = 1;

const recorderStatusCallbacks = new Map();
let nextRecorderStatusCallbackId = 1;

ipcRenderer.on("blitz:settings:update", (_event, snapshot) => {
  settingsCallbacks.forEach((callback) => {
    callback(snapshot);
  });
});

ipcRenderer.on("blitz:nt:update", (_event, update) => {
  const callback = ntCallbacks.get(update.subscriptionId);
  if (callback) {
    callback(update);
  }
});

ipcRenderer.on("blitz:autobahn:update", (_event, update) => {
  const callback = autobahnCallbacks.get(update.subscriptionId);
  if (!callback) {
    return;
  }

  callback({
    ...update,
    payload:
      update.payload instanceof Uint8Array
        ? update.payload
        : new Uint8Array(update.payload ?? []),
  });
});

ipcRenderer.on("blitz:autobahn:status", (_event, isConnected) => {
  autobahnStatusCallbacks.forEach((callback) => {
    callback(isConnected);
  });
});

ipcRenderer.on("blitz:recorder:status", (_event, status) => {
  recorderStatusCallbacks.forEach((callback) => {
    callback(status);
  });
});

contextBridge.exposeInMainWorld("blitzRenderer", {
  platform: process.platform,
  electronVersion: process.versions.electron,
  settings: {
    getSnapshot: () => ipcRenderer.invoke("blitz:settings:get"),
    subscribe: (callback) => {
      const callbackId = nextSettingsCallbackId++;
      settingsCallbacks.set(callbackId, callback);
      return callbackId;
    },
    unsubscribe: (callbackId) => {
      settingsCallbacks.delete(callbackId);
    },
    setConnectionSettings: (settings) => ipcRenderer.invoke("blitz:settings:set-connection", settings),
    setHudVisibility: (hudVisibility) => ipcRenderer.invoke("blitz:settings:set-hud-visibility", hudVisibility),
    resetConnectionSettings: () => ipcRenderer.invoke("blitz:settings:reset-connection"),
    resetHudVisibility: () => ipcRenderer.invoke("blitz:settings:reset-hud-visibility"),
  },
  nt: {
    subscribe: async (params, callback) => {
      const response = await ipcRenderer.invoke("blitz:nt:subscribe", params);
      ntCallbacks.set(response.subscriptionId, callback);
      callback(response.initial);
      return response.subscriptionId;
    },
    unsubscribe: async (subscriptionId) => {
      ntCallbacks.delete(subscriptionId);
      await ipcRenderer.invoke("blitz:nt:unsubscribe", subscriptionId);
    },
    publish: (params) => ipcRenderer.invoke("blitz:nt:publish", params),
  },
  autobahn: {
    getStatus: () => ipcRenderer.invoke("blitz:autobahn:get-status"),
    subscribeStatus: (callback) => {
      const callbackId = nextAutobahnStatusCallbackId++;
      autobahnStatusCallbacks.set(callbackId, callback);
      return callbackId;
    },
    unsubscribeStatus: (callbackId) => {
      autobahnStatusCallbacks.delete(callbackId);
    },
    subscribeTopic: async (params, callback) => {
      const response = await ipcRenderer.invoke("blitz:autobahn:subscribe", params);
      autobahnCallbacks.set(response.subscriptionId, callback);
      callback({
        ...response.initial,
        payload: response.initial.payload
          ? response.initial.payload instanceof Uint8Array
            ? response.initial.payload
            : new Uint8Array(response.initial.payload)
          : null,
      });
      return response.subscriptionId;
    },
    unsubscribeTopic: async (subscriptionId) => {
      autobahnCallbacks.delete(subscriptionId);
      await ipcRenderer.invoke("blitz:autobahn:unsubscribe", subscriptionId);
    },
    publish: (params) => ipcRenderer.invoke("blitz:autobahn:publish", params),
    reconnect: () => ipcRenderer.invoke("blitz:autobahn:reconnect"),
  },
  recorder: {
    getStatus: () => ipcRenderer.invoke("blitz:recorder:get-status"),
    subscribeStatus: (callback) => {
      const callbackId = nextRecorderStatusCallbackId++;
      recorderStatusCallbacks.set(callbackId, callback);
      return callbackId;
    },
    unsubscribeStatus: (callbackId) => {
      recorderStatusCallbacks.delete(callbackId);
    },
    start: (options) => ipcRenderer.invoke("blitz:recorder:start", options ?? {}),
    stop: () => ipcRenderer.invoke("blitz:recorder:stop"),
    listSessions: () => ipcRenderer.invoke("blitz:recorder:list-sessions"),
    deleteSession: (id) => ipcRenderer.invoke("blitz:recorder:delete-session", id),
    revealSession: (id) => ipcRenderer.invoke("blitz:recorder:reveal-session", id),
    setAutoRecord: (enabled) => ipcRenderer.invoke("blitz:recorder:set-auto-record", enabled),
    chooseRecordingsDir: () => ipcRenderer.invoke("blitz:recorder:choose-dir"),
    setRecordingsDir: (dir) => ipcRenderer.invoke("blitz:recorder:set-dir", dir),
    beginVideo: (info) => ipcRenderer.invoke("blitz:recorder:begin-video", info),
    // Structured clone keeps this zero-copy-ish; chunks arrive once per timeslice.
    appendVideoChunk: (chunk) => ipcRenderer.invoke("blitz:recorder:append-video", chunk),
    endVideo: () => ipcRenderer.invoke("blitz:recorder:end-video"),
  },
  media: {
    getCameraStatus: () => ipcRenderer.invoke("blitz:media:get-camera-status"),
    requestCamera: () => ipcRenderer.invoke("blitz:media:request-camera"),
    openCameraSettings: () => ipcRenderer.invoke("blitz:media:open-camera-settings"),
  },
});
