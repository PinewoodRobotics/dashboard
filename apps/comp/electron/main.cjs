const {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  screen,
  session,
  shell,
  systemPreferences,
} = require("electron");
const { spawn } = require("child_process");
const { promises: fsp } = require("fs");
const http = require("http");
const net = require("net");
const path = require("path");
const { SharedSettingsManager } = require("./shared-settings.cjs");
const { NtBroker } = require("./nt-broker.cjs");
const { AutobahnBroker } = require("./autobahn-broker.cjs");
const { NtRecorder } = require("./nt-recorder.cjs");

const HOST = "127.0.0.1";
const DEFAULT_DEV_URL = "http://127.0.0.1:3001";
const SERVER_START_TIMEOUT_MS = 60_000;
const SERVER_POLL_INTERVAL_MS = 300;
const TILE_SHORTCUT_KEY = "f";
const MAIN_HUD_DISPLAY_SIZE = { width: 1920, height: 1080 };
const TOUCHSCREEN_DISPLAY_SIZE = { width: 1920, height: 515 };

let mainWindow = null;
let touchscreenWindow = null;
let nextServerProcess = null;
let packagedServerUrl = null;
let bundledServerScriptPath = null;
let bundledServerCwd = null;
const serverLogBuffer = [];
const SERVER_LOG_BUFFER_MAX = 120;

const settingsManager = new SharedSettingsManager();
const ntBroker = new NtBroker();
const autobahnBroker = new AutobahnBroker();
const trackedRendererIds = new Set();

// The recorder needs app.getPath(), so it is constructed once the app is ready.
let ntRecorder = null;

function getRecorderPrefsPath() {
  return path.join(app.getPath("userData"), "recorder-prefs.json");
}

function getDefaultRecordingsDir() {
  return path.join(app.getPath("userData"), "recordings");
}

async function readRecorderPrefs() {
  try {
    const raw = await fsp.readFile(getRecorderPrefsPath(), "utf8");
    const parsed = JSON.parse(raw);
    return {
      recordingsDir:
        typeof parsed?.recordingsDir === "string" && parsed.recordingsDir.trim().length > 0
          ? parsed.recordingsDir
          : getDefaultRecordingsDir(),
      autoRecord: parsed?.autoRecord === true,
    };
  } catch {
    return { recordingsDir: getDefaultRecordingsDir(), autoRecord: false };
  }
}

async function writeRecorderPrefs(prefs) {
  const filePath = getRecorderPrefsPath();
  try {
    await fsp.mkdir(path.dirname(filePath), { recursive: true });
    await fsp.writeFile(filePath, JSON.stringify(prefs, null, 2), "utf8");
  } catch (error) {
    console.error("[recorder] failed to persist prefs:", error?.message ?? error);
  }
}

async function persistRecorderPrefsFromStatus() {
  if (!ntRecorder) return;
  const status = ntRecorder.getStatus();
  await writeRecorderPrefs({
    recordingsDir: status.recordingsDir,
    autoRecord: status.autoRecord,
  });
}

function pushServerLog(source, chunk) {
  const text = String(chunk ?? "").replace(/\r/g, "");
  if (!text) return;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    serverLogBuffer.push(`[${source}] ${line}`);
  }
  if (serverLogBuffer.length > SERVER_LOG_BUFFER_MAX) {
    serverLogBuffer.splice(0, serverLogBuffer.length - SERVER_LOG_BUFFER_MAX);
  }
}

function getBundledServerDiagnostics() {
  const lines = [
    `Server URL: ${packagedServerUrl ?? "(not started)"}`,
    `Server script: ${bundledServerScriptPath ?? "(unknown)"}`,
    `Server cwd: ${bundledServerCwd ?? "(unknown)"}`,
  ];
  if (serverLogBuffer.length > 0) {
    lines.push("", "Recent embedded server logs:");
    lines.push(...serverLogBuffer.slice(-40));
  }
  return lines.join("\n");
}

function getWindowIconPath() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "icon.png");
  }

  return path.join(__dirname, "..", "build", "icons", "icon.png");
}

function canConnect(url) {
  return new Promise((resolve) => {
    const request = http.get(url, (response) => {
      response.resume();
      resolve(response.statusCode !== undefined && response.statusCode < 500);
    });

    request.on("error", () => resolve(false));
    request.setTimeout(1_500, () => {
      request.destroy();
      resolve(false);
    });
  });
}

async function waitForServer(url, timeoutMs) {
  const timeoutAt = Date.now() + timeoutMs;
  while (Date.now() < timeoutAt) {
    // eslint-disable-next-line no-await-in-loop
    if (await canConnect(url)) {
      return;
    }

    // eslint-disable-next-line no-await-in-loop
    await new Promise((resolve) => setTimeout(resolve, SERVER_POLL_INTERVAL_MS));
  }

  throw new Error(`Timed out waiting for Next.js server at ${url}`);
}

function getOpenPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, HOST, () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("Unable to determine an open port.")));
        return;
      }

      const { port } = address;
      server.close((closeError) => {
        if (closeError) {
          reject(closeError);
          return;
        }
        resolve(port);
      });
    });
  });
}

async function startBundledNextServer(port) {
  const serverScriptPath = path.join(process.resourcesPath, "app", "server.js");
  const serverCwd = path.dirname(serverScriptPath);
  bundledServerScriptPath = serverScriptPath;
  bundledServerCwd = serverCwd;
  serverLogBuffer.length = 0;

  nextServerProcess = spawn(process.execPath, [serverScriptPath], {
    cwd: serverCwd,
    env: {
      ...process.env,
      NODE_ENV: "production",
      PORT: String(port),
      HOSTNAME: HOST,
      ELECTRON_RUN_AS_NODE: "1",
    },
    stdio: "pipe",
    windowsHide: true,
  });

  nextServerProcess.stdout.on("data", (data) => {
    pushServerLog("next:stdout", data);
    process.stdout.write(`[next] ${data}`);
  });

  nextServerProcess.stderr.on("data", (data) => {
    pushServerLog("next:stderr", data);
    process.stderr.write(`[next] ${data}`);
  });

  nextServerProcess.on("error", (error) => {
    pushServerLog("next:spawn-error", error?.stack || error?.message || String(error));
  });

  nextServerProcess.on("exit", (code, signal) => {
    if (!app.isQuitting) {
      dialog.showErrorBox(
        "PWRUP Comp",
        [
          `Embedded server stopped unexpectedly (code: ${code ?? "null"}, signal: ${signal ?? "none"}).`,
          "",
          getBundledServerDiagnostics(),
        ].join("\n"),
      );
      app.quit();
    }
  });

  try {
    await waitForServer(`http://${HOST}:${port}`, SERVER_START_TIMEOUT_MS);
  } catch (error) {
    pushServerLog("next:start-timeout", error?.stack || error?.message || String(error));
    throw error;
  }
}

function stopBundledNextServer() {
  if (nextServerProcess && !nextServerProcess.killed) {
    nextServerProcess.kill();
  }
}

async function getRendererStartUrl() {
  let startUrl = process.env.ELECTRON_START_URL || DEFAULT_DEV_URL;

  if (app.isPackaged) {
    if (!packagedServerUrl) {
      const port = await getOpenPort();
      await startBundledNextServer(port);
      packagedServerUrl = `http://${HOST}:${port}`;
    }
    startUrl = packagedServerUrl;
  }

  return startUrl;
}

function broadcastToWindows(channel, payload) {
  BrowserWindow.getAllWindows().forEach((window) => {
    if (!window.isDestroyed()) {
      window.webContents.send(channel, payload);
    }
  });
}

function handleRendererDestroyed(senderId) {
  ntBroker.cleanupRenderer(senderId);
  autobahnBroker.cleanupRenderer(senderId);
}

function trackSender(sender) {
  if (trackedRendererIds.has(sender.id)) {
    return;
  }

  trackedRendererIds.add(sender.id);
  sender.once("destroyed", () => {
    trackedRendererIds.delete(sender.id);
    handleRendererDestroyed(sender.id);
  });
}

function registerIpcHandlers() {
  ipcMain.handle("blitz:settings:get", () => settingsManager.getSnapshot());
  ipcMain.handle("blitz:settings:set-connection", async (_event, settings) => {
    return settingsManager.setConnectionSettings(settings);
  });
  ipcMain.handle("blitz:settings:set-hud-visibility", async (_event, hudVisibility) => {
    return settingsManager.setHudVisibility(hudVisibility);
  });
  ipcMain.handle("blitz:settings:reset-connection", () => settingsManager.resetConnectionSettings());
  ipcMain.handle("blitz:settings:reset-hud-visibility", () => settingsManager.resetHudVisibility());

  ipcMain.handle("blitz:nt:subscribe", (event, params) => {
    trackSender(event.sender);
    return ntBroker.subscribe(event.sender, params);
  });
  ipcMain.handle("blitz:nt:unsubscribe", (_event, subscriptionId) => {
    ntBroker.unsubscribe(subscriptionId);
  });
  ipcMain.handle("blitz:nt:publish", (_event, params) => ntBroker.publish(params));

  ipcMain.handle("blitz:autobahn:get-status", () => autobahnBroker.getStatus());
  ipcMain.handle("blitz:autobahn:subscribe", (event, params) => {
    trackSender(event.sender);
    return autobahnBroker.subscribe(event.sender, params);
  });
  ipcMain.handle("blitz:autobahn:unsubscribe", (_event, subscriptionId) => {
    autobahnBroker.unsubscribe(subscriptionId);
  });
  ipcMain.handle("blitz:autobahn:publish", (_event, params) => autobahnBroker.publish(params));
  ipcMain.handle("blitz:autobahn:reconnect", () => autobahnBroker.reconnect());

  ipcMain.handle("blitz:recorder:get-status", () => ntRecorder.getStatus());
  ipcMain.handle("blitz:recorder:start", (_event, options) => ntRecorder.start(options ?? {}));
  ipcMain.handle("blitz:recorder:stop", () => ntRecorder.stop());
  ipcMain.handle("blitz:recorder:list-sessions", () => ntRecorder.listSessions());
  ipcMain.handle("blitz:recorder:delete-session", (_event, id) => ntRecorder.deleteSession(id));
  ipcMain.handle("blitz:recorder:reveal-session", (_event, id) => ntRecorder.revealSession(id));
  ipcMain.handle("blitz:recorder:set-auto-record", async (_event, enabled) => {
    ntRecorder.setAutoRecord(enabled === true);
    await persistRecorderPrefsFromStatus();
    return ntRecorder.getStatus();
  });
  ipcMain.handle("blitz:recorder:choose-dir", async (event) => {
    const owner = BrowserWindow.fromWebContents(event.sender);
    const result = await dialog.showOpenDialog(owner ?? undefined, {
      title: "Choose where recordings are saved",
      defaultPath: ntRecorder.getStatus().recordingsDir,
      properties: ["openDirectory", "createDirectory"],
    });
    if (result.canceled || result.filePaths.length === 0) {
      return null;
    }
    return result.filePaths[0];
  });
  ipcMain.handle("blitz:recorder:set-dir", async (_event, dir) => {
    ntRecorder.setRecordingsDir(dir);
    await persistRecorderPrefsFromStatus();
    return ntRecorder.getStatus();
  });
  ipcMain.handle("blitz:recorder:begin-video", (_event, info) => ntRecorder.beginVideo(info));
  ipcMain.handle("blitz:recorder:append-video", (_event, chunk) =>
    ntRecorder.appendVideoChunk(chunk),
  );
  ipcMain.handle("blitz:recorder:end-video", () => ntRecorder.endVideo());

  ipcMain.handle("blitz:media:get-camera-status", () => getCameraAccessStatus());
  ipcMain.handle("blitz:media:request-camera", () => requestCameraAccess());
  ipcMain.handle("blitz:media:open-camera-settings", async () => {
    if (process.platform !== "darwin") return;
    await shell.openExternal(
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
    );
  });
}

/**
 * The Record app captures a field-facing webcam, which Electron denies unless we say
 * otherwise. macOS gates it a second time behind TCC; that prompt is raised on demand
 * (see `blitz:media:request-camera`) rather than here, because askForMediaAccess blocks
 * until the user answers and a prompt fired before any window exists has nothing on
 * screen to explain it.
 */
function configureMediaPermissions() {
  session.defaultSession.setPermissionRequestHandler((_contents, permission, callback) => {
    callback(permission === "media");
  });
  session.defaultSession.setPermissionCheckHandler((_contents, permission) => permission === "media");
}

/** Mirrors Electron's media-access vocabulary; platforms without TCC are always granted. */
function getCameraAccessStatus() {
  return process.platform === "darwin"
    ? systemPreferences.getMediaAccessStatus("camera")
    : "granted";
}

async function requestCameraAccess() {
  if (process.platform !== "darwin" || getCameraAccessStatus() !== "not-determined") {
    return getCameraAccessStatus();
  }

  // Unsigned dev builds have their TCC request attributed to the launching terminal, so
  // the prompt carries that app's name. Focusing first at least puts it in front of the
  // window the user just clicked.
  app.focus({ steal: true });
  try {
    await systemPreferences.askForMediaAccess("camera");
  } catch (error) {
    console.error("[recorder] camera access request failed:", error?.message ?? error);
  }
  return getCameraAccessStatus();
}

async function initializeBridge() {
  const snapshot = await settingsManager.initialize();
  ntBroker.initialize(snapshot);
  autobahnBroker.initialize(snapshot);

  const recorderPrefs = await readRecorderPrefs();
  ntRecorder = new NtRecorder({
    settingsManager,
    recordingsDir: recorderPrefs.recordingsDir,
  });
  ntRecorder.setAutoRecord(recorderPrefs.autoRecord);
  // NtRecorder subscribes to settingsManager "change" itself, so it is not rebound here.
  ntRecorder.initialize();

  settingsManager.on("change", (nextSnapshot) => {
    ntBroker.updateSettingsSnapshot(nextSnapshot);
    autobahnBroker.updateSettingsSnapshot(nextSnapshot);
    broadcastToWindows("blitz:settings:update", nextSnapshot);
  });

  autobahnBroker.on("status", (isConnected) => {
    broadcastToWindows("blitz:autobahn:status", isConnected);
  });

  ntRecorder.on("status", (status) => {
    broadcastToWindows("blitz:recorder:status", status);
  });

  configureMediaPermissions();
  registerIpcHandlers();
}

function isShortcutInput(input) {
  return (
    input.type === "keyDown" &&
    input.shift &&
    (input.control || input.meta) &&
    String(input.key || "").toLowerCase() === TILE_SHORTCUT_KEY
  );
}

function findDisplayByExactBounds(targetSize) {
  return screen
    .getAllDisplays()
    .find(
      (display) =>
        display.bounds.width === targetSize.width && display.bounds.height === targetSize.height,
    );
}

function clearWindowTiling(window) {
  if (!window || window.isDestroyed()) {
    return;
  }

  window.setKiosk(false);
  if (window.isFullScreen()) {
    window.setFullScreen(false);
  }
  window.setMenuBarVisibility(false);
}

function tileWindowToDisplay(window, display) {
  if (!window || window.isDestroyed()) {
    return;
  }

  if (!display) {
    clearWindowTiling(window);
    return;
  }

  const { x, y, width, height } = display.bounds;
  clearWindowTiling(window);
  window.setBounds({ x, y, width, height });
  window.setMenuBarVisibility(false);
  window.setKiosk(true);
}

function tileCompWindows() {
  const mainHudDisplay = findDisplayByExactBounds(MAIN_HUD_DISPLAY_SIZE);
  const touchscreenDisplay = findDisplayByExactBounds(TOUCHSCREEN_DISPLAY_SIZE);

  tileWindowToDisplay(mainWindow, mainHudDisplay);
  tileWindowToDisplay(touchscreenWindow, touchscreenDisplay);
}

function attachTilingShortcut(window) {
  window.webContents.on("before-input-event", (event, input) => {
    if (!isShortcutInput(input)) {
      return;
    }

    event.preventDefault();
    tileCompWindows();
  });
}

async function createAppWindow(options) {
  const {
    routePath,
    width,
    height,
    minWidth,
    minHeight,
    title,
    assignWindow,
  } = options;
  const iconPath = getWindowIconPath();
  const startUrl = await getRendererStartUrl();

  const window = new BrowserWindow({
    width,
    height,
    minWidth,
    minHeight,
    title,
    icon: iconPath,
    autoHideMenuBar: true,
    backgroundColor: "#000000",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      backgroundThrottling: false,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  const rendererId = window.webContents.id;

  assignWindow(window);
  attachTilingShortcut(window);
  window.on("closed", () => {
    handleRendererDestroyed(rendererId);
    assignWindow(null);
  });

  await window.loadURL(new URL(routePath, startUrl).toString());
  return window;
}

async function createWindows() {
  if (!mainWindow) {
    mainWindow = await createAppWindow({
      routePath: "/hud",
      width: 1440,
      height: 900,
      minWidth: 1024,
      minHeight: 720,
      title: "PWRUP Comp",
      assignWindow: (window) => {
        mainWindow = window;
      },
    });
  }

  if (!touchscreenWindow) {
    touchscreenWindow = await createAppWindow({
      routePath: "/touchscreen",
      width: 1920,
      height: 515,
      minWidth: 1280,
      minHeight: 420,
      title: "PWRUP Comp Touchscreen",
      assignWindow: (window) => {
        touchscreenWindow = window;
      },
    });
  }
}

let recorderShutdownPromise = null;

app.on("before-quit", (event) => {
  // An in-flight recording still has buffered samples; quitting synchronously would truncate
  // the log. Defer the quit exactly once while the recorder closes its files.
  if (ntRecorder && !recorderShutdownPromise) {
    event.preventDefault();
    recorderShutdownPromise = Promise.resolve()
      .then(() => ntRecorder.shutdown())
      .catch((error) => {
        console.error("[recorder] shutdown failed:", error?.message ?? error);
      })
      .then(() => {
        app.quit();
      });
    return;
  }

  app.isQuitting = true;
  settingsManager.stop();
  ntBroker.stop();
  autobahnBroker.stop();
  stopBundledNextServer();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", async () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    await createWindows();
  }
});

app
  .whenReady()
  .then(async () => {
    await initializeBridge();
    await createWindows();
    tileCompWindows();
  })
  .catch((error) => {
    const baseMessage = `Failed to start the app.\n\n${error.message}`;
    if (app.isPackaged) {
      dialog.showErrorBox("PWRUP Comp", `${baseMessage}\n\n${getBundledServerDiagnostics()}`);
    } else {
      dialog.showErrorBox("PWRUP Comp", baseMessage);
    }
    app.quit();
  });
