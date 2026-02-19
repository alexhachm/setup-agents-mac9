// NW.js Backend - Runs in Node.js context
const fs = require('fs');
const path = require('path');
const chokidar = require('chokidar');

// Get project path from args or use parent directory
let projectPath = process.argv.find(a => a.startsWith('--project='))?.split('=')[1]
    || path.resolve(__dirname, '../../..');

const stateDir = path.join(projectPath, '.codex-shared-state');
const logPath = path.join(projectPath, '.codex', 'logs', 'activity.log');

// Export functions for renderer
global.backend = {
    projectPath,
    stateDir,

    getState: (filename) => {
        try {
            return JSON.parse(fs.readFileSync(path.join(stateDir, filename), 'utf-8'));
        } catch (e) {
            return null;
        }
    },

    getActivityLog: (lines = 100) => {
        try {
            const content = fs.readFileSync(logPath, 'utf-8');
            return content.split('\n').filter(l => l.trim()).slice(-lines);
        } catch (e) {
            return [];
        }
    },

    writeState: (filename, data) => {
        try {
            fs.writeFileSync(path.join(stateDir, filename), JSON.stringify(data, null, 2));
            return { success: true };
        } catch (e) {
            return { success: false, error: e.message };
        }
    },

    selectProject: () => {
        // Will be handled via file dialog in renderer
        return null;
    },

    stateWatcher: null,
    logWatcher: null,

    startWatching: (onStateChange, onLogLines) => {
        // Watch state files
        global.backend.stateWatcher = chokidar.watch(stateDir, {
            persistent: true,
            ignoreInitial: true,
            awaitWriteFinish: { stabilityThreshold: 100 }
        });

        global.backend.stateWatcher.on('change', (filePath) => {
            const filename = path.basename(filePath);
            onStateChange(filename);
        });

        // Watch log
        if (fs.existsSync(logPath)) {
            let lastSize = fs.statSync(logPath).size;

            global.backend.logWatcher = chokidar.watch(logPath, {
                persistent: true,
                ignoreInitial: true
            });

            global.backend.logWatcher.on('change', () => {
                try {
                    const newSize = fs.statSync(logPath).size;
                    if (newSize > lastSize) {
                        const fd = fs.openSync(logPath, 'r');
                        const buffer = Buffer.alloc(newSize - lastSize);
                        fs.readSync(fd, buffer, 0, buffer.length, lastSize);
                        fs.closeSync(fd);

                        const newLines = buffer.toString('utf-8').split('\n').filter(l => l.trim());
                        if (newLines.length > 0) {
                            onLogLines(newLines);
                        }
                    }
                    lastSize = newSize;
                } catch (e) { }
            });
        }

        console.log('Started watching:', stateDir);
    }
};

console.log('Backend initialized for project:', projectPath);
