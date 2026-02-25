// Agent Control Center v2 - Full Feature Renderer
// Features: Timeline, Agent Health, Tier Classification, Knowledge, Signals, Lifecycle, Stats

// ═══════════════════════════════════════════════════════════════════════════
// DEBUG + CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════
const DEBUG_LOG = [];
const MAX_DEBUG = 500;
const DEBUG_RENDERER = localStorage.getItem('acc-debug') === '1' || window.location.search.includes('debug=1');
const IS_MAC = navigator.platform === 'MacIntel' || navigator.userAgent.includes('Mac');
const HEALTH_POLL_MS_NORMAL = IS_MAC ? 12000 : 6000;
const HEALTH_POLL_MS_URGENT = IS_MAC ? 8000 : 4000;
const SIGNAL_AGE_REFRESH_MS = IS_MAC ? 5000 : 3000;
const WATCHDOG_REFRESH_MS = IS_MAC ? 45000 : 30000;
const PHASE_COLORS = {
    handoff: '#6e7681', triage: '#a371f7', decomposition: '#8b5cf6',
    allocation: '#d29922', worker: '#58a6ff', validation: '#79c0ff', integration: '#3fb950'
};
const TIER_COLORS = { 1: '#3fb950', 2: '#58a6ff', 3: '#d29922' };
const TIER_LABELS = { 1: 'Direct execution', 2: 'Single worker', 3: 'Full pipeline' };
const TOKEN_BUDGETS = {
    'codebase-insights.md': 2000, 'patterns.md': 1000, 'mistakes.md': 1000,
    'instruction-patches.md': null
};
const DOMAIN_TOKEN_BUDGET = 800;

// ═══════════════════════════════════════════════════════════════════════════
// DIRTY-FLAG RENDER SYSTEM (rAF debounce)
// ═══════════════════════════════════════════════════════════════════════════
const _dirty = new Set();
let _renderScheduled = false;

function markDirty(...sections) {
    sections.forEach(s => _dirty.add(s));
    scheduleRender();
}

function markAllDirty() {
    ['pipeline', 'workers', 'activity', 'masters', 'clarification', 'requests'].forEach(s => _dirty.add(s));
    scheduleRender();
}

function scheduleRender() {
    if (_renderScheduled) return;
    _renderScheduled = true;
    requestAnimationFrame(() => {
        _renderScheduled = false;
        flushRender();
    });
}

function flushRender() {
    if (_dirty.has('pipeline')) { renderAnimatedPipeline(); renderPipeline(); }
    if (_dirty.has('workers')) renderWorkers();
    if (_dirty.has('activity')) renderActivityLogFull();
    if (_dirty.has('masters')) updateMasterStatus();
    if (_dirty.has('clarification')) updateClarificationBanner();
    if (_dirty.has('requests')) renderRequestList();
    _dirty.clear();
}

function debugLog(category, message, data = null) {
    const entry = {
        timestamp: new Date().toISOString(), source: 'RENDERER', category, message,
        data: data ? JSON.stringify(data).slice(0, 500) : null
    };
    DEBUG_LOG.push(entry);
    if (DEBUG_LOG.length > MAX_DEBUG) DEBUG_LOG.splice(0, DEBUG_LOG.length - MAX_DEBUG);
    if (DEBUG_RENDERER) {
        console.log(`[${category}] ${message}`, data || '');
    }
    if (elements.debugPanel && !elements.debugPanel.classList.contains('hidden')) appendDebugEntry(entry);
}
function appendDebugEntry(entry) {
    const dl = document.getElementById('debug-log-list');
    if (!dl) return;
    const sc = entry.source === 'MAIN' ? 'main-source' : 'renderer-source';
    dl.insertAdjacentHTML('beforeend', `<div class="debug-entry ${sc}">
        <span class="debug-time">${entry.timestamp.split('T')[1]?.slice(0, 8) || ''}</span>
        <span class="debug-source">${entry.source}</span>
        <span class="debug-cat">${entry.category}</span>
        <span class="debug-msg">${entry.message}</span></div>`);
    if (document.getElementById('debug-autoscroll')?.checked) dl.scrollTop = dl.scrollHeight;
}

// ═══════════════════════════════════════════════════════════════════════════
// STATE
// ═══════════════════════════════════════════════════════════════════════════
let state = {
    workers: {}, taskQueue: null, handoff: null,
    clarifications: { questions: [], responses: [] },
    fixQueue: null, codebaseMap: null, activityLog: [],
    pendingClarification: null, projectName: '',
    master2Ready: false, master3Ready: false, selectedDetail: null,
    // v2 state
    activeTab: 'pipeline', agentHealth: null, knowledgeFiles: [],
    signalHistory: [], tierClassifications: {}, requestTimers: {},
    selectedKnowledgeFile: null, healthPollInterval: null, signalAgeInterval: null,
    launchCommands: [],
    // Chat state
    chatMessages: [],
    chatMessageIds: new Set(),
    isThinking: false,
    fileTree: null
};

// ═══════════════════════════════════════════════════════════════════════════
// DOM ELEMENTS
// ═══════════════════════════════════════════════════════════════════════════
const elements = {
    connectionScreen: document.getElementById('connection-screen'),
    dashboardScreen: document.getElementById('dashboard-screen'),
    selectProjectBtn: document.getElementById('select-project-btn'),
    addProjectBtn: document.getElementById('add-project-btn'),
    projectTabs: document.getElementById('project-tabs'),
    connectionError: document.getElementById('connection-error'),
    projectName: document.getElementById('project-name'),
    commandInput: document.getElementById('command-input'),
    sendBtn: document.getElementById('send-btn'),
    clarificationBanner: document.getElementById('clarification-banner'),
    clarificationQuestion: document.getElementById('clarification-question'),
    m1Status: document.getElementById('m1-status'),
    m2Status: document.getElementById('m2-status'),
    m3Status: document.getElementById('m3-status'),
    m2ReadyDot: document.getElementById('m2-ready-dot'),
    m3ReadyDot: document.getElementById('m3-ready-dot'),
    workerGrid: document.getElementById('worker-grid'),
    workerSummary: document.getElementById('worker-summary'),
    activityLog: document.getElementById('activity-log'),
    autoscroll: document.getElementById('autoscroll'),
    inputCount: document.getElementById('input-count'),
    decompCount: document.getElementById('decomp-count'),
    queueCount: document.getElementById('queue-count'),
    activeCount: document.getElementById('active-count'),
    inputItems: document.getElementById('input-items'),
    decompItems: document.getElementById('decomp-items'),
    queueItems: document.getElementById('queue-items'),
    activeItems: document.getElementById('active-items'),
    detailPanel: document.getElementById('detail-panel'),
    detailTitle: document.getElementById('detail-title'),
    detailContent: document.getElementById('detail-content'),
    closeDetailBtn: document.getElementById('close-detail-btn'),
    debugPanel: document.getElementById('debug-panel'),
    debugToggleBtn: document.getElementById('debug-toggle-btn'),
    refreshFilesBtn: document.getElementById('refresh-files-btn'),
    filesList: document.getElementById('files-list'),
    rawStateDisplay: document.getElementById('raw-state-display'),
    // v2 elements
    staggerBanner: document.getElementById('stagger-banner'),
    staggerMessage: document.getElementById('stagger-message'),
    toastContainer: document.getElementById('toast-container'),
    requestList: document.getElementById('request-list'),
    timelineSelect: document.getElementById('timeline-request-select'),
    timelineChart: document.getElementById('timeline-chart'),
    timelineSummary: document.getElementById('timeline-summary'),
    healthCards: document.getElementById('health-cards'),
    healthUpdateTime: document.getElementById('health-update-time'),
    knowledgeFileList: document.getElementById('knowledge-file-list'),
    knowledgeFileName: document.getElementById('knowledge-file-name'),
    knowledgeFileMeta: document.getElementById('knowledge-file-meta'),
    knowledgeFileContent: document.getElementById('knowledge-file-content'),
    signalPills: document.getElementById('signal-pills'),
    signalHistory: document.getElementById('signal-history'),
    signalCount: document.getElementById('signal-count'),
    statsContent: document.getElementById('stats-content')
};

// ═══════════════════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════
async function init() {
    debugLog('INIT', 'Starting v2 initialization');
    setupEventListeners();
    // Load recent projects on the setup screen
    await loadRecentProjects();
    // Check if a project was already passed via args
    await checkConnection();
}

function setupEventListeners() {
    elements.selectProjectBtn?.addEventListener('click', selectProject);
    elements.addProjectBtn?.addEventListener('click', () => {
        // Navigate back to setup screen to add a new project
        stopWatchdogPolling();
        stopHealthPolling();
        stopSignalAgeUpdater();
        elements.dashboardScreen.classList.remove('active');
        elements.connectionScreen.classList.add('active');
        loadRecentProjects();
    });
    elements.sendBtn?.addEventListener('click', sendCommand);
    elements.commandInput?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendCommand(); }
    });
    elements.debugToggleBtn?.addEventListener('click', toggleDebugPanel);
    elements.refreshFilesBtn?.addEventListener('click', refreshFiles);
    elements.closeDetailBtn?.addEventListener('click', closeDetailPanel);

    // Collapse buttons
    document.querySelectorAll('.collapse-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const t = document.getElementById(btn.dataset.target);
            if (t) { t.classList.toggle('collapsed'); btn.textContent = t.classList.contains('collapsed') ? '+' : '−'; }
        });
    });

    // Tab navigation
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    // Timeline controls
    elements.timelineSelect?.addEventListener('change', () => {
        const rid = elements.timelineSelect.value;
        if (rid) loadTimeline(rid);
    });
    document.getElementById('timeline-refresh-btn')?.addEventListener('click', populateRequestDropdown);

    // Stats controls
    document.getElementById('stats-refresh-btn')?.addEventListener('click', computeSessionStats);
    document.getElementById('stats-export-json-btn')?.addEventListener('click', () => exportStats('json'));
    document.getElementById('stats-export-md-btn')?.addEventListener('click', () => exportStats('md'));

    // Launch controls
    document.getElementById('launch-everything-btn')?.addEventListener('click', launchEverything);
    document.getElementById('launch-all-masters-btn')?.addEventListener('click', () => launchAgentGroup('masters'));
    document.getElementById('launch-all-workers-btn')?.addEventListener('click', () => launchAgentGroup('workers'));
    document.getElementById('launch-add-project-btn')?.addEventListener('click', addNewProject);
    document.getElementById('launch-project-select')?.addEventListener('change', (e) => {
        if (e.target.value) switchToProject(e.target.value);
    });

    // File tree
    document.getElementById('file-tree-refresh')?.addEventListener('click', loadFileTree);

    // Setup screen controls
    document.getElementById('setup-run-btn')?.addEventListener('click', handleSetup);
    document.getElementById('setup-browse-btn')?.addEventListener('click', async () => {
        const result = await window.electron.browseDirectory();
        if (result.success) {
            document.getElementById('setup-project-path').value = result.path;
        }
    });
    document.getElementById('setup-repo-url')?.addEventListener('input', (e) => {
        // Auto-suggest project path from repo URL
        const url = e.target.value.trim();
        const pathInput = document.getElementById('setup-project-path');
        if (url && !pathInput.value) {
            const repoName = url.split('/').pop()?.replace('.git', '') || 'my-project';
            pathInput.placeholder = `~/Desktop/${repoName}`;
        }
    });

    // Setup progress listener
    window.electron.onSetupProgress((data) => {
        const console = document.getElementById('setup-console');
        if (!console) return;
        if (data.type === 'stdout' || data.type === 'stderr') {
            console.textContent += stripAnsi(data.text);
            console.scrollTop = console.scrollHeight;
        } else if (data.type === 'done') {
            const badge = document.getElementById('setup-status-badge');
            if (data.code === 0) {
                badge.textContent = 'Complete';
                badge.className = 'setup-status-badge success';
            } else {
                badge.textContent = 'Failed';
                badge.className = 'setup-status-badge error';
            }
        }
    });

    // Real-time listeners
    window.electron.onStateChanged(handleStateChanged);
    window.electron.onNewLogLines(handleNewLogLines);
    window.electron.onDebugLog((entry) => {
        entry.source = 'MAIN';
        DEBUG_LOG.push(entry);
        if (elements.debugPanel && !elements.debugPanel.classList.contains('hidden')) appendDebugEntry(entry);
    });
    window.electron.onKnowledgeChanged((filename) => {
        debugLog('KNOWLEDGE', 'File changed', { filename });
        if (state.activeTab === 'knowledge') loadKnowledge();
    });
    window.electron.onSignalFired((data) => {
        debugLog('SIGNAL', 'Signal fired', data);
        handleSignalFired(data);
    });
}

function switchTab(tabName) {
    state.activeTab = tabName;
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === tabName));
    document.querySelectorAll('.tab-content').forEach(c => c.classList.toggle('active', c.dataset.tab === tabName));

    // Load data for newly active tab
    if (tabName === 'pipeline') markAllDirty();
    else if (tabName === 'timeline') populateRequestDropdown();
    else if (tabName === 'health') startHealthPolling();
    else if (tabName === 'knowledge') loadKnowledge();
    else if (tabName === 'signals') loadSignals();
    else if (tabName === 'stats') computeSessionStats();
    else if (tabName === 'launch') loadLaunchPanel();

    if (tabName !== 'health') stopHealthPolling();
    if (tabName !== 'signals') stopSignalAgeUpdater();
}

async function checkConnection() {
    try {
        const project = await window.electron.getProject();
        if (project) {
            state.projectName = project.name;
            elements.projectName.textContent = project.name;
            showDashboard();
            await loadAllState();
        }
    } catch (e) { debugLog('CONN', 'Connection check error', { error: e.message }); }
}

async function selectProject() {
    elements.connectionError.textContent = '';
    try {
        const result = await window.electron.selectProject();
        if (result.success) {
            state.projectName = result.path.split('/').pop();
            elements.projectName.textContent = state.projectName;
            showDashboard();
            await loadAllState();
        } else { elements.connectionError.textContent = result.error; }
    } catch (e) { elements.connectionError.textContent = e.message; }
}

function showDashboard() {
    elements.connectionScreen.classList.remove('active');
    elements.dashboardScreen.classList.add('active');
    renderProjectTabs();
    startWatchdogPolling();
}

async function renderProjectTabs() {
    const tabsContainer = elements.projectTabs;
    if (!tabsContainer) return;
    try {
        const projects = await window.electron.getRecentProjects();
        const currentProject = state.projectName;
        if (!projects || projects.length === 0) {
            tabsContainer.innerHTML = currentProject
                ? `<div class="project-tab active"><span>${escapeHtml(currentProject)}</span></div>`
                : '';
            return;
        }
        tabsContainer.innerHTML = projects.map(p => {
            const name = p.name || p.path.split('/').pop();
            const isActive = name === currentProject || p.path.endsWith('/' + currentProject);
            return `<div class="project-tab ${isActive ? 'active' : ''}"
                data-project-path="${escapeHtml(p.path)}" title="${escapeHtml(p.path)}">
                <span>${escapeHtml(name)}</span>
                <span class="tab-close">✕</span>
            </div>`;
        }).join('');

        // Attach click handlers using data attributes
        tabsContainer.querySelectorAll('.project-tab').forEach(tab => {
            const pp = tab.dataset.projectPath;
            tab.addEventListener('click', () => window.openExistingProject(pp));
            tab.querySelector('.tab-close')?.addEventListener('click', (e) => {
                e.stopPropagation();
                removeProjectTab(pp);
            });
        });
    } catch (e) {
        debugLog('TABS', 'Error rendering project tabs', { error: e.message });
    }
}

window.removeProjectTab = async function (projectPath) {
    try {
        await window.electron.removeProject(projectPath);
        renderProjectTabs();
    } catch (e) {
        debugLog('TABS', 'Error removing project', { error: e.message });
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SETUP FLOW (GUI-first)
// ═══════════════════════════════════════════════════════════════════════════
function stripAnsi(text) {
    return text.replace(/\x1B\[[0-9;]*[A-Za-z]/g, '').replace(/\x1B\([A-Za-z]/g, '');
}

async function loadRecentProjects() {
    debugLog('SETUP', 'Loading recent projects');
    try {
        const projects = await window.electron.getRecentProjects();
        const list = document.getElementById('recent-projects-list');
        if (!list) return;

        if (!projects || projects.length === 0) {
            list.innerHTML = '<div class="recent-empty">No recent projects found</div>';
            return;
        }

        list.innerHTML = projects.map(p => `
            <div class="recent-project-card" data-project-path="${escapeHtml(p.path)}">
                <div class="recent-project-info">
                    <div class="recent-project-name">${escapeHtml(p.name)}</div>
                    <div class="recent-project-path">${escapeHtml(p.path)}</div>
                    ${p.repoUrl ? `<div class="recent-project-repo">${escapeHtml(p.repoUrl)}</div>` : ''}
                </div>
                <div class="recent-project-actions">
                    ${p.hasManifest ? '<span class="recent-manifest-badge">✓ Ready</span>' : ''}
                    <button class="secondary-btn open-project-btn">Open</button>
                </div>
            </div>
        `).join('');

        // Attach click handlers using data attributes (avoids backslash escaping issues)
        list.querySelectorAll('.recent-project-card').forEach(card => {
            const pp = card.dataset.projectPath;
            card.addEventListener('click', () => openExistingProject(pp));
            card.querySelector('.open-project-btn')?.addEventListener('click', (e) => {
                e.stopPropagation();
                openExistingProject(pp);
            });
        });
    } catch (e) {
        debugLog('SETUP', 'Error loading recent projects', { error: e.message });
    }
}

window.openExistingProject = async function (projectPathStr) {
    debugLog('SETUP', 'Opening existing project', { path: projectPathStr });
    // Extract project name from path (handle both / and \ separators)
    const projectName = projectPathStr.split(/[/\\]/).pop();
    try {
        // Switch to this project
        const result = await window.electron.switchProject(projectPathStr);
        if (result.success) {
            state.projectName = projectName;
            elements.projectName.textContent = state.projectName;

            // Check if setup is needed
            if (result.needsSetup) {
                debugLog('SETUP', 'Project needs setup', { path: projectPathStr });
                showSetupNeeded(projectPathStr, projectName);
                return;
            }

            showDashboard();
            await loadAllState();
            // Auto-switch to launch tab
            switchTab('launch');
        } else {
            // Try adding it first then switching
            const addResult = await window.electron.addProject(projectPathStr);
            if (addResult.success && addResult.needsSetup) {
                state.projectName = projectName;
                elements.projectName.textContent = state.projectName;
                showSetupNeeded(projectPathStr, projectName);
                return;
            }
            const r2 = await window.electron.switchProject(projectPathStr);
            if (r2.success) {
                state.projectName = projectName;
                elements.projectName.textContent = state.projectName;
                if (r2.needsSetup) {
                    showSetupNeeded(projectPathStr, projectName);
                    return;
                }
                showDashboard();
                await loadAllState();
                switchTab('launch');
            } else {
                elements.connectionError.textContent = r2.error || 'Failed to open project';
            }
        }
    } catch (e) {
        elements.connectionError.textContent = e.message;
    }
};

async function showSetupNeeded(projectPathStr, projectName) {
    // Check what specifically is missing
    const setupStatus = await window.electron.checkProjectSetup(projectPathStr);
    const missingList = (setupStatus.missing || []).join(', ');

    // Show setup screen pre-populated with this project
    elements.dashboardScreen.classList.remove('active');
    elements.connectionScreen.classList.add('active');

    // Pre-fill the setup form
    const pathInput = document.getElementById('setup-project-path');
    const repoInput = document.getElementById('setup-repo-url');
    if (pathInput) pathInput.value = projectPathStr;

    // Try to detect repo URL from recent projects data
    try {
        const recentProjects = await window.electron.getRecentProjects();
        const match = recentProjects.find(p => p.path === projectPathStr);
        if (match?.repoUrl && repoInput) {
            repoInput.value = match.repoUrl;
        }
    } catch (e) { /* ignore */ }

    // Show a banner explaining what's needed
    elements.connectionError.textContent = '';
    const setupBanner = document.getElementById('setup-needed-banner');
    if (setupBanner) {
        setupBanner.classList.remove('hidden');
        setupBanner.innerHTML = `<strong>${escapeHtml(projectName)}</strong> is missing orchestration files (${escapeHtml(missingList)}). Run setup to initialize.`;
    } else {
        // Create the banner if it doesn't exist
        const banner = document.createElement('div');
        banner.id = 'setup-needed-banner';
        banner.className = 'setup-needed-banner';
        banner.innerHTML = `<strong>${escapeHtml(projectName)}</strong> is missing orchestration files (${escapeHtml(missingList)}). Run setup to initialize.`;
        const setupForm = document.getElementById('setup-form') || document.querySelector('.setup-section');
        if (setupForm) {
            setupForm.parentNode.insertBefore(banner, setupForm);
        } else {
            elements.connectionScreen.querySelector('.connection-content')?.prepend(banner);
        }
    }

    debugLog('SETUP', 'Showing setup-needed screen', { projectName, missing: setupStatus.missing });
}

async function handleSetup() {
    const repoUrl = document.getElementById('setup-repo-url')?.value.trim() || '';
    let projectPath = document.getElementById('setup-project-path')?.value.trim() || '';
    const workers = document.getElementById('setup-workers')?.value || '3';
    const sessionMode = document.querySelector('input[name="setup-mode"]:checked')?.value;

    // If no path, derive from repo URL or use default
    if (!projectPath && repoUrl) {
        const repoName = repoUrl.split('/').pop()?.replace('.git', '') || 'my-project';
        projectPath = `~/Desktop/${repoName}`;
    }

    if (!projectPath) {
        elements.connectionError.textContent = 'Please specify a project path';
        return;
    }

    debugLog('SETUP', 'Starting setup', { repoUrl, projectPath, workers, sessionMode });

    // Show progress panel
    const progressPanel = document.getElementById('setup-progress-panel');
    const console = document.getElementById('setup-console');
    const badge = document.getElementById('setup-status-badge');
    const runBtn = document.getElementById('setup-run-btn');

    progressPanel?.classList.remove('hidden');
    if (console) console.textContent = '';
    if (badge) {
        badge.textContent = 'Running…';
        badge.className = 'setup-status-badge';
    }
    if (runBtn) runBtn.disabled = true;
    elements.connectionError.textContent = '';

    try {
        // Don't pass sessionMode — setup creates files/worktrees/manifest
        // but skips terminal launches. The GUI's Launch tab handles launching.
        const result = await window.electron.runSetup({
            repoUrl: repoUrl || undefined,
            projectPath,
            workers
        });

        if (result.success) {
            debugLog('SETUP', 'Setup completed successfully', { projectPath: result.projectPath });
            // Auto-open the project
            if (result.projectPath) {
                setTimeout(() => openExistingProject(result.projectPath), 1500);
            }
        } else {
            elements.connectionError.textContent = result.error || 'Setup failed';
        }
    } catch (e) {
        elements.connectionError.textContent = e.message;
        if (badge) {
            badge.textContent = 'Error';
            badge.className = 'setup-status-badge error';
        }
    } finally {
        if (runBtn) runBtn.disabled = false;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STATE LOADING
// ═══════════════════════════════════════════════════════════════════════════
async function loadAllState() {
    debugLog('STATE', 'Loading all state');
    state.workers = await window.electron.getState('worker-status.json') || {};
    state.taskQueue = await window.electron.getState('task-queue.json');
    state.handoff = await window.electron.getState('handoff.json');
    state.clarifications = await window.electron.getState('clarification-queue.json') || { questions: [], responses: [] };
    state.fixQueue = await window.electron.getState('fix-queue.json');
    state.codebaseMap = await window.electron.getState('codebase-map.json');
    state.launchCommands = state.codebaseMap?.launch_commands || [];
    state.agentHealth = await window.electron.getAgentHealth();
    const logLines = await window.electron.getActivityLog(100);
    state.activityLog = logLines.map(parseLogLine).filter(Boolean);
    checkMasterReadiness();
    renderAll();
    loadFileTree();
    debugLog('STATE', 'State loading complete');
}

async function handleStateChanged(filename) {
    debugLog('STATE', 'File changed', { filename });
    switch (filename) {
        case 'worker-status.json':
            state.workers = await window.electron.getState(filename) || {};
            markDirty('pipeline', 'workers', 'masters');
            break;
        case 'task-queue.json':
            state.taskQueue = await window.electron.getState(filename);
            markDirty('pipeline', 'requests');
            break;
        case 'handoff.json':
            state.handoff = await window.electron.getState(filename);
            markDirty('pipeline', 'masters', 'requests');
            break;
        case 'clarification-queue.json':
            state.clarifications = await window.electron.getState(filename) || { questions: [], responses: [] };
            markDirty('clarification');
            break;
        case 'fix-queue.json':
            state.fixQueue = await window.electron.getState(filename);
            break;
        case 'codebase-map.json':
            state.codebaseMap = await window.electron.getState(filename);
            state.launchCommands = state.codebaseMap?.launch_commands || [];
            checkMasterReadiness();
            renderProjectLaunchCommands();
            markDirty('masters');
            break;
        case 'agent-health.json':
            state.agentHealth = await window.electron.getAgentHealth();
            checkAgentHealthScanStatus();
            if (state.activeTab === 'health') loadAgentHealth();
            markDirty('pipeline', 'workers', 'masters');
            break;
    }
    refreshRawState();
}

function handleNewLogLines(lines) {
    const entries = lines.map(parseLogLine).filter(Boolean);
    state.activityLog.push(...entries);
    if (state.activityLog.length > 500) state.activityLog = state.activityLog.slice(-500);

    entries.forEach(entry => {
        if (entry.agent.includes('master-2') && entry.action === 'SCAN_COMPLETE') state.master2Ready = true;
        if (entry.agent.includes('master-3') && entry.action === 'SCAN_COMPLETE') state.master3Ready = true;
        if (entry.agent.includes('master-2') && entry.details.includes('loop')) state.master2Ready = true;
        if (entry.agent.includes('master-3') && (entry.details.includes('loop') || entry.details.includes('allocat'))) state.master3Ready = true;

        // Feature 3: Tier classification detection
        if (entry.agent.includes('master-2') && entry.action === 'TIER_CLASSIFY') {
            const tierMatch = entry.details.match(/tier[=:\s]*(\d)/i);
            const tier = tierMatch ? parseInt(tierMatch[1]) : null;
            const reqMatch = entry.details.match(/(?:request|id)[=:\s]*([^\s,]+)/i);
            const reqId = reqMatch ? reqMatch[1] : null;
            if (tier && reqId) {
                state.tierClassifications[reqId] = { tier, reasoning: entry.details, timestamp: entry.time };
                showTierToast(reqId, tier, entry.details);
                renderRequestList();
            }
        }
    });

    renderActivityLog(entries);
    updateMasterStatus();
    // Feed relevant entries into chat
    entries.forEach(entry => chatFromLogEntry(entry));
}

function checkMasterReadiness() {
    if (state.codebaseMap && Object.keys(state.codebaseMap).length > 0) state.master2Ready = true;
    state.activityLog.forEach(entry => {
        if (entry.agent.includes('master-2') && (entry.action === 'SCAN_COMPLETE' || entry.details.toLowerCase().includes('architect'))) state.master2Ready = true;
        if (entry.agent.includes('master-3') && (entry.action === 'SCAN_COMPLETE' || entry.details.toLowerCase().includes('allocat'))) state.master3Ready = true;
    });
}

// Check agent-health.json for scan completion (more reliable than log parsing)
async function checkAgentHealthScanStatus() {
    try {
        const health = await window.electron.getAgentHealth();
        if (!health) return;

        // Master-2: use effectiveStatus to determine readiness
        if (health['master-2']) {
            const es = health['master-2'].effectiveStatus || health['master-2'].status;
            if (es === 'active') {
                if (!state.master2Ready) {
                    state.master2Ready = true;
                    debugLog('SCAN', 'Master-2 scan complete (detected from agent-health.json)');
                }
            } else if (es === 'stopped' || es === 'stale') {
                state.master2Ready = false;
                debugLog('SCAN', `Master-2 is ${es} — marking not ready`);
            }
        }

        // Master-3: use effectiveStatus to determine readiness
        if (health['master-3']) {
            const es = health['master-3'].effectiveStatus || health['master-3'].status;
            if (es === 'active') {
                if (!state.master3Ready) {
                    state.master3Ready = true;
                    debugLog('SCAN', 'Master-3 scan complete (detected from agent-health.json)');
                }
            } else if (es === 'stopped' || es === 'stale') {
                state.master3Ready = false;
                debugLog('SCAN', `Master-3 is ${es} — marking not ready`);
            }
        }

        updateMasterStatus();
    } catch (e) {
        debugLog('SCAN', 'Error checking agent health', { error: e.message });
    }
}

function buildRequestId(text) {
    const stem = text
        .toLowerCase()
        .replace(/[^a-z0-9\s-]/g, ' ')
        .split(/\s+/)
        .filter(w => w.length > 2)
        .slice(0, 4)
        .join('-')
        .replace(/-+/g, '-')
        .replace(/^-|-$/g, '');
    return stem || `request-${Date.now()}`;
}

async function emitSignal(signalName) {
    const result = await window.electron.touchSignal(signalName);
    if (!result?.success) {
        throw new Error(result?.error || `Failed to emit signal: ${signalName}`);
    }
}

let watchdogTimer = null;
async function refreshWatchdogState() {
    if (document.hidden || !state.projectName) return;
    try {
        const [workers, taskQueue, handoff, clarifications, fixQueue, health] = await Promise.all([
            window.electron.getState('worker-status.json'),
            window.electron.getState('task-queue.json'),
            window.electron.getState('handoff.json'),
            window.electron.getState('clarification-queue.json'),
            window.electron.getState('fix-queue.json'),
            window.electron.getAgentHealth()
        ]);

        const newWorkers = workers || {};
        const newHandoff = handoff;
        // Only re-render if data actually changed
        const workersChanged = JSON.stringify(newWorkers) !== JSON.stringify(state.workers);
        const handoffChanged = JSON.stringify(newHandoff) !== JSON.stringify(state.handoff);
        state.workers = newWorkers;
        state.taskQueue = taskQueue;
        state.handoff = newHandoff;
        state.clarifications = clarifications || { questions: [], responses: [] };
        state.fixQueue = fixQueue;
        state.agentHealth = health;
        if (workersChanged || handoffChanged) {
            markAllDirty();
        }
    } catch (e) {
        debugLog('WATCHDOG', 'Error refreshing fallback state', { error: e.message });
    }
}

function startWatchdogPolling() {
    stopWatchdogPolling();
    watchdogTimer = setInterval(refreshWatchdogState, WATCHDOG_REFRESH_MS);
}

function stopWatchdogPolling() {
    if (watchdogTimer) {
        clearInterval(watchdogTimer);
        watchdogTimer = null;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// COMMAND INPUT
// ═══════════════════════════════════════════════════════════════════════════
async function sendCommand() {
    const text = elements.commandInput.value.trim();
    if (!text) return;
    debugLog('CMD', 'Sending command', { text });
    elements.commandInput.value = '';
    elements.sendBtn.disabled = true;
    try {
        if (state.pendingClarification) {
            const q = { ...state.clarifications };
            q.questions = q.questions.map(qu =>
                qu.request_id === state.pendingClarification.request_id && qu.question === state.pendingClarification.question
                    ? { ...qu, status: 'answered' } : qu);
            q.responses = [...q.responses, {
                request_id: state.pendingClarification.request_id,
                question: state.pendingClarification.question, answer: text, timestamp: new Date().toISOString()
            }];
            await window.electron.writeState('clarification-queue.json', q);
            state.pendingClarification = null;
        } else if (text.toLowerCase().startsWith('fix worker-')) {
            const match = text.match(/fix\s+(worker-\d+):\s*(.+)/i);
            if (match) {
                const [, worker, issue] = match;
                await window.electron.writeState('fix-queue.json', {
                    worker,
                    task: {
                        subject: `FIX: ${issue.slice(0, 50)}`, description: `PRIORITY: URGENT\nDOMAIN: ${state.workers[worker]?.domain || 'unknown'}\n\n${issue}`,
                        request_id: `fix-${Date.now()}`
                    }
                });
                await emitSignal('.fix-signal');
            } else {
                debugLog('CMD', 'Fix command ignored: invalid format', { text });
            }
        } else {
            const requestId = buildRequestId(text);
            addChatMessage({ role: 'user', content: text, timestamp: new Date().toISOString() });
            await window.electron.writeState('handoff.json', {
                request_id: requestId, timestamp: new Date().toISOString(),
                type: 'feature', description: text, tasks: [], success_criteria: [], status: 'pending_decomposition'
            });
            await emitSignal('.handoff-signal');
            addChatMessage({ id: `submitted-${requestId}`, role: 'system', content: `Request submitted: ${requestId}`, timestamp: new Date().toISOString() });
            showTypingIndicator(true);
        }
    } catch (e) { debugLog('CMD', 'Error', { error: e.message }); }
    elements.sendBtn.disabled = false;
    elements.commandInput.focus();
}

// ═══════════════════════════════════════════════════════════════════════════
// RENDERING (Dashboard)
// ═══════════════════════════════════════════════════════════════════════════
function renderAll() {
    markAllDirty();
}

// ═══════════════════════════════════════════════════════════════════════════
// ANIMATED PIPELINE CARD
// ═══════════════════════════════════════════════════════════════════════════
let expandedPipelineWorker = null;

window.togglePipeWorker = function (id) {
    expandedPipelineWorker = expandedPipelineWorker === id ? null : id;
    renderAnimatedPipeline();
};

function formatHbAge(isoStr) {
    if (!isoStr) return '?';
    const diff = Date.now() - new Date(isoStr).getTime();
    if (isNaN(diff) || diff < 0) return '?';
    const s = Math.floor(diff / 1000);
    return s < 60 ? `${s}s ago` : `${Math.floor(s / 60)}m ago`;
}

function derivePipelineStages() {
    const handoff = state.handoff || {};
    const workers = state.workers || {};
    const taskQueue = state.taskQueue || {};
    const status = handoff.status || '';

    // Resolve tier from explicit field, then infer from status/context
    let tier = handoff.tier || taskQueue.tier || null;
    if (!tier) {
        if (status === 'completed_tier1') tier = 1;
        else if (status === 'assigned_tier2' || status.includes('tier2')) tier = 2;
        else if (status === 'decomposed' || (taskQueue?.tasks?.length > 1)) tier = 3;
        else if (taskQueue?.tasks?.length === 1) tier = 2;
    }

    // Detect active workers from worker-status for additional context
    const workerEntries = Object.entries(workers);
    const busyWorkers = workerEntries.filter(([wid, w]) => {
        const es = state.agentHealth?.workers?.[wid]?.effectiveStatus || w.status;
        return es === 'busy' || es === 'running' || es === 'assigned';
    });

    // If workers are active but tier still unknown, infer from worker count
    if (!tier && busyWorkers.length > 0) {
        tier = busyWorkers.length > 1 ? 3 : 2;
    }

    const m1 = handoff.request_id ? 'done' : 'idle';

    let m2 = 'idle';
    if (status === 'pending_decomposition') m2 = 'thinking';
    else if (m1 === 'done' && status) m2 = 'done';

    let m3 = 'idle';
    if (tier === 1) { m3 = 'skipped'; }
    else if (tier === 2) { m3 = 'skipped'; }
    else if (tier === 3 && m2 === 'done') {
        const allDone = workerEntries.length > 0 && workerEntries.every(([wid, w]) => {
            const es = state.agentHealth?.workers?.[wid]?.effectiveStatus || w.status;
            return es === 'completed_task' || es === 'idle';
        });
        m3 = allDone ? 'done' : 'thinking';
    }

    return { m1, m2, m3, tier };
}

function aplAgentBlock(label, status, info) {
    let inner = '';
    if (status === 'thinking') inner = '<div class="apb-dot-wave"><span></span><span></span><span></span></div>';
    else if (status === 'done') inner = '<span class="apb-check">✓</span>';
    else if (status === 'skipped') inner = '<span class="apb-skip">—</span>';
    const infoHtml = info ? `<span class="apb-info">${escapeHtml(info)}</span>` : '';
    return `<div class="agent-pipe-block apb-${status}">${
        `<span class="apb-label">${label}</span>${inner}${infoHtml}`
    }</div>`;
}

function aplArrow(visible) {
    if (!visible) return '<div class="pipe-arrow-placeholder"></div>';
    return `<div class="pipe-arrow"><svg viewBox="0 0 32 14" fill="none" xmlns="http://www.w3.org/2000/svg">
        <line x1="0" y1="7" x2="26" y2="7" stroke="#30363d" stroke-width="1.5"/>
        <polyline points="21,2 28,7 21,12" fill="none" stroke="#30363d" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    </svg></div>`;
}

function aplWorkerBlock(id, worker) {
    const wNum = id.replace(/\D/g, '') || id;
    const domain = (worker.domain || '').slice(0, 5).toUpperCase() || '—';
    const healthWorker = state.agentHealth?.workers?.[id];
    const es = healthWorker?.effectiveStatus || worker.status || 'idle';
    const wStatus = es === 'busy' || es === 'running' ? 'running'
        : es === 'completed_task' ? 'done'
        : es === 'dead' ? 'dead'
        : es === 'stopped' ? 'stopped'
        : 'idle';
    const isExpanded = expandedPipelineWorker === id;
    let detail = '';
    if (isExpanded) {
        detail = `<div class="apw-detail">
            ${worker.domain ? `<div class="apw-row"><span class="apw-label">domain</span><span>${escapeHtml(worker.domain)}</span></div>` : ''}
            <div class="apw-row"><span class="apw-label">status</span><span>${escapeHtml(es)}</span></div>
            ${worker.current_task ? `<div class="apw-row"><span class="apw-label">task</span><span>${escapeHtml((worker.current_task || '').slice(0, 60))}</span></div>` : ''}
            ${worker.last_heartbeat ? `<div class="apw-row"><span class="apw-label">hb</span><span>${formatHbAge(worker.last_heartbeat)}</span></div>` : ''}
        </div>`;
    }
    return `<div class="agent-worker-block apw-${wStatus}" onclick="togglePipeWorker('${escapeHtml(id)}')">
        <div class="apw-chip">
            <span class="apw-dot ${wStatus}"></span>
            <span class="apw-num">w${wNum}</span>
            <span class="apw-domain">${domain}</span>
        </div>${detail}</div>`;
}

function renderAnimatedPipeline() {
    const el = document.getElementById('animated-pipeline');
    if (!el) return;
    const handoff = state.handoff || {};
    if (!handoff.request_id) {
        el.innerHTML = '<div class="apl-no-request">No active request — use the command bar to start one</div>';
        return;
    }
    const { m1, m2, m3, tier } = derivePipelineStages();
    const workers = Object.entries(state.workers || {}).sort(([a], [b]) => a.localeCompare(b));
    const tierLabel = tier ? `Tier ${tier}` : '';
    const reqAge = handoff.timestamp ? formatHbAge(handoff.timestamp) : '';
    const showM2 = m1 !== 'idle';
    const showM3 = tier === 3 && showM2;

    // Assign workers to the correct pipeline slot based on tier
    const inlineWorkers = tier === 2 ? workers.slice(0, 1) : [];
    const rowWorkers = tier === 3 ? workers : [];
    // Fallback: if tier unknown but workers exist, show them in a row
    const fallbackWorkers = (!tier && workers.length > 0 && m2 === 'done') ? workers : [];

    let html = `<div class="apl-card">
        <div class="apl-header">
            <span class="apl-name">${escapeHtml(handoff.request_id)}</span>
            ${tierLabel ? `<span class="apl-tier tier-${tier}">${tierLabel}</span>` : ''}
            ${reqAge ? `<span class="apl-age">${reqAge}</span>` : ''}
        </div>
        <div class="apl-flow">
            ${aplAgentBlock('M1', m1)}
            ${aplArrow(showM2)}`;

    if (showM2) {
        html += aplAgentBlock('M2', m2, m2 === 'done' ? tierLabel || undefined : undefined);

        // Tier 2: arrow → single worker inline
        if (inlineWorkers.length > 0) {
            html += aplArrow(true);
            html += aplWorkerBlock(inlineWorkers[0][0], inlineWorkers[0][1]);
        }

        // Tier 3: arrow → M3
        if (showM3) {
            html += aplArrow(true);
            html += aplAgentBlock('M3', m3);
        }
    }

    html += `</div>`;

    // Tier 3 workers in a second row
    const workerRow = rowWorkers.length > 0 ? rowWorkers : fallbackWorkers;
    if (workerRow.length > 0 && (showM3 || fallbackWorkers.length > 0)) {
        html += `<div class="apl-workers-row">
            <span class="apl-down-connector">↓</span>
            ${workerRow.map(([id, w]) => aplWorkerBlock(id, w)).join('')}
        </div>`;
    }

    html += `</div>`;
    el.innerHTML = html;
}

function updateMasterStatus() {
    const pendingClars = (state.clarifications.questions || []).filter(q => q.status === 'pending');
    elements.m1Status.textContent = pendingClars.length > 0 ? 'Awaiting clarification'
        : state.handoff?.status === 'pending_decomposition' ? 'Request sent' : 'Ready';

    // Master-2 status dot — use effectiveStatus from health data
    const m2Health = state.agentHealth?.['master-2'];
    const m2Effective = m2Health?.effectiveStatus || (state.master2Ready ? 'active' : 'scanning');
    elements.m2ReadyDot.classList.remove('scanning', 'ready', 'stale', 'stopped');
    if (m2Effective === 'active' || state.master2Ready) {
        if (m2Effective === 'stale') {
            elements.m2ReadyDot.classList.add('stale');
            elements.m2ReadyDot.title = 'Stale — no recent activity';
            elements.m2Status.textContent = 'Stale (no activity)';
        } else if (m2Effective === 'stopped') {
            elements.m2ReadyDot.classList.add('stopped');
            elements.m2ReadyDot.title = 'Stopped — not running';
            elements.m2Status.textContent = 'Not running';
        } else {
            elements.m2ReadyDot.classList.add('ready');
            elements.m2ReadyDot.title = 'Ready';
            elements.m2Status.textContent = state.handoff?.status === 'pending_decomposition' ? 'Decomposing...'
                : (state.taskQueue?.tasks?.length || 0) > 0 ? `${state.taskQueue.tasks.length} tasks created` : 'Watching';
        }
    } else {
        elements.m2ReadyDot.classList.add('scanning');
        elements.m2ReadyDot.title = 'Scanning codebase...';
        elements.m2Status.textContent = 'Scanning codebase...';
    }

    // Master-3 status dot — use effectiveStatus from health data
    const m3Health = state.agentHealth?.['master-3'];
    const m3Effective = m3Health?.effectiveStatus || (state.master3Ready ? 'active' : 'scanning');
    elements.m3ReadyDot.classList.remove('scanning', 'ready', 'stale', 'stopped');
    if (m3Effective === 'active' || state.master3Ready) {
        if (m3Effective === 'stale') {
            elements.m3ReadyDot.classList.add('stale');
            elements.m3ReadyDot.title = 'Stale — no recent activity';
            elements.m3Status.textContent = 'Stale (no activity)';
        } else if (m3Effective === 'stopped') {
            elements.m3ReadyDot.classList.add('stopped');
            elements.m3ReadyDot.title = 'Stopped — not running';
            elements.m3Status.textContent = 'Not running';
        } else {
            elements.m3ReadyDot.classList.add('ready');
            elements.m3ReadyDot.title = 'Ready';
            const busyCount = Object.entries(state.workers).filter(([wid, w]) => {
                const es = state.agentHealth?.workers?.[wid]?.effectiveStatus || w.status;
                return es === 'busy' || es === 'running';
            }).length;
            elements.m3Status.textContent = busyCount > 0 ? `${busyCount} worker${busyCount > 1 ? 's' : ''} active`
                : (state.taskQueue?.tasks?.length || 0) > 0 ? 'Allocating...' : 'Monitoring';
        }
    } else {
        elements.m3ReadyDot.classList.add('scanning');
        elements.m3ReadyDot.title = 'Scanning codebase...';
        elements.m3Status.textContent = 'Scanning codebase...';
    }
}

function renderPipeline() {
    const inputItems = [];
    if (state.handoff?.status === 'pending_decomposition' || state.handoff?.description) {
        inputItems.push({
            id: state.handoff.request_id, title: state.handoff.request_id || 'Request',
            subtitle: state.handoff.description?.slice(0, 50) || '', type: 'request', data: state.handoff
        });
    }
    elements.inputCount.textContent = inputItems.length;
    elements.inputItems.innerHTML = inputItems.length === 0
        ? '<div class="stage-item empty">No pending requests</div>'
        : inputItems.map(i => renderStageItem(i)).join('');

    const decompItems = [];
    if (state.handoff?.status === 'pending_decomposition') {
        decompItems.push({
            id: 'decomp-' + state.handoff.request_id, title: 'Breaking down...',
            subtitle: state.handoff.request_id, type: 'decomp', data: state.handoff
        });
    }
    elements.decompCount.textContent = decompItems.length;
    elements.decompItems.innerHTML = decompItems.length === 0
        ? '<div class="stage-item empty">—</div>' : decompItems.map(i => renderStageItem(i)).join('');

    const queueTasks = (state.taskQueue?.tasks || []).map(t => ({
        id: t.subject, title: t.subject || 'Task', subtitle: t.domain || t.assigned_to || '', type: 'task', data: t
    }));
    elements.queueCount.textContent = queueTasks.length;
    elements.queueItems.innerHTML = queueTasks.length === 0
        ? '<div class="stage-item empty">—</div>'
        : queueTasks.slice(0, 5).map(i => renderStageItem(i)).join('') +
        (queueTasks.length > 5 ? `<div class="stage-item more">+${queueTasks.length - 5} more</div>` : '');

    const activeItems = Object.entries(state.workers).filter(([id, w]) => {
            const es = state.agentHealth?.workers?.[id]?.effectiveStatus || w.status;
            return es === 'busy' || es === 'running';
        })
        .map(([id, w]) => ({ id, title: w.current_task || 'Working...', subtitle: id.toUpperCase(), type: 'worker', data: { id, ...w } }));
    elements.activeCount.textContent = activeItems.length;
    elements.activeItems.innerHTML = activeItems.length === 0
        ? '<div class="stage-item empty">—</div>' : activeItems.map(i => renderStageItem(i)).join('');
}

function renderStageItem(item) {
    const tc = item.type === 'request' ? 'request' : item.type === 'task' ? 'task' : item.type === 'worker' ? 'worker' : '';
    return `<div class="stage-item clickable ${tc}" onclick="showDetail('${item.type}', '${escapeHtml(item.id)}')">
        <div class="stage-item-title">${escapeHtml(item.title)}</div>
        <div class="stage-item-subtitle">${escapeHtml(item.subtitle)}</div></div>`;
}

function renderWorkers() {
    const workers = Object.entries(state.workers).sort(([a], [b]) => a.localeCompare(b));
    const active = workers.filter(([id, w]) => {
        const es = state.agentHealth?.workers?.[id]?.effectiveStatus || w.status;
        return es === 'busy' || es === 'running';
    }).length;
    elements.workerSummary.textContent = `(${active}/${workers.length})`;
    elements.workerGrid.innerHTML = workers.length === 0
        ? '<div class="no-workers">No workers registered</div>'
        : workers.map(([id, worker]) => {
            // Use effectiveStatus from health data if available, else derive locally
            const healthWorker = state.agentHealth?.workers?.[id];
            const effectiveStatus = healthWorker?.effectiveStatus || worker.status || 'idle';
            const sc = effectiveStatus === 'dead' ? 'dead' : effectiveStatus === 'stopped' ? 'dead'
                : effectiveStatus === 'busy' || effectiveStatus === 'running' ? 'busy'
                : effectiveStatus === 'completed_task' ? 'completed' : effectiveStatus === 'resetting' ? 'resetting' : 'idle';
            const hbAge = worker.last_heartbeat ? (Date.now() - new Date(worker.last_heartbeat).getTime()) / 1000 : 999;
            const hbClass = hbAge > 90 ? 'stale' : '';
            const progress = Math.min((worker.tasks_completed || 0) / 4 * 100, 100);
            const statusLabel = effectiveStatus === 'stopped' ? 'Not running'
                : effectiveStatus === 'dead' ? 'Dead'
                : worker.current_task || 'Idle';
            return `<div class="worker-card ${sc}" onclick="showDetail('worker', '${id}')">
                <div class="worker-header"><div class="worker-id">
                    <span class="worker-status-dot ${effectiveStatus}"></span>${id.replace('worker-', 'W')}</div>
                    <span class="worker-heartbeat ${hbClass}">hb</span></div>
                ${worker.domain ? `<span class="worker-domain">${worker.domain}</span>` : ''}
                <div class="worker-task">${statusLabel}</div>
                <div class="worker-progress"><div class="worker-progress-bar" style="width: ${progress}%"></div></div>
                <div class="worker-progress-label">${worker.tasks_completed || 0}/4 tasks</div></div>`;
        }).join('');
}

function renderActivityLogFull() {
    elements.activityLog.innerHTML = state.activityLog.map(renderLogEntry).join('');
    if (elements.autoscroll?.checked) elements.activityLog.scrollTop = elements.activityLog.scrollHeight;
}
function renderActivityLog(newEntries) {
    newEntries.forEach(e => elements.activityLog.insertAdjacentHTML('beforeend', renderLogEntry(e)));
    if (elements.autoscroll?.checked) elements.activityLog.scrollTop = elements.activityLog.scrollHeight;
}
function renderLogEntry(entry) {
    const ac = entry.agent.includes('master-1') ? 'm-1' : entry.agent.includes('master-2') ? 'm-2'
        : entry.agent.includes('master-3') ? 'm-3' : entry.agent.includes('worker') ? 'worker' : '';
    const aclass = ['COMPLETE', 'DECOMPOSE_DONE', 'MERGE_PR'].includes(entry.action) ? 'complete'
        : ['ALLOCATE', 'REQUEST'].includes(entry.action) ? 'allocate'
            : ['RESET', 'RESET_WORKER', 'CONTEXT_RESET', 'SCAN_COMPLETE'].includes(entry.action) ? 'reset'
                : entry.action.includes('ERROR') || entry.action.includes('DEAD') ? 'error' : '';
    return `<div class="log-entry"><span class="log-time">${entry.time}</span>
        <span class="log-agent ${ac}">${entry.agentShort}</span>
        <span class="log-action ${aclass}">${entry.action}</span>
        <span class="log-details">${escapeHtml(entry.details)}</span></div>`;
}

function updateClarificationBanner() {
    const pending = (state.clarifications.questions || []).find(q => q.status === 'pending');
    if (pending) {
        state.pendingClarification = pending;
        elements.clarificationQuestion.textContent = pending.question;
        elements.clarificationBanner.classList.remove('hidden');
        elements.commandInput.placeholder = 'Type your answer...';
    } else {
        state.pendingClarification = null;
        elements.clarificationBanner.classList.add('hidden');
        elements.commandInput.placeholder = 'Tell Master-1 what you want...';
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE 3: Request List with Tier Badges
// ═══════════════════════════════════════════════════════════════════════════
function renderRequestList() {
    const requests = [];
    // From activity log, extract unique request IDs
    const seen = new Set();
    state.activityLog.forEach(entry => {
        const reqMatch = entry.details.match(/(?:request_id|id)[=:\s]*([^\s,\]]+)/i);
        if (reqMatch && !seen.has(reqMatch[1])) {
            seen.add(reqMatch[1]);
            requests.push({ id: reqMatch[1], firstSeen: entry.time, agent: entry.agent, action: entry.action });
        }
    });
    // Current handoff
    if (state.handoff?.request_id && !seen.has(state.handoff.request_id)) {
        requests.unshift({ id: state.handoff.request_id, firstSeen: 'now', agent: 'master-1', action: 'REQUEST' });
    }

    if (!elements.requestList) return;
    if (requests.length === 0) {
        elements.requestList.innerHTML = '<div class="request-empty">No requests yet</div>';
        return;
    }
    elements.requestList.innerHTML = requests.slice(0, 20).map(req => {
        const tc = state.tierClassifications[req.id];
        const tierBadge = tc ? `<span class="tier-badge tier-${tc.tier}">T${tc.tier}</span>` : '';
        const phase = getCurrentPhase(req.id);
        return `<div class="request-item" onclick="switchTab('timeline'); setTimeout(() => { elements.timelineSelect.value='${escapeHtml(req.id)}'; loadTimeline('${escapeHtml(req.id)}'); }, 100);">
            ${tierBadge}<span class="request-id">${escapeHtml(req.id)}</span>
            <span class="request-phase">${phase}</span>
            <span class="request-time">${req.firstSeen}</span></div>`;
    }).join('');
}

function getCurrentPhase(requestId) {
    const events = state.activityLog.filter(e => e.details.includes(requestId));
    if (events.length === 0) return 'pending';
    const last = events[events.length - 1];
    if (last.action === 'COMPLETE' || last.action === 'MERGE_PR') return 'completed';
    if (last.action === 'TASK_CLAIMED') return 'executing';
    if (last.action === 'ALLOCATE') return 'allocating';
    if (last.action === 'DECOMPOSE_START') return 'decomposing';
    if (last.action === 'TIER_CLASSIFY') return 'classified';
    return last.action.toLowerCase();
}

function showTierToast(requestId, tier, reasoning) {
    const toast = document.createElement('div');
    toast.className = `toast tier-toast tier-${tier}`;
    toast.innerHTML = `<span class="toast-icon">T${tier}</span>
        <div class="toast-body"><strong>'${escapeHtml(requestId)}'</strong> → Tier ${tier}
        <div class="toast-sub">${TIER_LABELS[tier]}</div></div>`;
    elements.toastContainer?.appendChild(toast);
    requestAnimationFrame(() => toast.classList.add('show'));
    setTimeout(() => { toast.classList.remove('show'); setTimeout(() => toast.remove(), 300); }, 5000);
}

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE 1: TIMELINE / WATERFALL VIEW
// ═══════════════════════════════════════════════════════════════════════════
async function populateRequestDropdown() {
    const events = await window.electron.getTimeline();
    const ids = new Set();
    events.forEach(e => {
        const m = e.details.match(/(?:request_id|id)[=:\s]*([^\s,\]]+)/i);
        if (m) ids.add(m[1]);
    });
    // Also add from handoff
    if (state.handoff?.request_id) ids.add(state.handoff.request_id);
    const select = elements.timelineSelect;
    const current = select.value;
    select.innerHTML = '<option value="">— Select a request —</option>';
    [...ids].forEach(id => {
        const opt = document.createElement('option');
        opt.value = id; opt.textContent = id;
        select.appendChild(opt);
    });
    if (current && ids.has(current)) select.value = current;
}

async function loadTimeline(requestId) {
    const events = await window.electron.getTimeline(requestId);
    if (events.length === 0) {
        elements.timelineChart.innerHTML = '<div class="timeline-empty">No events found for this request</div>';
        elements.timelineSummary.innerHTML = '';
        return;
    }
    const phases = buildPhases(events, requestId);
    renderTimelineChart(phases, events);
}

function buildPhases(events, requestId) {
    const phases = [];
    let handoffStart = null, triageStart = null, decompStart = null;
    let allocStarts = [], workerPhases = {};

    events.forEach(e => {
        const t = new Date(e.timestamp).getTime();
        if (e.action === 'REQUEST' && e.agent.includes('master-1')) {
            handoffStart = t;
        } else if (e.action === 'TIER_CLASSIFY' && e.agent.includes('master-2')) {
            if (handoffStart) { phases.push({ phase: 'handoff', start: handoffStart, end: t, agent: 'master-1' }); handoffStart = null; }
            triageStart = t;
        } else if ((e.action === 'TIER1_EXECUTE' || e.action === 'TIER2_ASSIGN' || e.action === 'DECOMPOSE_START') && e.agent.includes('master-2')) {
            if (triageStart) { phases.push({ phase: 'triage', start: triageStart, end: t, agent: 'master-2' }); triageStart = null; }
            if (e.action === 'DECOMPOSE_START') decompStart = t;
        } else if (e.action === 'DECOMPOSE_DONE' && e.agent.includes('master-2')) {
            if (decompStart) { phases.push({ phase: 'decomposition', start: decompStart, end: t, agent: 'master-2' }); decompStart = null; }
        } else if (e.action === 'ALLOCATE' && e.agent.includes('master-3')) {
            allocStarts.push(t);
        } else if (e.action === 'TASK_CLAIMED' && e.agent.includes('worker')) {
            const wid = e.agent;
            workerPhases[wid] = workerPhases[wid] || [];
            workerPhases[wid].push({ start: t, agent: wid });
        } else if (e.action === 'COMPLETE' && e.agent.includes('worker')) {
            const wid = e.agent;
            if (workerPhases[wid]?.length) {
                const last = workerPhases[wid][workerPhases[wid].length - 1];
                if (!last.end) last.end = t;
            }
        } else if (e.action === 'MERGE_PR' && e.agent.includes('master-3')) {
            phases.push({ phase: 'integration', start: t - 5000, end: t, agent: 'master-3' });
        }
    });

    // Add allocation phase
    if (allocStarts.length > 0) {
        phases.push({ phase: 'allocation', start: Math.min(...allocStarts), end: Math.max(...allocStarts) + 2000, agent: 'master-3' });
    }
    // Add worker phases
    Object.entries(workerPhases).forEach(([wid, wps]) => {
        wps.forEach(wp => {
            if (wp.end) phases.push({ phase: 'worker', start: wp.start, end: wp.end, agent: wid });
            else phases.push({ phase: 'worker', start: wp.start, end: Date.now(), agent: wid });
        });
    });

    phases.sort((a, b) => a.start - b.start);
    return phases;
}

function renderTimelineChart(phases, events) {
    if (phases.length === 0) {
        elements.timelineChart.innerHTML = '<div class="timeline-empty">No phases detected</div>';
        return;
    }
    const minT = Math.min(...phases.map(p => p.start));
    const maxT = Math.max(...phases.map(p => p.end));
    const totalMs = maxT - minT || 1;
    const totalSec = Math.round(totalMs / 1000);
    const totalStr = totalSec >= 60 ? `${Math.floor(totalSec / 60)}m ${totalSec % 60}s` : `${totalSec}s`;

    // Find longest phase
    let longestIdx = 0, longestDur = 0;
    phases.forEach((p, i) => { const d = p.end - p.start; if (d > longestDur) { longestDur = d; longestIdx = i; } });

    // Group workers into swim lanes
    const agents = [...new Set(phases.map(p => p.agent))];
    const nonWorkerAgents = agents.filter(a => !a.includes('worker'));
    const workerAgents = agents.filter(a => a.includes('worker'));
    const lanes = [...nonWorkerAgents.map(a => ({ agent: a, label: a.replace('master-', 'M').toUpperCase() })),
    ...workerAgents.map(a => ({ agent: a, label: a.replace('worker-', 'W').toUpperCase() }))];

    // Summary
    elements.timelineSummary.innerHTML = `<div class="timeline-total"><strong>Total:</strong> ${totalStr}</div>
        <div class="timeline-longest"><strong>Longest:</strong> ${phases[longestIdx].phase} (${formatDuration(longestDur)})</div>`;

    // Build chart
    let html = '<div class="timeline-axis">';
    const ticks = 5;
    for (let i = 0; i <= ticks; i++) {
        const pct = (i / ticks) * 100;
        const time = new Date(minT + (totalMs * i / ticks));
        html += `<span class="timeline-tick" style="left:${pct}%">${time.toTimeString().slice(0, 8)}</span>`;
    }
    html += '</div>';

    lanes.forEach(lane => {
        const lanePhases = phases.filter(p => p.agent === lane.agent);
        html += `<div class="timeline-lane"><span class="lane-label">${lane.label}</span><div class="lane-bars">`;
        lanePhases.forEach((p, i) => {
            const left = ((p.start - minT) / totalMs) * 100;
            const width = Math.max(((p.end - p.start) / totalMs) * 100, 0.5);
            const isLongest = phases.indexOf(p) === longestIdx;
            const dur = formatDuration(p.end - p.start);
            const color = PHASE_COLORS[p.phase] || '#58a6ff';
            html += `<div class="timeline-bar ${isLongest ? 'longest' : ''}" style="left:${left}%;width:${width}%;background:${color}"
                title="${p.phase}: ${dur} (${new Date(p.start).toTimeString().slice(0, 8)} → ${new Date(p.end).toTimeString().slice(0, 8)})">
                ${width > 8 ? `<span class="bar-label">${p.phase} ${dur}</span>` : ''}</div>`;

            // Dead time gap detection
            if (i > 0) {
                const prevEnd = lanePhases[i - 1].end;
                const gap = p.start - prevEnd;
                if (gap > 5000) {
                    const gapLeft = ((prevEnd - minT) / totalMs) * 100;
                    const gapWidth = (gap / totalMs) * 100;
                    html += `<div class="timeline-deadtime" style="left:${gapLeft}%;width:${gapWidth}%"
                        title="Dead time: ${formatDuration(gap)}"></div>`;
                }
            }
        });
        html += '</div></div>';
    });

    elements.timelineChart.innerHTML = html;
}

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE 2: AGENT HEALTH DASHBOARD
// ═══════════════════════════════════════════════════════════════════════════
let healthPollTimer = null;
function hasUrgentHealthState(health) {
    if (!health) return false;
    const m2es = health['master-2']?.effectiveStatus;
    const m3es = health['master-3']?.effectiveStatus;
    if (m2es === 'resetting' || m3es === 'resetting') return true;
    const workers = Object.values(health.workers || {});
    return workers.some(w => {
        const es = w.effectiveStatus || w.status;
        return es === 'dead' || es === 'resetting';
    });
}

function nextHealthPollIntervalMs() {
    return hasUrgentHealthState(state.agentHealth) ? HEALTH_POLL_MS_URGENT : HEALTH_POLL_MS_NORMAL;
}

async function runHealthPollLoop() {
    try {
        await loadAgentHealth();
    } catch (e) {
        debugLog('HEALTH', 'Health poll error', { error: e.message });
    }
    if (state.activeTab !== 'health') return;
    healthPollTimer = setTimeout(runHealthPollLoop, nextHealthPollIntervalMs());
}

function startHealthPolling() {
    stopHealthPolling();
    runHealthPollLoop();
}

function stopHealthPolling() {
    if (healthPollTimer) {
        clearTimeout(healthPollTimer);
        healthPollTimer = null;
    }
}

async function loadAgentHealth() {
    const health = await window.electron.getAgentHealth();
    state.agentHealth = health;
    elements.healthUpdateTime.textContent = `Updated ${new Date().toLocaleTimeString()}`;
    renderHealthCards(health);
    updateStaggerBanner(health);
    // Sync dashboard status dots and launch panel with health data
    updateMasterStatus();
    if (state.activeTab === 'launch') updateLaunchStatuses();
}

function renderHealthCards(health) {
    if (!health) { elements.healthCards.innerHTML = '<div class="health-empty">No agent-health.json found. Agents will populate this when running.</div>'; return; }
    let html = '';
    // Master-2 card
    if (health['master-2']) {
        const m2 = health['master-2'];
        const es = m2.effectiveStatus || m2.status || 'unknown';
        const t1pct = Math.round(((m2.tier1_count || 0) / 4) * 100);
        const dpct = Math.round(((m2.decomposition_count || 0) / 6) * 100);
        const statusExtra = es === 'stale' ? 'No recent activity'
            : es === 'stopped' ? 'Not running' : null;
        html += renderAgentCard('MASTER-2', 'Opus', 'Architect', es, m2.resetImminent && es === 'active', [
            { label: 'Tier 1 executions', value: `${m2.tier1_count || 0}/4`, percent: t1pct },
            { label: 'Decompositions', value: `${m2.decomposition_count || 0}/6`, percent: dpct }
        ], statusExtra || (m2.staleness ? `${m2.staleness} commits since scan` : null), m2.last_reset);
    }
    // Master-3 card
    if (health['master-3']) {
        const m3 = health['master-3'];
        const es = m3.effectiveStatus || m3.status || 'unknown';
        const uptimeStr = es === 'stopped' ? `${m3.uptimeMinutes || 0} min (stopped)`
            : es === 'stale' ? `${m3.uptimeMinutes || 0} min (stale)`
            : `${m3.uptimeMinutes || 0} min`;
        const statusExtra = es === 'stale' ? 'No recent activity'
            : es === 'stopped' ? 'Not running' : null;
        html += renderAgentCard('MASTER-3', 'Opus', 'Allocator', es, m3.resetImminent && es === 'active', [
            { label: 'Context budget', value: `${m3.context_budget || 0}/5000`, percent: es === 'active' ? (m3.budgetPercent || 0) : 0 },
            { label: 'Uptime', value: uptimeStr, percent: es === 'active' ? Math.min(100, Math.round(((m3.uptimeMinutes || 0) / 20) * 100)) : 0 }
        ], statusExtra, m3.last_reset);
    }
    // Worker cards
    if (health.workers) {
        Object.entries(health.workers).sort(([a], [b]) => a.localeCompare(b)).forEach(([id, w]) => {
            const es = w.effectiveStatus || w.status || 'idle';
            const taskPct = Math.round(((w.tasks_completed || 0) / 6) * 100);
            const hbAge = w._heartbeatAgeSec;
            const hbStr = hbAge !== null ? (hbAge > 3600 ? `${Math.floor(hbAge / 3600)}h ago` : `${hbAge}s ago`) : null;
            const statusExtra = es === 'stopped' ? 'Not running'
                : es === 'dead' ? 'No heartbeat (>90s)'
                : w.current_task ? `Current: "${w.current_task}"` : null;
            html += renderAgentCard(id.toUpperCase(), 'Opus', w.domain || 'general', es, w.resetImminent && (es === 'busy' || es === 'running'), [
                { label: 'Context budget', value: `${w.context_budget || 0}/8000`, percent: w.budgetPercent || 0 },
                { label: 'Tasks completed', value: `${w.tasks_completed || 0}/6`, percent: taskPct }
            ], statusExtra, null, hbStr);
        });
    }
    elements.healthCards.innerHTML = html || '<div class="health-empty">No agent data available</div>';
}

function renderAgentCard(name, model, role, status, resetImminent, metrics, extra, lastReset, heartbeat) {
    const dotClass = resetImminent ? 'warning'
        : status === 'stopped' ? 'stopped'
        : status === 'stale' ? 'stale'
        : status === 'resetting' ? 'resetting'
        : status === 'dead' ? 'dead'
        : 'active';
    let html = `<div class="health-card ${dotClass}"><div class="health-card-header">
        <div class="health-card-title">${name} <span class="health-model">(${model})</span> — ${role}
        <span class="health-dot ${dotClass}"></span></div></div>`;
    metrics.forEach(m => {
        const color = getHealthColor(m.percent);
        html += `<div class="health-metric"><span class="health-label">${m.label}:</span>
            <div class="health-bar-wrap"><div class="health-bar" style="width:${m.percent}%;background:${color}"></div></div>
            <span class="health-value">${m.value}</span></div>`;
    });
    if (extra) html += `<div class="health-extra">${escapeHtml(extra)}</div>`;
    if (heartbeat) html += `<div class="health-heartbeat">Last heartbeat: ${heartbeat}</div>`;
    if (lastReset) html += `<div class="health-reset">Last reset: ${relativeTime(lastReset)}</div>`;
    if (status) html += `<div class="health-status">Status: ${status}</div>`;
    html += '</div>';
    return html;
}

function getHealthColor(pct) {
    if (pct < 60) return '#3fb950'; if (pct < 85) return '#d29922'; return '#f85149';
}

function updateStaggerBanner(health) {
    if (!health || !elements.staggerBanner) return;
    const resetting = [];
    if ((health['master-2']?.effectiveStatus || health['master-2']?.status) === 'resetting') resetting.push('Master-2');
    if ((health['master-3']?.effectiveStatus || health['master-3']?.status) === 'resetting') resetting.push('Master-3');
    if (resetting.length > 0) {
        const others = ['Master-2', 'Master-3'].filter(m => !resetting.includes(m));
        elements.staggerMessage.textContent = `${resetting.join(', ')} RESETTING — ${others.join(', ')} reset deferred until complete`;
        elements.staggerBanner.classList.remove('hidden');
    } else { elements.staggerBanner.classList.add('hidden'); }
}

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE 4: KNOWLEDGE FILE VIEWER
// ═══════════════════════════════════════════════════════════════════════════
async function loadKnowledge() {
    const files = await window.electron.getKnowledge();
    state.knowledgeFiles = files || [];
    renderKnowledgeList();
}

function renderKnowledgeList() {
    const fl = elements.knowledgeFileList;
    if (!fl) return;
    if (state.knowledgeFiles.length === 0) {
        fl.innerHTML = '<div class="knowledge-empty">No knowledge files found in .claude/knowledge/</div>';
        return;
    }
    fl.innerHTML = state.knowledgeFiles.map(f => {
        const budget = getBudgetForFile(f.name);
        const pct = budget ? Math.min(100, Math.round((f.tokenEstimate / budget) * 100)) : null;
        const color = pct !== null ? getHealthColor(pct) : '#58a6ff';
        const modAge = Date.now() - new Date(f.modified).getTime();
        const isNew = modAge < 300000; // 5 min
        const overBudget = pct !== null && pct > 100;
        return `<div class="knowledge-file-item ${state.selectedKnowledgeFile === f.name ? 'selected' : ''}"
            onclick="selectKnowledgeFile('${escapeHtml(f.name)}')">
            <div class="knowledge-file-header">
                <span class="knowledge-file-name">${escapeHtml(f.name)}</span>
                ${isNew ? '<span class="knowledge-new-badge">← NEW</span>' : ''}
            </div>
            <div class="knowledge-file-stats">
                <span class="knowledge-tokens">${f.tokenEstimate}${budget ? ' / ' + budget : ''} tokens</span>
                <span class="knowledge-modified">${relativeTime(f.modified)}</span>
            </div>
            ${pct !== null ? `<div class="knowledge-bar-wrap"><div class="knowledge-bar ${overBudget ? 'over' : ''}" style="width:${Math.min(pct, 100)}%;background:${color}"></div></div>` : ''}
        </div>`;
    }).join('');
}

window.selectKnowledgeFile = function (name) {
    state.selectedKnowledgeFile = name;
    const file = state.knowledgeFiles.find(f => f.name === name);
    if (!file) return;
    elements.knowledgeFileName.textContent = file.name;
    const budget = getBudgetForFile(file.name);
    elements.knowledgeFileMeta.textContent = `${file.tokenEstimate} tokens${budget ? ' / ' + budget + ' budget' : ''} • Modified ${relativeTime(file.modified)}`;
    // Simple markdown rendering
    elements.knowledgeFileContent.innerHTML = `<pre class="knowledge-rendered">${escapeHtml(file.content)}</pre>`;
    renderKnowledgeList(); // Update selected state
};

function getBudgetForFile(name) {
    if (TOKEN_BUDGETS[name] !== undefined) return TOKEN_BUDGETS[name];
    if (name.startsWith('domain/')) return DOMAIN_TOKEN_BUDGET;
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE 5: SIGNAL MONITOR
// ═══════════════════════════════════════════════════════════════════════════
async function loadSignals() {
    const signals = await window.electron.getSignals();
    renderSignalPills(signals);
    renderSignalHistory();
    startSignalAgeUpdater();
}

function handleSignalFired(data) {
    state.signalHistory.unshift({ ...data, receivedAt: Date.now() });
    if (state.signalHistory.length > 50) state.signalHistory = state.signalHistory.slice(0, 50);

    // Flash the pill
    if (state.activeTab === 'signals') {
        renderSignalPills();
        renderSignalHistory();
    }

    // Check for slow wake
    setTimeout(() => checkSlowWake(data), 5500);
}

function renderSignalPills(signals) {
    const pills = elements.signalPills;
    if (!pills) return;
    const allSignals = signals || state.signalHistory.slice(0, 10);
    if (allSignals.length === 0) { pills.innerHTML = '<span class="signal-none">No signals detected</span>'; return; }
    pills.innerHTML = allSignals.map(s => {
        const age = Date.now() - new Date(s.lastTouched || s.timestamp).getTime();
        const bright = age < 5000;
        const name = s.name || s.signal || 'unknown';
        return `<span class="signal-pill ${bright ? 'bright' : 'faded'}" data-signal="${escapeHtml(name)}">
            ${escapeHtml(name)} <span class="signal-age">${formatAge(age)}</span></span>`;
    }).join(' → ');
}

function renderSignalHistory() {
    const sh = elements.signalHistory;
    if (!sh) return;
    elements.signalCount.textContent = state.signalHistory.length;
    if (state.signalHistory.length === 0) {
        sh.innerHTML = '<div class="signal-empty">No signal events recorded yet</div>';
        return;
    }
    sh.innerHTML = state.signalHistory.map(s => {
        const name = s.signal || s.name || 'unknown';
        const age = Date.now() - new Date(s.timestamp).getTime();
        return `<div class="signal-history-item ${s.slowWake ? 'slow-wake' : ''}">
            <span class="signal-history-name">${escapeHtml(name)}</span>
            <span class="signal-history-time">${formatAge(age)}</span>
            ${s.slowWake ? '<span class="signal-slow-badge">slow wake</span>' : ''}</div>`;
    }).join('');
}

function checkSlowWake(signalData) {
    const signalTime = new Date(signalData.timestamp).getTime();
    const recentActions = state.activityLog.filter(e => {
        if (!Number.isFinite(e.timestampMs)) return false;
        return Math.abs(e.timestampMs - signalTime) < 10000;
    });
    // If no action within 5s of signal, mark as slow wake
    const entry = state.signalHistory.find(s => s.timestamp === signalData.timestamp);
    if (entry && recentActions.length === 0) {
        entry.slowWake = true;
        if (state.activeTab === 'signals') renderSignalHistory();
    }
}

let signalAgeTimer = null;
function startSignalAgeUpdater() {
    stopSignalAgeUpdater();
    signalAgeTimer = setInterval(() => {
        if (state.activeTab === 'signals') { renderSignalPills(); renderSignalHistory(); }
        else stopSignalAgeUpdater();
    }, SIGNAL_AGE_REFRESH_MS);
}

function stopSignalAgeUpdater() {
    if (signalAgeTimer) {
        clearInterval(signalAgeTimer);
        signalAgeTimer = null;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE 7: SESSION STATS
// ═══════════════════════════════════════════════════════════════════════════
async function computeSessionStats() {
    const events = await window.electron.getTimeline();
    if (!events || events.length === 0) {
        elements.statsContent.innerHTML = '<div class="stats-empty">No session data available. Activity log is empty.</div>';
        return;
    }
    const firstEvent = events[0];
    const sessionStart = new Date(firstEvent.timestamp);

    // Extract request IDs
    const requestIds = new Set();
    events.forEach(e => {
        const m = e.details.match(/(?:request_id|id)[=:\s]*([^\s,\]]+)/i);
        if (m) requestIds.add(m[1]);
    });

    // Count tiers
    const tiers = { 1: [], 2: [], 3: [] };
    events.filter(e => e.action === 'TIER_CLASSIFY').forEach(e => {
        const tm = e.details.match(/tier[=:\s]*(\d)/i);
        const rm = e.details.match(/(?:request_id|id)[=:\s]*([^\s,\]]+)/i);
        if (tm && rm) tiers[parseInt(tm[1])]?.push(rm[1]);
    });

    // Count resets
    const resets = { 'master-2': 0, 'master-3': 0, workers: 0 };
    events.filter(e => e.action === 'RESET' || e.action === 'CONTEXT_RESET').forEach(e => {
        if (e.agent.includes('master-2')) resets['master-2']++;
        else if (e.agent.includes('master-3')) resets['master-3']++;
        else if (e.agent.includes('worker')) resets.workers++;
    });

    const totalResets = resets['master-2'] + resets['master-3'] + resets.workers;

    elements.statsContent.innerHTML = `
        <div class="stats-section">
            <h3>SESSION STATS <span class="stats-since">(since ${sessionStart.toLocaleTimeString()})</span></h3>
            <div class="stats-grid">
                <div class="stat-card"><div class="stat-number">${requestIds.size}</div><div class="stat-label">Requests</div></div>
                <div class="stat-card tier-1-card"><div class="stat-number">${tiers[1].length}</div><div class="stat-label">Tier 1</div></div>
                <div class="stat-card tier-2-card"><div class="stat-number">${tiers[2].length}</div><div class="stat-label">Tier 2</div></div>
                <div class="stat-card tier-3-card"><div class="stat-number">${tiers[3].length}</div><div class="stat-label">Tier 3</div></div>
            </div>
        </div>
        <div class="stats-section">
            <h3>Agent Resets</h3>
            <div class="stats-grid">
                <div class="stat-card"><div class="stat-number">${totalResets}</div><div class="stat-label">Total Resets</div></div>
                <div class="stat-card"><div class="stat-number">${resets['master-2']}</div><div class="stat-label">Master-2</div></div>
                <div class="stat-card"><div class="stat-number">${resets['master-3']}</div><div class="stat-label">Master-3</div></div>
                <div class="stat-card"><div class="stat-number">${resets.workers}</div><div class="stat-label">Workers</div></div>
            </div>
        </div>
        <div class="stats-section">
            <h3>Event Summary</h3>
            <div class="stats-table">
                <div class="stats-row"><span>Total log events</span><span>${events.length}</span></div>
                <div class="stats-row"><span>Signal events</span><span>${state.signalHistory.length}</span></div>
                <div class="stats-row"><span>Knowledge files</span><span>${state.knowledgeFiles.length}</span></div>
            </div>
        </div>`;

    state._lastStats = { requestIds: [...requestIds], tiers, resets, totalEvents: events.length, sessionStart: sessionStart.toISOString() };
}

function exportStats(format) {
    if (!state._lastStats) { computeSessionStats(); return; }
    let content;
    if (format === 'json') {
        content = JSON.stringify(state._lastStats, null, 2);
    } else {
        const s = state._lastStats;
        content = `# Session Stats\n\n- Requests: ${s.requestIds.length}\n- Tier 1: ${s.tiers[1].length}\n- Tier 2: ${s.tiers[2].length}\n- Tier 3: ${s.tiers[3].length}\n- Resets: M2=${s.resets['master-2']} M3=${s.resets['master-3']} Workers=${s.resets.workers}\n- Events: ${s.totalEvents}\n`;
    }
    navigator.clipboard.writeText(content).then(() => {
        showTierToast('Stats', 0, `Copied to clipboard as ${format.toUpperCase()}`);
    }).catch(() => console.log('Export:', content));
}

// ═══════════════════════════════════════════════════════════════════════════
// DETAIL PANEL (Feature 6: Per-Request Lifecycle embedded here)
// ═══════════════════════════════════════════════════════════════════════════
window.showDetail = function (type, id) {
    debugLog('UI', 'Show detail', { type, id });
    let title = '', content = '';

    if (type === 'request') {
        title = 'Request Details';
        const data = state.handoff || {};
        const tc = state.tierClassifications[data.request_id];
        content = `<div class="detail-section"><label>Request ID</label><div class="detail-value">${data.request_id || 'N/A'}</div></div>
            ${tc ? `<div class="detail-section"><label>Tier</label><div class="detail-value"><span class="tier-badge tier-${tc.tier}">T${tc.tier}</span> ${TIER_LABELS[tc.tier]}</div></div>` : ''}
            <div class="detail-section"><label>Status</label><div class="detail-value status-${data.status}">${data.status || 'N/A'}</div></div>
            <div class="detail-section"><label>Description</label><div class="detail-value">${data.description || 'N/A'}</div></div>
            <div class="detail-section"><label>Tasks</label><div class="detail-value">${renderTaskTree(data.request_id)}</div></div>
            <div class="detail-section"><label>Raw JSON</label><pre class="detail-json">${JSON.stringify(data, null, 2)}</pre></div>`;
    } else if (type === 'task') {
        title = 'Task Details';
        const task = (state.taskQueue?.tasks || []).find(t => t.subject === id) || {};
        content = `<div class="detail-section"><label>Subject</label><div class="detail-value">${task.subject || id}</div></div>
            <div class="detail-section"><label>Domain</label><div class="detail-value">${task.domain || 'N/A'}</div></div>
            <div class="detail-section"><label>Assigned To</label><div class="detail-value">${task.assigned_to || 'Unassigned'}</div></div>
            <div class="detail-section"><label>Description</label><div class="detail-value">${task.description || 'N/A'}</div></div>
            <div class="detail-section"><label>Raw JSON</label><pre class="detail-json">${JSON.stringify(task, null, 2)}</pre></div>`;
    } else if (type === 'worker') {
        title = `${id.toUpperCase()} Details`;
        const w = state.workers[id] || {};
        content = `<div class="detail-section"><label>Status</label><div class="detail-value status-${w.status}">${w.status || 'unknown'}</div></div>
            <div class="detail-section"><label>Domain</label><div class="detail-value">${w.domain || 'None'}</div></div>
            <div class="detail-section"><label>Current Task</label><div class="detail-value">${w.current_task || 'None'}</div></div>
            <div class="detail-section"><label>Tasks Completed</label><div class="detail-value">${w.tasks_completed || 0}/4</div></div>
            <div class="detail-section"><label>Last Heartbeat</label><div class="detail-value">${w.last_heartbeat || 'N/A'}</div></div>
            <div class="detail-section"><label>Last PR</label><div class="detail-value">${w.last_pr ? `<a href="${w.last_pr}" target="_blank">${w.last_pr}</a>` : 'None'}</div></div>
            <div class="detail-section"><label>Raw JSON</label><pre class="detail-json">${JSON.stringify(w, null, 2)}</pre></div>`;
    } else if (type === 'decomp') {
        title = 'Decomposition In Progress';
        content = `<div class="detail-section"><label>Request</label><div class="detail-value">${state.handoff?.request_id || 'N/A'}</div></div>
            <div class="detail-section"><label>Status</label><div class="detail-value">Master-2 is analyzing...</div></div>
            <div class="detail-section"><label>Description</label><div class="detail-value">${state.handoff?.description || 'N/A'}</div></div>`;
    }
    elements.detailTitle.textContent = title;
    elements.detailContent.innerHTML = content;
    elements.detailPanel.classList.remove('hidden');
    state.selectedDetail = { type, id };
};

function renderTaskTree(requestId) {
    const tasks = (state.taskQueue?.tasks || []).filter(t => t.request_id === requestId || !requestId);
    if (tasks.length === 0) return 'No tasks';
    return '<div class="task-tree">' + tasks.map(t => {
        const w = t.assigned_to || 'unassigned';
        const status = t.status === 'completed' ? '[done]' : t.status === 'in_progress' ? '[run]' : '[wait]';
        return `<div class="task-tree-item">${status} "${escapeHtml(t.subject || 'Task')}" → ${w}${t.depends_on ? ` <span class="task-dep">depends: ${t.depends_on}</span>` : ''}</div>`;
    }).join('') + '</div>';
}

function closeDetailPanel() { elements.detailPanel.classList.add('hidden'); state.selectedDetail = null; }

// ═══════════════════════════════════════════════════════════════════════════
// DEBUG PANEL
// ═══════════════════════════════════════════════════════════════════════════
function toggleDebugPanel() {
    const h = elements.debugPanel.classList.toggle('hidden');
    if (!h) { renderDebugLog(); refreshFiles(); refreshRawState(); }
}
function renderDebugLog() {
    const dl = document.getElementById('debug-log-list');
    if (!dl) return;
    dl.innerHTML = DEBUG_LOG.map(e => {
        const sc = e.source === 'MAIN' ? 'main-source' : 'renderer-source';
        return `<div class="debug-entry ${sc}"><span class="debug-time">${e.timestamp.split('T')[1]?.slice(0, 8) || ''}</span>
            <span class="debug-source">${e.source || 'RENDERER'}</span><span class="debug-cat">${e.category}</span>
            <span class="debug-msg">${e.message}</span></div>`;
    }).join('');
    dl.scrollTop = dl.scrollHeight;
}
async function refreshFiles() {
    try {
        const r = await window.electron.checkFiles();
        if (r.error) { elements.filesList.innerHTML = `<div class="debug-error">${r.error}</div>`; return; }
        let html = `<div class="files-section"><strong>Project:</strong> ${r.projectPath?.split('/').pop() || 'N/A'}</div>`;
        html += `<div class="files-section"><strong>State:</strong> ${r.stateDir?.exists ? 'OK' : 'Missing'}</div>`;
        if (r.stateDir?.files) {
            html += '<div class="files-list">';
            for (const f of r.stateDir.files) html += `<div class="file-item"><span class="file-name">${f.name}</span><span class="file-size">${f.size}b</span></div>`;
            html += '</div>';
        }
        elements.filesList.innerHTML = html;
    } catch (e) { elements.filesList.innerHTML = `<div class="debug-error">${e.message}</div>`; }
}
async function refreshRawState() {
    if (elements.rawStateDisplay) {
        elements.rawStateDisplay.textContent = JSON.stringify({
            workers: state.workers, taskQueue: state.taskQueue, handoff: state.handoff,
            master2Ready: state.master2Ready, master3Ready: state.master3Ready
        }, null, 2);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// UTILITIES
// ═══════════════════════════════════════════════════════════════════════════
function parseLogLine(line) {
    const match = line.match(/\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?)\]\s+\[([^\]]+)\]\s+\[([^\]]+)\]\s*(.*)/);
    if (!match) return null;
    const [, timestamp, agent, action, details] = match;
    const date = new Date(timestamp);
    const time = `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
    const agentShort = agent.replace('master-', 'M').replace('worker-', 'W').toUpperCase();
    return {
        time,
        timestamp,
        timestampMs: date.getTime(),
        agent,
        agentShort,
        action,
        details: details.trim()
    };
}
function escapeHtml(text) { if (!text) return ''; const d = document.createElement('div'); d.textContent = text; return d.innerHTML; }
function formatDuration(ms) {
    const s = Math.round(ms / 1000);
    if (s >= 3600) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
    if (s >= 60) return `${Math.floor(s / 60)}m ${s % 60}s`;
    return `${s}s`;
}
function formatAge(ms) {
    const s = Math.round(ms / 1000);
    if (s < 60) return `${s}s ago`;
    if (s < 3600) return `${Math.floor(s / 60)}m ago`;
    return `${Math.floor(s / 3600)}h ago`;
}
function relativeTime(iso) {
    if (!iso) return 'never';
    const ms = Date.now() - new Date(iso).getTime();
    return formatAge(ms);
}

// ═══════════════════════════════════════════════════════════════════════════
// LAUNCH PANEL
// ═══════════════════════════════════════════════════════════════════════════
let launchManifest = null;
let launchedAgentIds = new Set();

async function loadLaunchPanel() {
    debugLog('LAUNCH', 'Loading launch panel');
    try {
        launchManifest = await window.electron.getLauncherManifest();
        if (!launchManifest) {
            const noManifestEl = document.getElementById('launch-no-manifest');
            if (noManifestEl) {
                noManifestEl.classList.remove('hidden');
                // Check what's missing and offer setup
                const setupStatus = await window.electron.checkProjectSetup();
                if (setupStatus.needsSetup) {
                    const missingList = (setupStatus.missing || []).join(', ');
                    noManifestEl.innerHTML = `
                        <div class="setup-missing-info">
                            <h3>Project Setup Required</h3>
                            <p>Missing: ${escapeHtml(missingList)}</p>
                            <p>Run setup to generate agent launchers and orchestration files.</p>
                            <button class="primary-btn" id="launch-run-setup-btn">Run Setup Now</button>
                        </div>`;
                    document.getElementById('launch-run-setup-btn')?.addEventListener('click', () => {
                        // Navigate to setup screen with project pre-filled
                        elements.dashboardScreen.classList.remove('active');
                        elements.connectionScreen.classList.add('active');
                        const pathInput = document.getElementById('setup-project-path');
                        if (pathInput) pathInput.value = setupStatus.path || '';
                        loadRecentProjects();
                    });
                }
            }
            document.getElementById('launch-agents-container')?.classList.add('hidden');
            return;
        }
        document.getElementById('launch-no-manifest')?.classList.add('hidden');
        document.getElementById('launch-agents-container')?.classList.remove('hidden');

        const masters = launchManifest.agents.filter(a => a.group === 'masters');
        const workers = launchManifest.agents.filter(a => a.group === 'workers');

        renderAgentCards('launch-masters-grid', masters, 'master');
        renderAgentCards('launch-workers-grid', workers, 'worker');

        // Refresh launched status
        const launched = await window.electron.getLaunchedAgents();
        launched.forEach(la => launchedAgentIds.add(la.agentId));
        updateLaunchStatuses();

        // Load projects
        await loadProjectList();

        // Render project launch commands
        renderProjectLaunchCommands();
    } catch (e) {
        debugLog('LAUNCH', 'Error loading launch panel', { error: e.message });
    }
}

function renderAgentCards(containerId, agents, type) {
    const container = document.getElementById(containerId);
    if (!container) return;
    container.innerHTML = agents.map(agent => {
        const isLaunched = launchedAgentIds.has(agent.id);
        return `<div class="launch-agent-card ${type}" data-agent-id="${agent.id}">
            <div class="launch-agent-name">${agent.id}</div>
            <div class="launch-agent-role">${agent.role}</div>
            <div class="launch-agent-model">${agent.model}</div>
            <div class="launch-agent-status">
                <span class="launch-status-dot ${isLaunched ? 'launched' : ''}"></span>
                <span>${isLaunched ? 'Running' : 'Ready'}</span>
            </div>
            <button class="launch-agent-btn ${isLaunched ? 'launched' : ''}"
                onclick="launchSingleAgent('${agent.id}')"
                ${isLaunched ? 'disabled' : ''}>
                ${isLaunched ? 'Launched' : 'Launch'}
            </button>
        </div>`;
    }).join('');
}

function updateLaunchStatuses() {
    document.querySelectorAll('.launch-agent-card').forEach(card => {
        const agentId = card.dataset.agentId;
        const isLaunched = launchedAgentIds.has(agentId);

        // Cross-reference health data for actual agent state
        let healthStatus = null;
        if (state.agentHealth) {
            if (agentId === 'master-2') healthStatus = state.agentHealth['master-2']?.effectiveStatus;
            else if (agentId === 'master-3') healthStatus = state.agentHealth['master-3']?.effectiveStatus;
            else if (state.agentHealth.workers?.[agentId]) healthStatus = state.agentHealth.workers[agentId].effectiveStatus;
        }

        const dot = card.querySelector('.launch-status-dot');
        const statusText = card.querySelector('.launch-agent-status span:last-child');
        const btn = card.querySelector('.launch-agent-btn');

        // Determine display state from health + launch tracking
        let displayStatus, dotClass, btnDisabled, btnText;
        if (healthStatus === 'stopped') {
            displayStatus = 'Stopped';
            dotClass = 'stopped';
            btnDisabled = false;
            btnText = 'Relaunch';
        } else if (healthStatus === 'stale') {
            displayStatus = 'Stale';
            dotClass = 'stale';
            btnDisabled = false;
            btnText = 'Relaunch';
        } else if (healthStatus === 'dead') {
            displayStatus = 'Dead';
            dotClass = 'stopped';
            btnDisabled = false;
            btnText = 'Relaunch';
        } else if (healthStatus === 'active' || healthStatus === 'busy' || healthStatus === 'running') {
            displayStatus = 'Running';
            dotClass = 'launched';
            btnDisabled = true;
            btnText = 'Running';
        } else if (isLaunched) {
            displayStatus = 'Launched';
            dotClass = 'launched';
            btnDisabled = true;
            btnText = 'Launched';
        } else {
            displayStatus = 'Ready';
            dotClass = '';
            btnDisabled = false;
            btnText = 'Launch';
        }

        if (dot) {
            dot.classList.remove('launched', 'stale', 'stopped');
            if (dotClass) dot.classList.add(dotClass);
        }
        if (statusText) statusText.textContent = displayStatus;
        if (btn) {
            btn.classList.remove('launched');
            if (dotClass === 'launched') btn.classList.add('launched');
            btn.textContent = btnText;
            btn.disabled = btnDisabled;
        }
    });
}

async function launchSingleAgent(agentId) {
    const continueMode = document.querySelector('input[name="launch-mode"]:checked')?.value === 'continue';
    debugLog('LAUNCH', `Launching ${agentId}`, { continueMode });
    const result = await window.electron.launchAgent({ agentId, continueMode });
    if (result.success) {
        launchedAgentIds.add(agentId);
        updateLaunchStatuses();
        debugLog('LAUNCH', `${agentId} launched successfully`);
    } else {
        debugLog('LAUNCH', `Failed to launch ${agentId}`, { error: result.error });
        alert(`Failed to launch ${agentId}: ${result.error}`);
    }
}

async function launchAgentGroup(group) {
    const continueMode = document.querySelector('input[name="launch-mode"]:checked')?.value === 'continue';
    const mergeTabs = document.getElementById('launch-merge-tabs')?.checked;
    debugLog('LAUNCH', `Launching group: ${group}`, { continueMode, mergeTabs });

    // Windows: use tabbed launch (single window per group)
    const isWindows = navigator.platform === 'Win32' || navigator.userAgent.includes('Windows');
    let result;
    if (isWindows) {
        result = await window.electron.launchGroupTabbed({ group, continueMode });
    } else {
        result = await window.electron.launchGroup({ group, continueMode });
    }

    if (result.success) {
        (result.launched || []).forEach(r => launchedAgentIds.add(r.agentId));
        updateLaunchStatuses();

        // Merge into tabs if requested (macOS)
        if (!isWindows && mergeTabs) {
            setTimeout(async () => {
                await window.electron.mergeTerminalWindows();
            }, 3000);
        }
    } else {
        alert(`Failed to launch group: ${result.error}`);
    }
}

async function launchEverything() {
    debugLog('LAUNCH', 'Launching everything');

    // Windows: launch all agents in a single window with tabs
    const isWindows = navigator.platform === 'Win32' || navigator.userAgent.includes('Windows');
    if (isWindows) {
        const continueMode = document.querySelector('input[name="launch-mode"]:checked')?.value === 'continue';
        const result = await window.electron.launchAllTabbed({ continueMode });
        if (result.success) {
            (result.launched || []).forEach(r => launchedAgentIds.add(r.agentId));
            updateLaunchStatuses();
        } else {
            alert(`Failed to launch: ${result.error}`);
        }
        return;
    }

    // macOS/Linux: launch groups sequentially
    await launchAgentGroup('masters');
    setTimeout(() => launchAgentGroup('workers'), 4000);
}

async function loadProjectList() {
    try {
        const data = await window.electron.listProjects();
        const select = document.getElementById('launch-project-select');
        if (!select) return;
        // Preserve the first option
        select.innerHTML = '<option value="">— Current project —</option>';
        (data.projects || []).forEach(p => {
            const opt = document.createElement('option');
            opt.value = p.path;
            opt.textContent = `${p.name}${p.isActive ? ' (active)' : ''}`;
            if (p.isActive) opt.selected = true;
            select.appendChild(opt);
        });
    } catch (e) {
        debugLog('LAUNCH', 'Error loading projects', { error: e.message });
    }
}

async function addNewProject() {
    const result = await window.electron.addProject();
    if (result.success) {
        debugLog('LAUNCH', 'Project added', { path: result.path });
        await loadProjectList();
    } else if (result.error !== 'No directory selected') {
        alert(`Error: ${result.error}`);
    }
}

async function switchToProject(projectPath) {
    const result = await window.electron.switchProject(projectPath);
    if (result.success) {
        debugLog('LAUNCH', 'Switched to project', { path: projectPath });
        launchedAgentIds.clear();
        await loadLaunchPanel();
    } else {
        alert(`Error switching project: ${result.error}`);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// PROJECT APP LAUNCH COMMANDS
// ═══════════════════════════════════════════════════════════════════════════
const CATEGORY_ICONS = { dev: 'dev', build: 'bld', test: 'tst', run: 'run', docker: 'dkr', lint: 'lnt' };

function renderProjectLaunchCommands() {
    const section = document.getElementById('launch-project-section');
    const grid = document.getElementById('launch-project-grid');
    const sourceLabel = document.getElementById('launch-project-source');
    if (!section || !grid) return;

    const cmds = state.launchCommands;
    section.classList.remove('hidden');

    if (!cmds || cmds.length === 0) {
        grid.innerHTML = '<div class="launch-project-empty">No launch commands detected yet. Master-2 will populate these after scanning the codebase.</div>';
        if (sourceLabel) sourceLabel.textContent = '';
        return;
    }

    // Show source files
    const sources = [...new Set(cmds.map(c => c.source).filter(Boolean))];
    if (sourceLabel) {
        sourceLabel.textContent = sources.length > 0 ? `Detected from ${sources.join(', ')}` : '';
    }

    grid.innerHTML = cmds.map((cmd, i) => {
        const icon = CATEGORY_ICONS[cmd.category] || 'run';
        const catClass = cmd.category || 'run';
        return `<div class="launch-project-card ${catClass}">
            <div class="launch-project-card-header">
                <span class="launch-project-icon">${icon}</span>
                <span class="launch-project-name">${escapeHtml(cmd.name)}</span>
                <span class="launch-project-category">${escapeHtml(cmd.category || 'run')}</span>
            </div>
            <div class="launch-project-command">${escapeHtml(cmd.command)}</div>
            <button class="launch-project-btn" id="proj-launch-btn-${i}" onclick="launchProjectApp(${i})">Launch</button>
        </div>`;
    }).join('');
}

window.launchProjectApp = async function (index) {
    const cmd = state.launchCommands[index];
    if (!cmd) return;

    const btn = document.getElementById(`proj-launch-btn-${index}`);
    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Launching...';
        btn.classList.add('launching');
    }

    try {
        const project = await window.electron.getProject();
        const result = await window.electron.launchProjectCommand({
            command: cmd.command,
            cwd: project?.path || '',
            name: cmd.name
        });

        if (result.success) {
            if (btn) {
                btn.textContent = 'Launched';
                btn.classList.remove('launching');
                btn.classList.add('launched');
            }
            debugLog('LAUNCH', `Project command launched: ${cmd.name}`, { command: cmd.command });
        } else {
            if (btn) {
                btn.textContent = 'Failed';
                btn.classList.remove('launching');
            }
            debugLog('LAUNCH', `Failed to launch: ${cmd.name}`, { error: result.error });
        }
    } catch (e) {
        if (btn) {
            btn.textContent = 'Error';
            btn.classList.remove('launching');
        }
        debugLog('LAUNCH', `Error launching: ${cmd.name}`, { error: e.message });
    }

    // Reset button after 5s
    setTimeout(() => {
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Launch';
            btn.className = 'launch-project-btn';
        }
    }, 5000);
};

window.addEventListener('beforeunload', () => {
    stopHealthPolling();
    stopSignalAgeUpdater();
    stopWatchdogPolling();
});

// ═══════════════════════════════════════════════════════════════════════════
// CHAT SYSTEM
// ═══════════════════════════════════════════════════════════════════════════

function addChatMessage(msg) {
    const id = msg.id || `${msg.role}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    if (state.chatMessageIds.has(id)) return;
    state.chatMessageIds.add(id);
    const fullMsg = { ...msg, id };
    state.chatMessages.push(fullMsg);
    renderSingleChatMsg(fullMsg);
    scrollChatToBottom();
}

function renderSingleChatMsg(msg) {
    const el = document.getElementById('chat-messages');
    if (!el) return;
    // Remove welcome on first message
    const welcome = document.getElementById('chat-welcome');
    if (welcome) welcome.remove();
    // Remove typing indicator before inserting
    const typing = el.querySelector('.chat-typing');
    if (typing) typing.remove();
    el.insertAdjacentHTML('beforeend', chatMsgHtml(msg));
    // Re-add typing if still thinking
    if (state.isThinking) el.insertAdjacentHTML('beforeend', typingHtml());
}

function chatMsgHtml(msg) {
    const time = msg.timestamp ? new Date(msg.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';

    if (msg.role === 'user') {
        return `<div class="chat-msg user">
            <div class="chat-avatar">U</div>
            <div class="chat-bubble">
                <div class="bubble-content">${escapeHtml(msg.content)}</div>
                <div class="bubble-meta">${time}</div>
            </div></div>`;
    }

    if (msg.role === 'system') {
        return `<div class="chat-msg system">
            <div class="chat-bubble">
                <span class="system-dot">●</span> ${msg.html ? msg.content : escapeHtml(msg.content)}
                ${time ? `<span class="bubble-time">${time}</span>` : ''}
            </div></div>`;
    }

    // Assistant
    const agentLabel = msg.agent || 'M1';
    const agentClass = agentLabel.startsWith('M2') ? 'm2' : agentLabel.startsWith('M3') ? 'm3' : agentLabel.startsWith('W') ? 'worker' : 'm1';
    const successClass = msg.type === 'success' ? ' success' : '';
    const avatarIcon = agentClass === 'm1' ? 'M1' : agentClass === 'm2' ? 'M2' : agentClass === 'm3' ? 'M3' : 'W';
    return `<div class="chat-msg assistant${successClass}">
        <div class="chat-avatar chat-avatar-${agentClass}">${avatarIcon}</div>
        <div class="chat-bubble">
            ${msg.agentTag ? `<div class="chat-agent-tag ${agentClass}">${msg.agentTag}</div>` : ''}
            <div class="bubble-content">${msg.html ? msg.content : escapeHtml(msg.content)}</div>
            <div class="bubble-meta">${time}</div>
        </div></div>`;
}

function typingHtml() {
    return `<div class="chat-typing">
        <div class="chat-avatar chat-avatar-m2">M2</div>
        <div class="typing-dots"><span></span><span></span><span></span></div>
    </div>`;
}

function showTypingIndicator(show) {
    state.isThinking = show;
    const el = document.getElementById('chat-messages');
    if (!el) return;
    const existing = el.querySelector('.chat-typing');
    if (show && !existing) {
        el.insertAdjacentHTML('beforeend', typingHtml());
        scrollChatToBottom();
    } else if (!show && existing) {
        existing.remove();
    }
}

function scrollChatToBottom() {
    const el = document.getElementById('chat-messages');
    if (el) requestAnimationFrame(() => { el.scrollTop = el.scrollHeight; });
}

function chatFromLogEntry(entry) {
    const reqMatch = entry.details.match(/(?:request_id|id)[=:\s]*([^\s,\]]+)/i);
    const reqId = reqMatch ? reqMatch[1] : null;

    // Tier classification
    if (entry.agent.includes('master-2') && entry.action === 'TIER_CLASSIFY') {
        const tierMatch = entry.details.match(/tier[=:\s]*(\d)/i);
        const tier = tierMatch ? parseInt(tierMatch[1]) : null;
        if (tier) {
            showTypingIndicator(false);
            addChatMessage({
                id: `tier-${reqId}`, role: 'assistant', agent: 'M2',
                agentTag: 'Master-2 \u00b7 Architect',
                content: `Classified as <span class="chat-tier-badge tier-${tier}">Tier ${tier}</span> \u2014 ${TIER_LABELS[tier]}`,
                html: true, timestamp: entry.timestamp, type: 'tier'
            });
            if (tier > 1) showTypingIndicator(true);
        }
    }

    // Decomposition start
    if (entry.agent.includes('master-2') && entry.action === 'DECOMPOSE_START') {
        showTypingIndicator(false);
        addChatMessage({ id: `decomp-start-${reqId}`, role: 'system', content: 'Decomposing request into tasks\u2026', timestamp: entry.timestamp });
        showTypingIndicator(true);
    }

    // Decomposition done
    if (entry.agent.includes('master-2') && entry.action === 'DECOMPOSE_DONE') {
        showTypingIndicator(false);
        const taskCount = entry.details.match(/(\d+)\s*tasks?/i);
        const count = taskCount ? taskCount[1] : '?';
        addChatMessage({
            id: `decomp-done-${reqId}`, role: 'assistant', agent: 'M2',
            agentTag: 'Master-2 \u00b7 Architect',
            content: `Decomposed into <strong>${count}</strong> tasks. Handing off to allocator.`,
            html: true, timestamp: entry.timestamp
        });
        showTypingIndicator(true);
    }

    // Allocation
    if (entry.agent.includes('master-3') && entry.action === 'ALLOCATE') {
        showTypingIndicator(false);
        addChatMessage({
            id: `alloc-${entry.details.slice(0, 30)}-${entry.timestamp}`, role: 'assistant', agent: 'M3',
            agentTag: 'Master-3 \u00b7 Allocator',
            content: escapeHtml(entry.details), timestamp: entry.timestamp, type: 'status'
        });
    }

    // Worker claimed task
    if (entry.agent.includes('worker') && entry.action === 'TASK_CLAIMED') {
        const wid = entry.agent.match(/worker-(\d+)/)?.[0] || entry.agent;
        addChatMessage({
            id: `claimed-${wid}-${entry.timestamp}`, role: 'system',
            content: `${wid.toUpperCase()} started: ${entry.details.slice(0, 80)}`,
            timestamp: entry.timestamp
        });
    }

    // Worker completed
    if (entry.agent.includes('worker') && entry.action === 'COMPLETE') {
        const wid = entry.agent.match(/worker-(\d+)/)?.[0] || entry.agent;
        addChatMessage({
            id: `complete-${wid}-${entry.timestamp}`, role: 'assistant',
            agent: wid.replace('worker-', 'W'), agentTag: `${wid.toUpperCase()} \u00b7 Complete`,
            content: `Task completed: ${escapeHtml(entry.details.slice(0, 100))}`,
            timestamp: entry.timestamp, type: 'success'
        });
    }

    // Merge / integration
    if (entry.agent.includes('master-3') && entry.action === 'MERGE_PR') {
        showTypingIndicator(false);
        addChatMessage({
            id: `merge-${reqId}-${entry.timestamp}`, role: 'assistant', agent: 'M3',
            agentTag: 'Master-3 \u00b7 Integration',
            content: `All work complete! Changes merged. ${escapeHtml(entry.details)}`,
            timestamp: entry.timestamp, type: 'success'
        });
    }

    // Tier 1 direct execution
    if (entry.agent.includes('master-2') && entry.action === 'TIER1_EXECUTE') {
        showTypingIndicator(false);
        addChatMessage({
            id: `tier1-exec-${entry.timestamp}`, role: 'assistant', agent: 'M2',
            agentTag: 'Master-2 \u00b7 Direct',
            content: `Executing directly: ${escapeHtml(entry.details)}`,
            timestamp: entry.timestamp, type: 'status'
        });
    }

    if (entry.agent.includes('master-2') && entry.action === 'TIER1_COMPLETE') {
        showTypingIndicator(false);
        addChatMessage({
            id: `tier1-done-${entry.timestamp}`, role: 'assistant', agent: 'M2',
            agentTag: 'Master-2 \u00b7 Complete',
            content: `Done! ${escapeHtml(entry.details)}`,
            timestamp: entry.timestamp, type: 'success'
        });
    }
}

function renderChatStatusStrip() {
    // Currently a no-op since we removed the strip; agents are shown in pipeline
}

// ═══════════════════════════════════════════════════════════════════════════
// FILE TREE
// ═══════════════════════════════════════════════════════════════════════════

const CLAUDE_MD_NAMES = new Set(['CLAUDE.md', 'claude.md', '.claude.md']);

async function loadFileTree() {
    try {
        const tree = await window.electron.getFileTree(4);
        if (!tree) {
            document.getElementById('file-tree').innerHTML = '<div class="tree-empty">No project loaded</div>';
            return;
        }
        state.fileTree = tree;
        renderFileTree(tree);
    } catch (e) {
        debugLog('TREE', 'Error loading file tree', { error: e.message });
        document.getElementById('file-tree').innerHTML = '<div class="tree-empty">Error loading files</div>';
    }
}

function renderFileTree(tree) {
    const container = document.getElementById('file-tree');
    if (!container) return;
    container.innerHTML = renderTreeNode(tree.children || [], 0);
}

function renderTreeNode(nodes, depth) {
    if (!nodes || nodes.length === 0) return '';
    return nodes.map(node => {
        const indent = depth * 14;
        const isHighlighted = CLAUDE_MD_NAMES.has(node.name);
        const hlClass = isHighlighted ? ' highlighted' : '';

        if (node.type === 'directory') {
            const icon = '<span class="tree-icon">></span>';
            const childHtml = renderTreeNode(node.children || [], depth + 1);
            // Auto-expand first two levels and dirs containing CLAUDE.md
            const hasClaudeMd = (node.children || []).some(c => CLAUDE_MD_NAMES.has(c.name));
            const autoOpen = depth < 1 || hasClaudeMd ? ' open' : '';
            return `<div class="tree-item${hlClass}" style="padding-left:${indent + 10}px" onclick="toggleTreeDir(this)">
                ${icon}<span class="tree-name">${escapeHtml(node.name)}</span>
            </div><div class="tree-children${autoOpen}">${childHtml}</div>`;
        }

        const icon = '<span class="tree-icon">·</span>';
        return `<div class="tree-item${hlClass}" style="padding-left:${indent + 10}px" title="${escapeHtml(node.path)}"
            onclick="openFileViewer('${escapeHtml(node.path)}')">
            ${icon}<span class="tree-name">${escapeHtml(node.name)}</span>
        </div>`;
    }).join('');
}

window.toggleTreeDir = function (el) {
    const sibling = el.nextElementSibling;
    if (sibling && sibling.classList.contains('tree-children')) {
        sibling.classList.toggle('open');
    }
};

window.openFileViewer = async function (relativePath) {
    if (!relativePath) return;
    const pathEl = document.getElementById('file-viewer-path');
    const metaEl = document.getElementById('file-viewer-meta');
    const contentEl = document.getElementById('file-viewer-content');
    const gutterEl = document.getElementById('editor-gutter');
    if (pathEl) pathEl.textContent = relativePath;
    if (metaEl) metaEl.textContent = 'Loading...';
    if (contentEl) contentEl.textContent = 'Loading...';
    if (gutterEl) gutterEl.innerHTML = '';

    // Highlight active tree item
    document.querySelectorAll('.tree-item.active').forEach(el => el.classList.remove('active'));
    document.querySelectorAll('.tree-item').forEach(el => {
        if (el.getAttribute('title') === relativePath) el.classList.add('active');
    });

    try {
        const result = await window.electron.readFileContent(relativePath);
        if (result.error) {
            if (contentEl) contentEl.textContent = `Error: ${result.error}`;
            if (metaEl) metaEl.textContent = '';
            return;
        }
        if (contentEl) contentEl.textContent = result.content;
        // Populate line number gutter
        if (gutterEl && result.content) {
            const lineCount = result.content.split('\n').length;
            let gutterHtml = '';
            for (let i = 1; i <= lineCount; i++) {
                gutterHtml += `<span class="ln">${i}</span>`;
            }
            gutterEl.innerHTML = gutterHtml;
        }
        // Sync gutter scroll with content scroll
        if (contentEl && gutterEl) {
            contentEl.onscroll = () => { gutterEl.scrollTop = contentEl.scrollTop; };
        }
        if (metaEl) {
            const sizeStr = result.size > 1024 ? `${(result.size / 1024).toFixed(1)} KB` : `${result.size} B`;
            const lines = result.content ? result.content.split('\n').length : 0;
            metaEl.textContent = `${lines} lines · ${sizeStr}${result.truncated ? ' · truncated' : ''}`;
        }
    } catch (e) {
        if (contentEl) contentEl.textContent = `Error: ${e.message}`;
        if (metaEl) metaEl.textContent = '';
    }
};

// Initialize
init();
