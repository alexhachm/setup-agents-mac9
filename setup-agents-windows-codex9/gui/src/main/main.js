// Electron Main Process - Agent Control Center
// WITH EXTENSIVE DEBUG LOGGING
'use strict';

// Suppress EPIPE errors on stdout/stderr — these occur when the pipe
// is closed (e.g. parent process exits) and console.log writes are
// buffered, causing async errors that bypass synchronous try/catch.
process.stdout?.on('error', (err) => { if (err.code !== 'EPIPE') throw err; });
process.stderr?.on('error', (err) => { if (err.code !== 'EPIPE') throw err; });

const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const chokidar = require('chokidar');
const os = require('os');
const { exec, spawn } = require('child_process');

let mainWindow = null;
let stateWatcher = null;
let logWatcher = null;
let knowledgeWatcher = null;
let signalWatcher = null;
let projectPath = null;

// ═══════════════════════════════════════════════════════════════════════════
// DEBUG LOGGING SYSTEM
// ═══════════════════════════════════════════════════════════════════════════
const DEBUG = true;
let debugLog = [];
const MAX_DEBUG_ENTRIES = 500;

function debug(category, message, data = null) {
    if (!DEBUG) return;

    const entry = {
        timestamp: new Date().toISOString(),
        category,
        message,
        data: data ? JSON.stringify(data).slice(0, 500) : null
    };

    debugLog.push(entry);
    if (debugLog.length > MAX_DEBUG_ENTRIES) {
        debugLog = debugLog.slice(-MAX_DEBUG_ENTRIES);
    }

    const logStr = `[MAIN:${category}] ${message}${data ? ' | ' + JSON.stringify(data).slice(0, 200) : ''}`;
    try { console.log(logStr); } catch (e) { /* ignore EPIPE */ }

    // Send to renderer if window exists and is not destroyed
    if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('debug-log', entry);
    }
}

// Get project path from command line, env var, or recent config
const args = process.argv.slice(2);
debug('INIT', 'Starting with args', args);
debug('INIT', 'PROJECT_PATH env', { env: process.env.PROJECT_PATH || 'not set' });

const projectArg = args.find(a => !a.startsWith('-'));
if (projectArg && fs.existsSync(path.join(projectArg, '.codex-shared-state'))) {
    projectPath = projectArg;
    debug('INIT', 'Project path from args', { projectPath });
} else if (process.env.PROJECT_PATH && fs.existsSync(path.join(process.env.PROJECT_PATH, '.codex-shared-state'))) {
    projectPath = process.env.PROJECT_PATH;
    debug('INIT', 'Project path from PROJECT_PATH env', { projectPath });
} else {
    // Auto-detect from recent config
    const configFile = path.join(os.homedir(), '.codex-multi-agent-config');
    try {
        if (fs.existsSync(configFile)) {
            const content = fs.readFileSync(configFile, 'utf-8');
            const match = content.match(/project_path\s*=\s*(.+)/);
            if (match) {
                const configPath = match[1].trim();
                if (fs.existsSync(path.join(configPath, '.codex-shared-state'))) {
                    projectPath = configPath;
                    debug('INIT', 'Project path from config file', { projectPath });
                }
            }
        }
    } catch (e) {
        debug('INIT', 'Error reading config', { error: e.message });
    }
    if (!projectPath) {
        debug('INIT', 'No valid project path found');
    }
}

const getStatePath = (file) => projectPath ? path.join(projectPath, '.codex-shared-state', file) : null;
const getLogPath = () => projectPath ? path.join(projectPath, '.codex', 'logs', 'activity.log') : null;
const getSignalPath = (signalFile) => projectPath ? path.join(projectPath, '.codex', 'signals', signalFile) : null;

function writeJsonFileAtomic(filePath, data) {
    const dir = path.dirname(filePath);
    fs.mkdirSync(dir, { recursive: true });

    const tmpPath = `${filePath}.tmp.${process.pid}.${Date.now()}`;
    try {
        fs.writeFileSync(tmpPath, JSON.stringify(data, null, 2));
        fs.renameSync(tmpPath, filePath);
    } finally {
        if (fs.existsSync(tmpPath)) {
            try { fs.unlinkSync(tmpPath); } catch (e) { /* ignore cleanup errors */ }
        }
    }
}

function touchSignal(signalName) {
    if (!projectPath) {
        throw new Error('No project selected');
    }
    if (typeof signalName !== 'string' || !signalName.trim()) {
        throw new Error('Signal name is required');
    }

    // Keep signal naming consistent with existing dot-prefixed files.
    const trimmed = signalName.trim();
    const normalized = trimmed.startsWith('.') ? trimmed : `.${trimmed}`;
    const signalPath = getSignalPath(normalized);
    if (!signalPath) {
        throw new Error('Signal path unavailable');
    }

    fs.mkdirSync(path.dirname(signalPath), { recursive: true });
    const now = new Date();
    fs.closeSync(fs.openSync(signalPath, 'a'));
    fs.utimesSync(signalPath, now, now);
    return { signalPath, signalName: normalized };
}

function createWindow() {
    debug('WINDOW', 'Creating main window');

    mainWindow = new BrowserWindow({
        width: 1400,
        height: 900,
        minWidth: 900,
        minHeight: 600,
        titleBarStyle: 'hiddenInset',
        backgroundColor: '#0d1117',
        show: false,
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: path.join(__dirname, 'preload.js')
        }
    });

    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

    mainWindow.once('ready-to-show', () => {
        debug('WINDOW', 'Window ready to show');
        mainWindow.show();
    });

    // Always open DevTools for debugging
    if (args.includes('--dev') || DEBUG) {
        mainWindow.webContents.openDevTools();
        debug('WINDOW', 'DevTools opened');
    }

    mainWindow.on('closed', () => {
        debug('WINDOW', 'Window closed');
        mainWindow = null;
        stopWatching();
    });

    debug('WINDOW', 'Window creation complete');
}

// === IPC Handlers ===

ipcMain.handle('select-project', async () => {
    debug('IPC', 'select-project called');

    const result = await dialog.showOpenDialog(mainWindow, {
        properties: ['openDirectory'],
        title: 'Select Project Directory'
    });

    debug('IPC', 'Dialog result', { canceled: result.canceled, paths: result.filePaths });

    if (!result.canceled && result.filePaths.length > 0) {
        const selectedPath = result.filePaths[0];
        projectPath = selectedPath;
        addProjectToRecent(selectedPath);
        debug('IPC', 'Project selected', { projectPath });

        const hasSharedState = fs.existsSync(path.join(selectedPath, '.codex-shared-state'));
        if (hasSharedState) {
            startWatching();
        }

        return {
            success: true,
            path: selectedPath,
            needsSetup: !hasSharedState
        };
    }
    return { success: false, error: 'No directory selected' };
});

ipcMain.handle('get-project', () => {
    debug('IPC', 'get-project called', { projectPath });
    if (projectPath) {
        return { path: projectPath, name: path.basename(projectPath) };
    }
    return null;
});

ipcMain.handle('get-state', async (event, filename) => {
    debug('IPC', 'get-state called', { filename });
    const filePath = getStatePath(filename);
    if (!filePath) {
        debug('IPC', 'get-state: no project path');
        return null;
    }
    try {
        const content = fs.readFileSync(filePath, 'utf-8');
        const data = JSON.parse(content);
        debug('IPC', 'get-state success', { filename, dataKeys: Object.keys(data || {}) });
        return data;
    } catch (e) {
        debug('IPC', 'get-state error', { filename, error: e.message });
        return null;
    }
});

ipcMain.handle('get-activity-log', async (event, lines = 100) => {
    debug('IPC', 'get-activity-log called', { lines });
    const logPath = getLogPath();
    if (!logPath) {
        debug('IPC', 'get-activity-log: no log path');
        return [];
    }
    try {
        const content = fs.readFileSync(logPath, 'utf-8');
        const logLines = content.split('\n').filter(l => l.trim()).slice(-lines);
        debug('IPC', 'get-activity-log success', { lineCount: logLines.length });
        return logLines;
    } catch (e) {
        debug('IPC', 'get-activity-log error', { error: e.message });
        return [];
    }
});

ipcMain.handle('write-state', async (event, { filename, data }) => {
    debug('IPC', 'write-state called', { filename, dataKeys: Object.keys(data || {}) });
    const filePath = getStatePath(filename);
    if (!filePath) {
        debug('IPC', 'write-state: no project selected');
        return { success: false, error: 'No project selected' };
    }
    try {
        writeJsonFileAtomic(filePath, data);
        debug('IPC', 'write-state success', { filename });
        return { success: true };
    } catch (e) {
        debug('IPC', 'write-state error', { filename, error: e.message });
        return { success: false, error: e.message };
    }
});

ipcMain.handle('touch-signal', async (event, signalName) => {
    debug('IPC', 'touch-signal called', { signalName });
    try {
        const result = touchSignal(signalName);
        debug('IPC', 'touch-signal success', result);
        return { success: true, ...result };
    } catch (e) {
        debug('IPC', 'touch-signal error', { signalName, error: e.message });
        return { success: false, error: e.message };
    }
});

ipcMain.handle('get-debug-log', () => {
    return debugLog;
});

ipcMain.handle('check-files', async () => {
    debug('IPC', 'check-files called');

    if (!projectPath) {
        return { error: 'No project selected' };
    }

    const stateDir = path.join(projectPath, '.codex-shared-state');
    const logDir = path.join(projectPath, '.codex', 'logs');

    const result = {
        projectPath,
        stateDir: {
            exists: fs.existsSync(stateDir),
            files: []
        },
        logDir: {
            exists: fs.existsSync(logDir),
            files: []
        }
    };

    if (result.stateDir.exists) {
        try {
            result.stateDir.files = fs.readdirSync(stateDir).map(f => {
                const fp = path.join(stateDir, f);
                const stat = fs.statSync(fp);
                let preview = null;
                try {
                    const content = fs.readFileSync(fp, 'utf-8');
                    preview = content.slice(0, 200);
                } catch (e) { }
                return {
                    name: f,
                    size: stat.size,
                    modified: stat.mtime.toISOString(),
                    preview
                };
            });
        } catch (e) {
            result.stateDir.error = e.message;
        }
    }

    if (result.logDir.exists) {
        try {
            result.logDir.files = fs.readdirSync(logDir).map(f => {
                const fp = path.join(logDir, f);
                const stat = fs.statSync(fp);
                return {
                    name: f,
                    size: stat.size,
                    modified: stat.mtime.toISOString()
                };
            });
        } catch (e) {
            result.logDir.error = e.message;
        }
    }

    debug('IPC', 'check-files result', result);
    return result;
});

// === v2 IPC Handlers ===

ipcMain.handle('get-timeline', async (event, requestId) => {
    const logPath = getLogPath();
    if (!logPath) return [];

    try {
        const content = fs.readFileSync(logPath, 'utf-8');
        const lines = content.split('\n').filter(l => l.trim());

        const events = lines.map(line => {
            const match = line.match(
                /\[(\d{4}-\d{2}-\d{2}T[\d:]+Z?)\]\s+\[([^\]]+)\]\s+\[([^\]]+)\]\s*(.*)/
            );
            if (!match) return null;
            const [, timestamp, agent, action, details] = match;
            return { timestamp, agent, action, details: details.trim() };
        }).filter(Boolean);

        if (requestId) {
            return events.filter(e =>
                e.details.includes(requestId) ||
                e.details.includes(`id=${requestId}`)
            );
        }
        return events;
    } catch (e) {
        return [];
    }
});

ipcMain.handle('get-agent-health', async () => {
    const filePath = getStatePath('agent-health.json');
    if (!filePath) return null;
    try {
        const content = fs.readFileSync(filePath, 'utf-8');
        const health = JSON.parse(content);

        // Enrich with computed fields
        if (health['master-2']) {
            const m2 = health['master-2'];
            m2.tier1_remaining = 4 - (m2.tier1_count || 0);
            m2.decomp_remaining = 6 - (m2.decomposition_count || 0);
            m2.resetImminent = m2.tier1_remaining <= 1 || m2.decomp_remaining <= 1;
        }
        if (health['master-3']) {
            const m3 = health['master-3'];
            if (m3.started_at) {
                m3.uptimeMinutes = Math.floor((Date.now() - new Date(m3.started_at).getTime()) / 60000);
                m3.resetImminent = m3.uptimeMinutes >= 18 || (m3.context_budget || 0) >= 4500;
            }
            m3.budgetPercent = Math.min(100, Math.floor(((m3.context_budget || 0) / 5000) * 100));
        }
        if (health.workers) {
            for (const [id, w] of Object.entries(health.workers)) {
                w.budgetPercent = Math.min(100, Math.floor(((w.context_budget || 0) / 8000) * 100));
                w.resetImminent = w.budgetPercent >= 90 || (w.tasks_completed || 0) >= 5;
            }
        }

        return health;
    } catch (e) {
        return null;
    }
});

ipcMain.handle('get-knowledge', async (event, filename) => {
    if (!projectPath) return null;
    const knowledgeDir = path.join(projectPath, '.codex', 'knowledge');

    if (!filename) {
        try {
            const files = [];
            const readDir = (dir, prefix = '') => {
                for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
                    if (entry.name === '.gitkeep') continue;
                    const fp = path.join(dir, entry.name);
                    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
                    if (entry.isDirectory()) {
                        readDir(fp, rel);
                    } else {
                        const stat = fs.statSync(fp);
                        const content = fs.readFileSync(fp, 'utf-8');
                        const wordCount = content.split(/\s+/).filter(Boolean).length;
                        files.push({
                            name: rel,
                            size: stat.size,
                            modified: stat.mtime.toISOString(),
                            tokenEstimate: Math.ceil(wordCount * 1.3),
                            content
                        });
                    }
                }
            };
            readDir(knowledgeDir);
            return files;
        } catch (e) {
            return [];
        }
    }

    try {
        return fs.readFileSync(path.join(knowledgeDir, filename), 'utf-8');
    } catch (e) {
        return null;
    }
});

ipcMain.handle('get-signals', async () => {
    if (!projectPath) return [];
    const signalDir = path.join(projectPath, '.codex', 'signals');
    if (!fs.existsSync(signalDir)) return [];

    try {
        return fs.readdirSync(signalDir)
            .filter(f => f.startsWith('.'))
            .map(f => {
                const fp = path.join(signalDir, f);
                const stat = fs.statSync(fp);
                return {
                    name: f,
                    lastTouched: stat.mtime.toISOString(),
                    ageMs: Date.now() - stat.mtime.getTime()
                };
            });
    } catch (e) {
        return [];
    }
});

// === Launcher & Multi-Project IPC Handlers ===

function cleanEnv(forProjectPath, cwdOverride) {
    const env = { ...process.env };

    // Baseline cleanup for stale compatibility env.
    delete env.LEGACY_AGENT_MODE;
    delete env.LEGACY_SESSION_ID;
    delete env.LEGACY_PROVIDER_ENV;

    const pp = forProjectPath || projectPath;
    if (pp) {
        try {
            const providerPath = path.join(pp, '.codex', 'provider-codex.json');
            if (fs.existsSync(providerPath)) {
                const provider = JSON.parse(fs.readFileSync(providerPath, 'utf-8'));
                const unsetVars = Array.isArray(provider?.env_policy?.unset) ? provider.env_policy.unset : [];
                unsetVars.forEach((key) => {
                    if (typeof key === 'string' && key) delete env[key];
                });

                const setVars = provider?.env_policy?.set && typeof provider.env_policy.set === 'object'
                    ? provider.env_policy.set
                    : {};
                Object.entries(setVars).forEach(([key, rawValue]) => {
                    if (!key) return;
                    let value = String(rawValue ?? '');
                    const runtimeCwd = cwdOverride || pp;
                    value = value.split('{{cwd}}').join(runtimeCwd);
                    value = value.split('{{project_dir}}').join(pp);
                    env[key] = value;
                });
            }
        } catch (e) {
            debug('LAUNCH', 'Provider env policy read failed', { error: e.message, projectPath: pp });
        }
    }

    return env;
}

// Read and parse the launcher manifest, handling Windows backslash paths
function readManifest(manifestPath) {
    let raw = fs.readFileSync(manifestPath, 'utf-8');
    // Fix Windows paths with unescaped backslashes in JSON
    raw = raw.replace(/\\/g, '/');
    return JSON.parse(raw);
}

function resolveManifestPath(pp, maybePath, fallbackPath) {
    if (!maybePath) return fallbackPath;
    return path.isAbsolute(maybePath) ? maybePath : path.join(pp, maybePath);
}

// Track launched processes per project
const launchedProcesses = new Map(); // key: "projectPath:agentId"

// Track multiple projects
let projects = new Map(); // path -> { name, path, addedAt }

// ═══════════════════════════════════════════════════════════════════════════
// PERSISTENT RECENT PROJECTS
// ═══════════════════════════════════════════════════════════════════════════
const recentProjectsFile = path.join(os.homedir(), '.codex-agent-recent-projects.json');

function loadRecentProjectsFromDisk() {
    try {
        if (fs.existsSync(recentProjectsFile)) {
            const data = JSON.parse(fs.readFileSync(recentProjectsFile, 'utf-8'));
            if (Array.isArray(data)) {
                data.forEach(p => {
                    if (p.path && fs.existsSync(p.path)) {
                        projects.set(p.path, {
                            name: p.name || path.basename(p.path),
                            path: p.path,
                            repoUrl: p.repoUrl || null,
                            addedAt: p.addedAt || new Date().toISOString()
                        });
                    }
                });
                debug('PROJECTS', 'Loaded recent projects from disk', { count: projects.size });
            }
        }
    } catch (e) {
        debug('PROJECTS', 'Error loading recent projects', { error: e.message });
    }
}

function saveRecentProjectsToDisk() {
    try {
        const data = Array.from(projects.values()).map(p => ({
            name: p.name,
            path: p.path,
            repoUrl: p.repoUrl || null,
            addedAt: p.addedAt
        }));
        fs.writeFileSync(recentProjectsFile, JSON.stringify(data, null, 2));
        debug('PROJECTS', 'Saved recent projects to disk', { count: data.length });
    } catch (e) {
        debug('PROJECTS', 'Error saving recent projects', { error: e.message });
    }
}

function detectRepoUrl(pp) {
    try {
        const gitConfigPath = path.join(pp, '.git', 'config');
        if (fs.existsSync(gitConfigPath)) {
            const content = fs.readFileSync(gitConfigPath, 'utf-8');
            const match = content.match(/\[remote "origin"\][^[]*url\s*=\s*(.+)/m);
            if (match) return match[1].trim();
        }
    } catch (e) { /* ignore */ }
    return null;
}

function addProjectToRecent(pp, repoUrl) {
    const name = path.basename(pp);
    const url = repoUrl || detectRepoUrl(pp) || null;
    projects.set(pp, {
        name,
        path: pp,
        repoUrl: url,
        addedAt: projects.get(pp)?.addedAt || new Date().toISOString()
    });
    saveRecentProjectsToDisk();
}

// Load persisted recent projects on startup
loadRecentProjectsFromDisk();

ipcMain.handle('get-launcher-manifest', async (event, forProjectPath) => {
    const pp = forProjectPath || projectPath;
    debug('IPC', 'get-launcher-manifest called', { forProjectPath, projectPath, pp });
    if (!pp) {
        debug('IPC', 'No project path for manifest lookup');
        return null;
    }
    const manifestPath = path.join(pp, '.codex', 'launchers', 'manifest.json');
    debug('IPC', 'Looking for manifest at', { manifestPath, exists: fs.existsSync(manifestPath) });
    try {
        const data = readManifest(manifestPath);
        debug('IPC', 'Manifest loaded successfully', { agents: data.agents?.length });
        return data;
    } catch (e) {
        debug('IPC', 'Failed to read manifest', { path: manifestPath, error: e.message });
        return null;
    }
});

ipcMain.handle('launch-agent', async (event, { agentId, projectPath: pp, continueMode }) => {
    pp = pp || projectPath;
    if (!pp) return { success: false, error: 'No project path' };

    const manifestPath = path.join(pp, '.codex', 'launchers', 'manifest.json');
    let manifest;
    try {
        manifest = readManifest(manifestPath);
    } catch (e) {
        return { success: false, error: 'Launcher manifest not found. Run setup first (setup.ps1 on Windows).' };
    }

    const agent = manifest.agents.find(a => a.id === agentId);
    if (!agent) return { success: false, error: `Agent ${agentId} not in manifest` };

    const processKey = `${pp}:${agentId}`;
    const command = continueMode ? agent.command_continue : agent.command_fresh;
    const cwd = agent.cwd;

    debug('LAUNCH', `Launching ${agentId}`, { cwd, command, platform: process.platform });

    try {
        let terminalCmd;

        if (process.platform === 'darwin') {
            // macOS: open a new Terminal.app window
            const escapedCmd = `cd '${cwd}' && ${command}`.replace(/'/g, "'\\''");
            terminalCmd = `osascript -e 'tell application "Terminal"' `
                + `-e 'activate' `
                + `-e 'do script "${escapedCmd}"' `
                + `-e 'end tell'`;

        } else if (process.platform === 'win32') {
            // Windows: prefer .ps1 launchers, fall back to .bat, then raw command
            const launcherDir = path.join(pp, '.codex', 'launchers');
            const suffix = continueMode ? '-continue' : '';
            const defaultPs1 = path.join(launcherDir, `${agent.id}${suffix}.ps1`);
            const defaultBat = path.join(launcherDir, `${agent.id}${suffix}.bat`);
            const ps1Field = continueMode ? (agent.launcher_ps1_continue || agent.launcher_ps1) : agent.launcher_ps1;
            const batField = continueMode ? (agent.launcher_win_continue || agent.launcher_win) : agent.launcher_win;
            const ps1File = resolveManifestPath(pp, ps1Field, defaultPs1);
            const batFile = resolveManifestPath(pp, batField, defaultBat);

            if (fs.existsSync(ps1File)) {
                terminalCmd = `where wt >nul 2>nul && wt new-tab -d "${cwd}" --title ${agent.id} powershell.exe -ExecutionPolicy Bypass -File "${ps1File}" || start powershell.exe -ExecutionPolicy Bypass -File "${ps1File}"`;
            } else if (fs.existsSync(batFile)) {
                terminalCmd = `where wt >nul 2>nul && wt new-tab -d "${cwd}" --title ${agent.id} cmd /k "${batFile}" || start cmd /k "${batFile}"`;
            } else {
                const winCmd = command.replace(/'/g, '"');
                terminalCmd = `where wt >nul 2>nul && wt new-tab -d "${cwd}" --title ${agent.id} cmd /k "${winCmd}" || start cmd /k "cd /d ${cwd} && ${winCmd}"`;
            }

        } else {
            // Linux: try common terminal emulators
            const linuxCmd = `cd '${cwd}' && ${command}`;
            terminalCmd = `which gnome-terminal >/dev/null 2>&1 && gnome-terminal -- bash -c '${linuxCmd}; exec bash' || `
                + `which konsole >/dev/null 2>&1 && konsole -e bash -c '${linuxCmd}; exec bash' || `
                + `xterm -e bash -c '${linuxCmd}; exec bash'`;
        }

        exec(terminalCmd, { env: cleanEnv(pp, cwd) }, (error) => {
            if (error) {
                debug('LAUNCH', `Error launching ${agentId}`, { error: error.message });
            }
        });

        launchedProcesses.set(processKey, {
            agentId,
            projectPath: pp,
            launchedAt: new Date().toISOString(),
            continueMode
        });

        debug('LAUNCH', `Launched ${agentId} successfully`);
        return { success: true, agentId, cwd };

    } catch (e) {
        debug('LAUNCH', `Failed to launch ${agentId}`, { error: e.message });
        return { success: false, error: e.message };
    }
});

ipcMain.handle('launch-group', async (event, { group, projectPath: pp, continueMode }) => {
    pp = pp || projectPath;
    if (!pp) return { success: false, error: 'No project path' };

    const manifestPath = path.join(pp, '.codex', 'launchers', 'manifest.json');
    let manifest;
    try {
        manifest = readManifest(manifestPath);
    } catch (e) {
        return { success: false, error: 'Launcher manifest not found' };
    }

    const agents = manifest.agents.filter(a => a.group === group);
    const results = [];

    for (const agent of agents) {
        // Stagger launches by 2 seconds to avoid race conditions
        if (results.length > 0) {
            await new Promise(resolve => setTimeout(resolve, 2000));
        }

        const command = continueMode ? agent.command_continue : agent.command_fresh;
        const cwd = agent.cwd;
        let terminalCmd;

        if (process.platform === 'darwin') {
            const escapedCmd = `cd '${cwd}' && ${command}`.replace(/'/g, "'\\''");
            terminalCmd = `osascript -e 'tell application "Terminal"' `
                + `-e 'activate' `
                + `-e 'do script "${escapedCmd}"' `
                + `-e 'end tell'`;
        } else if (process.platform === 'win32') {
            const launcherDir = path.join(pp, '.codex', 'launchers');
            const suffix = continueMode ? '-continue' : '';
            const defaultPs1 = path.join(launcherDir, `${agent.id}${suffix}.ps1`);
            const defaultBat = path.join(launcherDir, `${agent.id}${suffix}.bat`);
            const ps1Field = continueMode ? (agent.launcher_ps1_continue || agent.launcher_ps1) : agent.launcher_ps1;
            const batField = continueMode ? (agent.launcher_win_continue || agent.launcher_win) : agent.launcher_win;
            const ps1File = resolveManifestPath(pp, ps1Field, defaultPs1);
            const batFile = resolveManifestPath(pp, batField, defaultBat);

            if (fs.existsSync(ps1File)) {
                terminalCmd = `where wt >nul 2>nul && wt new-tab -d "${cwd}" --title ${agent.id} powershell.exe -ExecutionPolicy Bypass -File "${ps1File}" || start powershell.exe -ExecutionPolicy Bypass -File "${ps1File}"`;
            } else if (fs.existsSync(batFile)) {
                terminalCmd = `where wt >nul 2>nul && wt new-tab -d "${cwd}" --title ${agent.id} cmd /k "${batFile}" || start cmd /k "${batFile}"`;
            } else {
                const winCmd = command.replace(/'/g, '"');
                terminalCmd = `where wt >nul 2>nul && wt new-tab -d "${cwd}" --title ${agent.id} cmd /k "${winCmd}" || start cmd /k "cd /d ${cwd} && ${winCmd}"`;
            }
        } else {
            const linuxCmd = `cd '${cwd}' && ${command}`;
            terminalCmd = `which gnome-terminal >/dev/null 2>&1 && gnome-terminal -- bash -c '${linuxCmd}; exec bash' || `
                + `which konsole >/dev/null 2>&1 && konsole -e bash -c '${linuxCmd}; exec bash' || `
                + `xterm -e bash -c '${linuxCmd}; exec bash'`;
        }

        exec(terminalCmd, { env: cleanEnv(pp, cwd) }, (error) => {
            if (error) debug('LAUNCH', `Error launching ${agent.id}`, { error: error.message });
        });

        launchedProcesses.set(`${pp}:${agent.id}`, {
            agentId: agent.id,
            projectPath: pp,
            launchedAt: new Date().toISOString(),
            continueMode
        });

        results.push({ success: true, agentId: agent.id });
    }

    return { success: true, launched: results };
});

// macOS-specific: merge terminal windows into tabs after group launch
ipcMain.handle('merge-terminal-windows', async () => {
    if (process.platform !== 'darwin') return { success: false, error: 'macOS only' };

    try {
        exec(`osascript -e 'tell application "Terminal" to activate' -e 'delay 0.5' -e 'tell application "System Events" to tell process "Terminal" to click menu item "Merge All Windows" of menu "Window" of menu bar 1'`);
        return { success: true };
    } catch (e) {
        return { success: false, error: e.message };
    }
});

// Windows-specific: launch group as tabs in Windows Terminal
ipcMain.handle('launch-group-tabbed-wt', async (event, { group, projectPath: pp, continueMode }) => {
    if (process.platform !== 'win32') return { success: false, error: 'Windows only' };
    pp = pp || projectPath;

    const manifestPath = path.join(pp, '.codex', 'launchers', 'manifest.json');
    let manifest;
    try {
        manifest = readManifest(manifestPath);
    } catch (e) {
        return { success: false, error: 'Launcher manifest not found' };
    }

    const agents = manifest.agents.filter(a => a.group === group);
    if (agents.length === 0) return { success: false, error: 'No agents in group' };

    // Build a single Windows Terminal command with multiple tabs using .ps1 launchers
    const tabArgs = agents.map((agent, i) => {
        const launcherDir = path.join(pp, '.codex', 'launchers');
        const suffix = continueMode ? '-continue' : '';
        const defaultPs1 = path.join(launcherDir, `${agent.id}${suffix}.ps1`);
        const defaultBat = path.join(launcherDir, `${agent.id}${suffix}.bat`);
        const ps1Field = continueMode ? (agent.launcher_ps1_continue || agent.launcher_ps1) : agent.launcher_ps1;
        const batField = continueMode ? (agent.launcher_win_continue || agent.launcher_win) : agent.launcher_win;
        const ps1File = resolveManifestPath(pp, ps1Field, defaultPs1);
        const batFile = resolveManifestPath(pp, batField, defaultBat);
        const prefix = i === 0 ? '' : '; new-tab';

        if (fs.existsSync(ps1File)) {
            return `${prefix} -d "${agent.cwd}" --title ${agent.id} powershell.exe -ExecutionPolicy Bypass -File "${ps1File}"`;
        } else if (fs.existsSync(batFile)) {
            return `${prefix} -d "${agent.cwd}" --title ${agent.id} cmd /k "${batFile}"`;
        } else {
            const cmd = continueMode ? agent.command_continue : agent.command_fresh;
            const winCmd = cmd.replace(/'/g, '"');
            return `${prefix} -d "${agent.cwd}" --title ${agent.id} cmd /k "${winCmd}"`;
        }
    }).join(' ');

    try {
        exec(`wt ${tabArgs}`, { env: cleanEnv(pp, pp) });
        agents.forEach(a => {
            launchedProcesses.set(`${pp}:${a.id}`, {
                agentId: a.id,
                projectPath: pp,
                launchedAt: new Date().toISOString(),
                continueMode
            });
        });
        return { success: true, launched: agents.map(a => ({ agentId: a.id })) };
    } catch (e) {
        return { success: false, error: e.message };
    }
});

// Windows: launch ALL agents (masters + workers) in a single window with tabs
ipcMain.handle('launch-all-tabbed-wt', async (event, { projectPath: pp, continueMode }) => {
    if (process.platform !== 'win32') return { success: false, error: 'Windows only' };
    pp = pp || projectPath;

    const manifestPath = path.join(pp, '.codex', 'launchers', 'manifest.json');
    let manifest;
    try {
        manifest = readManifest(manifestPath);
    } catch (e) {
        return { success: false, error: 'Launcher manifest not found' };
    }

    const agents = manifest.agents;
    if (agents.length === 0) return { success: false, error: 'No agents in manifest' };

    const tabArgs = agents.map((agent, i) => {
        const launcherDir = path.join(pp, '.codex', 'launchers');
        const suffix = continueMode ? '-continue' : '';
        const defaultPs1 = path.join(launcherDir, `${agent.id}${suffix}.ps1`);
        const defaultBat = path.join(launcherDir, `${agent.id}${suffix}.bat`);
        const ps1Field = continueMode ? (agent.launcher_ps1_continue || agent.launcher_ps1) : agent.launcher_ps1;
        const batField = continueMode ? (agent.launcher_win_continue || agent.launcher_win) : agent.launcher_win;
        const ps1File = resolveManifestPath(pp, ps1Field, defaultPs1);
        const batFile = resolveManifestPath(pp, batField, defaultBat);
        const prefix = i === 0 ? '' : '; new-tab';

        if (fs.existsSync(ps1File)) {
            return `${prefix} -d "${agent.cwd}" --title ${agent.id} powershell.exe -ExecutionPolicy Bypass -File "${ps1File}"`;
        } else if (fs.existsSync(batFile)) {
            return `${prefix} -d "${agent.cwd}" --title ${agent.id} cmd /k "${batFile}"`;
        } else {
            const cmd = continueMode ? agent.command_continue : agent.command_fresh;
            const winCmd = cmd.replace(/'/g, '"');
            return `${prefix} -d "${agent.cwd}" --title ${agent.id} cmd /k "${winCmd}"`;
        }
    }).join(' ');

    try {
        exec(`wt ${tabArgs}`, { env: cleanEnv(pp, pp) });
        agents.forEach(a => {
            launchedProcesses.set(`${pp}:${a.id}`, {
                agentId: a.id,
                projectPath: pp,
                launchedAt: new Date().toISOString(),
                continueMode
            });
        });
        return { success: true, launched: agents.map(a => ({ agentId: a.id })) };
    } catch (e) {
        return { success: false, error: e.message };
    }
});

// Launch a project command (detected from codebase scan)
ipcMain.handle('launch-project-command', async (event, { command, cwd, name }) => {
    const pp = cwd || projectPath;
    if (!pp) return { success: false, error: 'No project path' };

    debug('LAUNCH', `Launching project command: ${name}`, { command, cwd: pp });

    try {
        let terminalCmd;

        if (process.platform === 'darwin') {
            const escapedCmd = `cd '${pp}' && ${command}`.replace(/'/g, "'\\''");
            terminalCmd = `osascript -e 'tell application "Terminal"' `
                + `-e 'activate' `
                + `-e 'do script "${escapedCmd}"' `
                + `-e 'end tell'`;

        } else if (process.platform === 'win32') {
            const winCmd = command.replace(/'/g, '"');
            terminalCmd = `where wt >nul 2>nul && wt new-tab -d "${pp}" --title "${name || 'Project'}" cmd /k "${winCmd}" || start cmd /k "cd /d ${pp} && ${winCmd}"`;

        } else {
            const linuxCmd = `cd '${pp}' && ${command}`;
            terminalCmd = `which gnome-terminal >/dev/null 2>&1 && gnome-terminal -- bash -c '${linuxCmd}; exec bash' || `
                + `which konsole >/dev/null 2>&1 && konsole -e bash -c '${linuxCmd}; exec bash' || `
                + `xterm -e bash -c '${linuxCmd}; exec bash'`;
        }

        exec(terminalCmd, { env: cleanEnv(pp, pp) }, (error) => {
            if (error) {
                debug('LAUNCH', `Error launching project command: ${name}`, { error: error.message });
            }
        });

        debug('LAUNCH', `Project command launched: ${name}`);
        return { success: true, name, command };

    } catch (e) {
        debug('LAUNCH', `Failed to launch project command: ${name}`, { error: e.message });
        return { success: false, error: e.message };
    }
});

ipcMain.handle('get-launched-agents', async () => {
    return Array.from(launchedProcesses.entries()).map(([key, val]) => ({
        key,
        ...val
    }));
});

// === Project Setup Status Check ===

ipcMain.handle('check-project-setup', async (event, pp) => {
    pp = pp || projectPath;
    if (!pp) return { needsSetup: true, reason: 'No project selected' };

    const checks = {
        projectExists: fs.existsSync(pp),
        hasCodexDir: fs.existsSync(path.join(pp, '.codex')),
        hasSharedState: fs.existsSync(path.join(pp, '.codex-shared-state')),
        hasManifest: fs.existsSync(path.join(pp, '.codex', 'launchers', 'manifest.json')),
        hasState: fs.existsSync(path.join(pp, '.codex', 'state')),
        hasAgentsMd: fs.existsSync(path.join(pp, 'AGENTS.md')),
    };

    const needsSetup = !checks.hasCodexDir || !checks.hasSharedState || !checks.hasManifest;
    const missing = [];
    if (!checks.hasCodexDir) missing.push('.codex directory');
    if (!checks.hasSharedState) missing.push('.codex-shared-state directory');
    if (!checks.hasManifest) missing.push('launcher manifest');
    if (!checks.hasState) missing.push('state files');
    if (!checks.hasAgentsMd) missing.push('AGENTS.md');

    debug('SETUP', 'Project setup check', { pp, checks, needsSetup });
    return { needsSetup, checks, missing, path: pp };
});

// === Multi-Project Management ===

ipcMain.handle('add-project', async (event, pp) => {
    if (!pp) {
        const result = await dialog.showOpenDialog(mainWindow, {
            properties: ['openDirectory'],
            title: 'Select Project Directory'
        });
        if (result.canceled || result.filePaths.length === 0) {
            return { success: false, error: 'No directory selected' };
        }
        pp = result.filePaths[0];
    }

    if (!fs.existsSync(pp)) {
        return { success: false, error: 'Directory does not exist' };
    }

    addProjectToRecent(pp);
    const name = path.basename(pp);
    const hasSharedState = fs.existsSync(path.join(pp, '.codex-shared-state'));

    // Set as active project if first one
    if (!projectPath) {
        projectPath = pp;
        if (hasSharedState) {
            startWatching();
        }
    }

    debug('PROJECT', 'Added project', { path: pp, name, hasSharedState });
    return { success: true, path: pp, name, needsSetup: !hasSharedState };
});

ipcMain.handle('switch-project', async (event, pp) => {
    if (!fs.existsSync(pp)) {
        return { success: false, error: 'Project directory does not exist' };
    }

    stopWatching();
    projectPath = pp;
    addProjectToRecent(pp);

    const hasSharedState = fs.existsSync(path.join(pp, '.codex-shared-state'));
    if (hasSharedState) {
        startWatching();
    }

    debug('PROJECT', 'Switched to project', { path: pp, hasSharedState });
    return { success: true, path: pp, needsSetup: !hasSharedState };
});

ipcMain.handle('list-projects', async () => {
    return {
        active: projectPath,
        projects: Array.from(projects.entries()).map(([p, data]) => ({
            path: p,
            name: data.name,
            isActive: p === projectPath,
            hasManifest: fs.existsSync(path.join(p, '.codex', 'launchers', 'manifest.json'))
        }))
    };
});

ipcMain.handle('remove-project', async (event, pp) => {
    projects.delete(pp);
    saveRecentProjectsToDisk();
    if (projectPath === pp) {
        stopWatching();
        // Switch to next available project or clear
        const next = projects.keys().next();
        if (!next.done) {
            projectPath = next.value;
            startWatching();
        } else {
            projectPath = null;
        }
    }
    debug('PROJECT', 'Removed project', { path: pp });
    return { success: true };
});

// === File Watching ===

function startWatching() {
    debug('WATCH', 'Starting file watchers');
    stopWatching();

    const stateDir = path.join(projectPath, '.codex-shared-state');
    debug('WATCH', 'Watching state directory', { stateDir, exists: fs.existsSync(stateDir) });

    stateWatcher = chokidar.watch(stateDir, {
        persistent: true,
        ignoreInitial: true,
        awaitWriteFinish: { stabilityThreshold: 100 }
    });

    stateWatcher.on('change', (filePath) => {
        const filename = path.basename(filePath);
        debug('WATCH', 'State file changed', { filename, filePath });
        mainWindow?.webContents.send('state-changed', filename);
    });

    stateWatcher.on('add', (filePath) => {
        const filename = path.basename(filePath);
        debug('WATCH', 'State file added', { filename });
    });

    stateWatcher.on('error', (error) => {
        debug('WATCH', 'State watcher error', { error: error.message });
    });

    stateWatcher.on('ready', () => {
        debug('WATCH', 'State watcher ready');
    });

    const logPath = getLogPath();
    debug('WATCH', 'Checking log path', { logPath, exists: logPath ? fs.existsSync(logPath) : false });

    if (logPath && fs.existsSync(logPath)) {
        let lastSize = fs.statSync(logPath).size;
        debug('WATCH', 'Log file initial size', { lastSize });

        logWatcher = chokidar.watch(logPath, { persistent: true, ignoreInitial: true });

        logWatcher.on('change', () => {
            try {
                const newSize = fs.statSync(logPath).size;
                debug('WATCH', 'Log file changed', { lastSize, newSize, delta: newSize - lastSize });

                if (newSize > lastSize) {
                    const fd = fs.openSync(logPath, 'r');
                    const buffer = Buffer.alloc(newSize - lastSize);
                    fs.readSync(fd, buffer, 0, buffer.length, lastSize);
                    fs.closeSync(fd);

                    const newLines = buffer.toString('utf-8').split('\n').filter(l => l.trim());
                    if (newLines.length > 0) {
                        debug('WATCH', 'Sending new log lines', { count: newLines.length });
                        mainWindow?.webContents.send('new-log-lines', newLines);
                    }
                }
                lastSize = newSize;
            } catch (e) {
                debug('WATCH', 'Log watch error', { error: e.message });
            }
        });

        logWatcher.on('ready', () => {
            debug('WATCH', 'Log watcher ready');
        });
    } else {
        debug('WATCH', 'Log file does not exist, skipping log watcher');
    }

    // Knowledge directory watcher
    const knowledgeDir = path.join(projectPath, '.codex', 'knowledge');
    if (fs.existsSync(knowledgeDir)) {
        knowledgeWatcher = chokidar.watch(knowledgeDir, {
            persistent: true,
            ignoreInitial: true,
            depth: 2,
            awaitWriteFinish: { stabilityThreshold: 200 }
        });
        knowledgeWatcher.on('change', (filePath) => {
            const filename = path.relative(knowledgeDir, filePath);
            debug('WATCH', 'Knowledge file updated', { filename });
            mainWindow?.webContents.send('knowledge-changed', filename);
        });
        knowledgeWatcher.on('add', (filePath) => {
            const filename = path.relative(knowledgeDir, filePath);
            debug('WATCH', 'Knowledge file created', { filename });
            mainWindow?.webContents.send('knowledge-changed', filename);
        });
    }

    // Signal directory watcher
    const signalDir = path.join(projectPath, '.codex', 'signals');
    if (fs.existsSync(signalDir)) {
        signalWatcher = chokidar.watch(signalDir, {
            persistent: true,
            ignoreInitial: true
        });
        const handleSignal = (filePath) => {
            const filename = path.basename(filePath);
            const timestamp = new Date().toISOString();
            debug('WATCH', 'Signal fired', { filename, timestamp });
            mainWindow?.webContents.send('signal-fired', { signal: filename, timestamp });
        };
        signalWatcher.on('change', handleSignal);
        signalWatcher.on('add', handleSignal);
    }

    debug('WATCH', 'Watchers started successfully');
}

function stopWatching() {
    debug('WATCH', 'Stopping watchers');
    stateWatcher?.close();
    logWatcher?.close();
    knowledgeWatcher?.close();
    signalWatcher?.close();
    stateWatcher = null;
    logWatcher = null;
    knowledgeWatcher = null;
    signalWatcher = null;
}

// === Setup Execution IPC Handlers ===

// Resolve setup script directory
const setupScriptDir = process.env.SETUP_SCRIPT_DIR || path.resolve(__dirname, '..', '..', '..');
debug('INIT', 'Setup script directory', { setupScriptDir });

ipcMain.handle('get-setup-script-dir', async () => {
    return setupScriptDir;
});

ipcMain.handle('run-setup', async (event, { repoUrl, projectPath: pp, workers, sessionMode }) => {
    // Detect platform and choose the right setup script
    const isWindows = process.platform === 'win32';
    let setupScript, spawnCmd, spawnArgs;

    if (isWindows) {
        setupScript = path.join(setupScriptDir, 'setup.ps1');
        if (!fs.existsSync(setupScript)) {
            // Fall back to bash script via Git Bash
            setupScript = path.join(setupScriptDir, '1-setup.sh');
        }
    } else {
        setupScript = path.join(setupScriptDir, '1-setup.sh');
    }

    if (!fs.existsSync(setupScript)) {
        return { success: false, error: `Setup script not found at ${setupScript}` };
    }

    // Expand tilde to home directory
    if (pp && pp.startsWith('~')) {
        pp = pp.replace(/^~/, os.homedir());
    }

    if (isWindows && setupScript.endsWith('.ps1')) {
        // PowerShell arguments
        spawnCmd = 'powershell.exe';
        spawnArgs = ['-ExecutionPolicy', 'Bypass', '-File', setupScript, '-Headless'];
        if (repoUrl) spawnArgs.push('-RepoUrl', repoUrl);
        if (pp) spawnArgs.push('-ProjectPath', pp);
        if (workers) spawnArgs.push('-Workers', String(workers));
        if (sessionMode) spawnArgs.push('-SessionMode', sessionMode);
    } else {
        // Bash arguments
        spawnCmd = 'bash';
        spawnArgs = [setupScript, '--headless'];
        if (repoUrl) spawnArgs.push(`--repo-url=${repoUrl}`);
        if (pp) spawnArgs.push(`--project-path=${pp}`);
        if (workers) spawnArgs.push(`--workers=${workers}`);
        if (sessionMode) spawnArgs.push(`--session-mode=${sessionMode}`);
    }

    debug('SETUP', 'Running headless setup', { setupScript, spawnCmd, spawnArgs });

    return new Promise((resolve) => {
        const child = spawn(spawnCmd, spawnArgs, {
            cwd: path.dirname(setupScript),
            env: { ...process.env, TERM: 'dumb' }
        });

        let output = '';
        let errorOutput = '';

        child.stdout.on('data', (data) => {
            const text = data.toString();
            output += text;
            debug('SETUP', 'stdout', { text: text.slice(0, 200) });
            mainWindow?.webContents.send('setup-progress', { type: 'stdout', text });
        });

        child.stderr.on('data', (data) => {
            const text = data.toString();
            errorOutput += text;
            debug('SETUP', 'stderr', { text: text.slice(0, 200) });
            mainWindow?.webContents.send('setup-progress', { type: 'stderr', text });
        });

        child.on('close', (code) => {
            debug('SETUP', 'Setup complete', { code });
            mainWindow?.webContents.send('setup-progress', { type: 'done', code });
            if (code === 0) {
                // Auto-detect project path from args
                const newProjectPath = pp || null;
                resolve({ success: true, projectPath: newProjectPath, output });
            } else {
                resolve({ success: false, error: `Setup exited with code ${code}`, output, errorOutput });
            }
        });

        child.on('error', (err) => {
            debug('SETUP', 'Setup error', { error: err.message });
            resolve({ success: false, error: err.message });
        });
    });
});

ipcMain.handle('get-recent-projects', async () => {
    const recent = [];
    const seenPaths = new Set();

    // 1. Include all projects from the persistent recent projects map
    for (const [pp, info] of projects) {
        if (!fs.existsSync(pp)) continue;
        seenPaths.add(pp);
        const hasManifest = fs.existsSync(
            path.join(pp, '.codex', 'launchers', 'manifest.json')
        );
        recent.push({
            name: info.name || path.basename(pp),
            path: pp,
            repoUrl: info.repoUrl || null,
            hasManifest,
            isActive: pp === projectPath
        });
    }

    // 2. Also check the legacy config file for any project not already tracked
    const configFile = path.join(os.homedir(), '.codex-multi-agent-config');
    try {
        if (fs.existsSync(configFile)) {
            const content = fs.readFileSync(configFile, 'utf-8');
            const lines = content.split('\n');
            const config = {};
            lines.forEach(line => {
                const [key, ...valueParts] = line.split('=');
                if (key && valueParts.length > 0) {
                    config[key.trim()] = valueParts.join('=').trim();
                }
            });

            if (config.project_path && fs.existsSync(config.project_path) && !seenPaths.has(config.project_path)) {
                const hasManifest = fs.existsSync(
                    path.join(config.project_path, '.codex', 'launchers', 'manifest.json')
                );
                recent.push({
                    name: path.basename(config.project_path),
                    path: config.project_path,
                    repoUrl: config.repo_url || null,
                    hasManifest,
                    isActive: config.project_path === projectPath
                });
                // Migrate legacy project into persistent store
                addProjectToRecent(config.project_path, config.repo_url || null);
            }
        }
    } catch (e) {
        debug('PROJECTS', 'Error reading legacy config', { error: e.message });
    }

    return recent;
});

ipcMain.handle('browse-directory', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
        properties: ['openDirectory', 'createDirectory'],
        title: 'Select Project Directory'
    });
    if (result.canceled || result.filePaths.length === 0) {
        return { success: false, error: 'No directory selected' };
    }
    return { success: true, path: result.filePaths[0] };
});

// === App Lifecycle ===

app.whenReady().then(() => {
    debug('LIFECYCLE', 'App ready');
    createWindow();

    // Auto-start watching if project was passed
    if (projectPath) {
        addProjectToRecent(projectPath);
        debug('LIFECYCLE', 'Auto-starting watchers for project', { projectPath });
        startWatching();
    }
});

app.on('window-all-closed', () => {
    debug('LIFECYCLE', 'All windows closed');
    stopWatching();
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('activate', () => {
    debug('LIFECYCLE', 'App activated');
    if (BrowserWindow.getAllWindows().length === 0) {
        createWindow();
    }
});

debug('INIT', 'Main process initialization complete');
