import { useEffect, useMemo, useState } from "react";
import { DEFAULT_RECONNECT_TIMEOUT_SECONDS } from "@pwrup/shared-core/settings-schema";
import { ntSelectedPathTopics, useSettings } from "@/lib/settings";

export function useTouchscreenSettingsForm() {
  const { settings, setSettings, resetDefaults } = useSettings();
  const savedReconnectTimeoutSeconds = settings.reconnectTimeoutSeconds ?? DEFAULT_RECONNECT_TIMEOUT_SECONDS;

  const [host, setHost] = useState(settings.host);
  const [port, setPort] = useState(String(settings.port));
  const [ntHost, setNtHost] = useState(settings.networkTables.host);
  const [ntPort, setNtPort] = useState(String(settings.networkTables.port));
  const [sharedTable, setSharedTable] = useState(settings.networkTables.sharedTable);
  const [selectedPathTopic, setSelectedPathTopic] = useState(settings.networkTables.selectedPathTopic);
  const [reconnectTimeoutSeconds, setReconnectTimeoutSeconds] = useState(savedReconnectTimeoutSeconds);

  useEffect(() => {
    setHost(settings.host);
    setPort(String(settings.port));
    setNtHost(settings.networkTables.host);
    setNtPort(String(settings.networkTables.port));
    setSharedTable(settings.networkTables.sharedTable);
    setSelectedPathTopic(settings.networkTables.selectedPathTopic);
    setReconnectTimeoutSeconds(savedReconnectTimeoutSeconds);
  }, [
    settings.host,
    settings.port,
    settings.networkTables.host,
    settings.networkTables.port,
    settings.networkTables.sharedTable,
    settings.networkTables.selectedPathTopic,
    savedReconnectTimeoutSeconds,
  ]);

  const nextHost = host.trim();
  const nextPort = Number(port);
  const nextNtHost = ntHost.trim();
  const nextNtPort = Number(ntPort);
  const nextSharedTable = sharedTable.trim();
  const nextSelectedPathTopic = selectedPathTopic.trim();

  const canSave =
    nextHost.length > 0 &&
    Number.isFinite(nextPort) && nextPort > 0 && nextPort <= 65535 &&
    nextNtHost.length > 0 &&
    Number.isFinite(nextNtPort) && nextNtPort > 0 && nextNtPort <= 65535 &&
    nextSharedTable.length > 0 &&
    nextSelectedPathTopic.length > 0;

  const hasChanges =
    nextHost !== settings.host ||
    Math.round(nextPort) !== settings.port ||
    nextNtHost !== settings.networkTables.host ||
    Math.round(nextNtPort) !== settings.networkTables.port ||
    nextSharedTable !== settings.networkTables.sharedTable ||
    nextSelectedPathTopic !== settings.networkTables.selectedPathTopic ||
    Math.round(reconnectTimeoutSeconds) !== savedReconnectTimeoutSeconds;

  const saveEnabled = canSave && hasChanges;

  const previewTopics = useMemo(
    () => ntSelectedPathTopics(nextSharedTable, nextSelectedPathTopic),
    [nextSharedTable, nextSelectedPathTopic],
  );

  function onSave() {
    if (!canSave) {
      return;
    }

    setSettings({
      host: nextHost,
      port: Math.round(nextPort),
      networkTables: {
        host: nextNtHost,
        port: Math.round(nextNtPort),
        sharedTable: nextSharedTable,
        selectedPathTopic: nextSelectedPathTopic,
      },
      reconnectTimeoutSeconds: Math.round(reconnectTimeoutSeconds),
    });
  }

  function onReset() {
    resetDefaults();
  }

  return {
    host,
    ntHost,
    ntPort,
    onReset,
    onSave,
    port,
    previewTopics,
    reconnectTimeoutSeconds,
    saveEnabled,
    selectedPathTopic,
    setHost,
    setNtHost,
    setNtPort,
    setPort,
    setReconnectTimeoutSeconds,
    setSelectedPathTopic,
    setSharedTable,
    sharedTable,
  };
}
