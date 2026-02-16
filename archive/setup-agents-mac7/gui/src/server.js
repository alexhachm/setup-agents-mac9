const http = require('http');
const fs = require('fs');
const path = require('path');
const chokidar = require('chokidar');
const { execSync } = require('child_process');

const PORT = 3847;
let projectPath = process.argv[2] || process.cwd();

// Validate project path
const stateDir = path.join(projectPath, '.claude-shared-state');
if (!fs.existsSync(stateDir)) {
    console.error('❌ Error: .claude-shared-state directory not found');
    console.error(`   Looking in: ${projectPath}`);
    console.error('');
    console.error('Usage: node server.js [project-path]');
    process.exit(1);
}

// SSE clients
const clients = [];

// File paths
const getStatePath = (file) => path.join(projectPath, '.claude-shared-state', file);
const getLogPath = () => path.join(projectPath, '.claude', 'logs', 'activity.log');

// Start file watchers
function startWatching() {
    const watcher = chokidar.watch(stateDir, {
        persistent: true,
        ignoreInitial: true,
        awaitWriteFinish: { stabilityThreshold: 100 }
    });

    watcher.on('change', (filePath) => {
        const filename = path.basename(filePath);
        broadcast({ type: 'state-changed', filename });
    });

    // Watch activity log
    const logPath = getLogPath();
    if (fs.existsSync(logPath)) {
        let lastSize = fs.statSync(logPath).size;

        chokidar.watch(logPath, { persistent: true, ignoreInitial: true })
            .on('change', () => {
                try {
                    const newSize = fs.statSync(logPath).size;
                    if (newSize > lastSize) {
                        const buffer = Buffer.alloc(newSize - lastSize);
                        const fd = fs.openSync(logPath, 'r');
                        fs.readSync(fd, buffer, 0, buffer.length, lastSize);
                        fs.closeSync(fd);

                        const newLines = buffer.toString('utf-8').split('\n').filter(l => l.trim());
                        if (newLines.length > 0) {
                            broadcast({ type: 'new-log-lines', lines: newLines });
                        }
                    }
                    lastSize = newSize;
                } catch (e) { }
            });
    }

    console.log('👁️  Watching:', stateDir);
}

function broadcast(data) {
    const msg = `data: ${JSON.stringify(data)}\n\n`;
    clients.forEach(res => res.write(msg));
}

// MIME types
const mimeTypes = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.json': 'application/json'
};

// HTTP Server
const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${PORT}`);

    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    // API routes
    if (url.pathname === '/api/events') {
        // SSE endpoint
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive'
        });
        res.write('data: {"type":"connected"}\n\n');
        clients.push(res);
        req.on('close', () => {
            const idx = clients.indexOf(res);
            if (idx > -1) clients.splice(idx, 1);
        });
        return;
    }

    if (url.pathname === '/api/state' && req.method === 'GET') {
        const filename = url.searchParams.get('file');
        try {
            const content = fs.readFileSync(getStatePath(filename), 'utf-8');
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(content);
        } catch (e) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end('{}');
        }
        return;
    }

    if (url.pathname === '/api/log' && req.method === 'GET') {
        try {
            const content = fs.readFileSync(getLogPath(), 'utf-8');
            const lines = content.split('\n').filter(l => l.trim()).slice(-100);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(lines));
        } catch (e) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end('[]');
        }
        return;
    }

    if (url.pathname === '/api/write' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                const { file, data } = JSON.parse(body);
                fs.writeFileSync(getStatePath(file), JSON.stringify(data, null, 2));
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end('{"success":true}');
            } catch (e) {
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(`{"error":"${e.message}"}`);
            }
        });
        return;
    }

    if (url.pathname === '/api/project') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ path: projectPath, name: path.basename(projectPath) }));
        return;
    }

    // Static files
    let filePath = url.pathname === '/' ? '/index.html' : url.pathname;
    filePath = path.join(__dirname, 'renderer', filePath);

    const ext = path.extname(filePath);
    const contentType = mimeTypes[ext] || 'text/plain';

    try {
        const content = fs.readFileSync(filePath);
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(content);
    } catch (e) {
        res.writeHead(404);
        res.end('Not found');
    }
});

// Start
startWatching();
server.listen(PORT, () => {
    console.log('');
    console.log('🧠 Agent Control Center');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log(`📂 Project: ${projectPath}`);
    console.log(`🌐 Open: http://localhost:${PORT}`);
    console.log('');
    console.log('Press Ctrl+C to stop');
    console.log('');

    // Auto-open browser
    try {
        execSync(`open http://localhost:${PORT}`);
    } catch (e) { }
});
