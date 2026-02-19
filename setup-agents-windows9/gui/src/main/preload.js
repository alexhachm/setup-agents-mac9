const { contextBridge, ipcRenderer } = require('electron');

// Debug logging bridge
const debugListeners = [];

contextBridge.exposeInMainWorld('electron', {
    // Original APIs
    selectProject: () => ipcRenderer.invoke('select-project'),
    getProject: () => ipcRenderer.invoke('get-project'),
    getState: (filename) => ipcRenderer.invoke('get-state', filename),
    getActivityLog: (lines) => ipcRenderer.invoke('get-activity-log', lines),
    writeState: (filename, data) => ipcRenderer.invoke('write-state', { filename, data }),
    touchSignal: (signalName) => ipcRenderer.invoke('touch-signal', signalName),

    onStateChanged: (callback) => {
        ipcRenderer.on('state-changed', (event, filename) => callback(filename));
    },
    onNewLogLines: (callback) => {
        ipcRenderer.on('new-log-lines', (event, lines) => callback(lines));
    },

    // v2 APIs
    getTimeline: (requestId) => ipcRenderer.invoke('get-timeline', requestId),
    getAgentHealth: () => ipcRenderer.invoke('get-agent-health'),
    getKnowledge: (filename) => ipcRenderer.invoke('get-knowledge', filename),
    getSignals: () => ipcRenderer.invoke('get-signals'),
    onKnowledgeChanged: (callback) => ipcRenderer.on('knowledge-changed', (_, filename) => callback(filename)),
    onSignalFired: (callback) => ipcRenderer.on('signal-fired', (_, data) => callback(data)),

    // Debug APIs
    getDebugLog: () => ipcRenderer.invoke('get-debug-log'),
    checkFiles: () => ipcRenderer.invoke('check-files'),
    onDebugLog: (callback) => {
        ipcRenderer.on('debug-log', (event, entry) => callback(entry));
    },

    // Launcher APIs
    getLauncherManifest: (projectPath) => ipcRenderer.invoke('get-launcher-manifest', projectPath),
    launchAgent: (opts) => ipcRenderer.invoke('launch-agent', opts),
    launchGroup: (opts) => ipcRenderer.invoke('launch-group', opts),
    launchGroupTabbed: (opts) => ipcRenderer.invoke('launch-group-tabbed-wt', opts),
    launchAllTabbed: (opts) => ipcRenderer.invoke('launch-all-tabbed-wt', opts),
    mergeTerminalWindows: () => ipcRenderer.invoke('merge-terminal-windows'),
    getLaunchedAgents: () => ipcRenderer.invoke('get-launched-agents'),
    launchProjectCommand: (opts) => ipcRenderer.invoke('launch-project-command', opts),

    // Multi-project APIs
    addProject: (path) => ipcRenderer.invoke('add-project', path),
    switchProject: (path) => ipcRenderer.invoke('switch-project', path),
    listProjects: () => ipcRenderer.invoke('list-projects'),
    removeProject: (path) => ipcRenderer.invoke('remove-project', path),

    // Setup APIs (GUI-first flow)
    runSetup: (opts) => ipcRenderer.invoke('run-setup', opts),
    getRecentProjects: () => ipcRenderer.invoke('get-recent-projects'),
    browseDirectory: () => ipcRenderer.invoke('browse-directory'),
    getSetupScriptDir: () => ipcRenderer.invoke('get-setup-script-dir'),
    checkProjectSetup: (path) => ipcRenderer.invoke('check-project-setup', path),
    onSetupProgress: (callback) => ipcRenderer.on('setup-progress', (_, data) => callback(data)),
});

console.log('[PRELOAD] Bridge initialized');
