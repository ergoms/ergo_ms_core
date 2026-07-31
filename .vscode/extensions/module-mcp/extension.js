const vscode = require('vscode');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const { spawn } = require('child_process');

const OUTPUT_CHANNEL_NAME = 'ERGO MS Module MCP';
const SYNC_DEBOUNCE_MS = 400;

/** @type {vscode.OutputChannel | undefined} */
let output;
/** @type {string[]} */
let registeredMcpNames = [];
/** @type {boolean} */
let mcpApiWarningShown = false;
/** @type {NodeJS.Timeout | undefined} */
let debounceTimer;
/** @type {vscode.FileSystemWatcher[]} */
let watchers = [];

/**
 * @param {string} message
 */
function log(message) {
  if (!output) {
    output = vscode.window.createOutputChannel(OUTPUT_CHANNEL_NAME);
  }
  output.appendLine(message);
}

/**
 * @returns {string | undefined}
 */
function findWorkspaceRoot() {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    return undefined;
  }
  for (const folder of folders) {
    const root = folder.uri.fsPath;
    if (
      fs.existsSync(path.join(root, '.cursor', 'mcp.registry.yaml')) ||
      (fs.existsSync(path.join(root, 'modules')) && fs.existsSync(path.join(root, '.cursor')))
    ) {
      return root;
    }
  }
  return folders[0].uri.fsPath;
}

/**
 * @param {string} workspaceRoot
 * @returns {string | undefined}
 */
function resolveProjectPython(workspaceRoot) {
  const winPy = path.join(workspaceRoot, 'virtual_env', 'python', 'Scripts', 'python.exe');
  const unixPy = path.join(workspaceRoot, 'virtual_env', 'python', 'bin', 'python');
  if (fs.existsSync(winPy)) {
    return winPy;
  }
  if (fs.existsSync(unixPy)) {
    return unixPy;
  }
  return undefined;
}

/**
 * @param {string} command
 * @param {string[]} args
 * @param {string} cwd
 * @returns {Promise<{ code: number, stdout: string, stderr: string }>}
 */
function runProcess(command, args, cwd) {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      cwd,
      shell: process.platform === 'win32',
      env: {
        ...process.env,
        PYTHONIOENCODING: 'utf-8',
        PYTHONUTF8: '1',
      },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on('data', (chunk) => {
      stderr += String(chunk);
    });
    child.on('error', (err) => {
      resolve({ code: 1, stdout, stderr: `${stderr}${err.message}` });
    });
    child.on('close', (code) => {
      resolve({ code: code == null ? 1 : code, stdout, stderr });
    });
  });
}

/**
 * @returns {{ registerServer?: (c: any) => void, unregisterServer?: (n: string) => void } | undefined}
 */
function getCursorMcpApi() {
  const cursor = /** @type {any} */ (vscode).cursor;
  if (!cursor || !cursor.mcp) {
    return undefined;
  }
  const { registerServer, unregisterServer } = cursor.mcp;
  if (typeof registerServer !== 'function' || typeof unregisterServer !== 'function') {
    return undefined;
  }
  return { registerServer, unregisterServer };
}

function unregisterMcpServers() {
  const api = getCursorMcpApi();
  if (!api) {
    registeredMcpNames = [];
    return;
  }
  for (const name of registeredMcpNames) {
    try {
      api.unregisterServer(name);
      log(`[INFO] unregisterServer: ${name}`);
    } catch (err) {
      log(`[WARNING] unregisterServer ${name}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  registeredMcpNames = [];
}

/**
 * @param {string} workspaceRoot
 * @returns {Promise<{ name: string, description: string, source: string, script: string, config: { command: string, args: string[] } }[]>}
 */
async function loadMcpEntries(workspaceRoot) {
  const python = resolveProjectPython(workspaceRoot);
  const script = path.join(workspaceRoot, '.cursor', 'mcp_sync.py');
  if (!python || !fs.existsSync(script)) {
    log('[WARNING] Python проекта или mcp_sync.py не найдены — MCP discovery пропущен');
    return [];
  }

  const result = await runProcess(python, [script, 'list', '--json'], workspaceRoot);
  if (result.code !== 0) {
    log(`[ERROR] mcp_sync list --json: ${result.stderr || result.stdout}`);
    return [];
  }
  const text = result.stdout.trim();
  if (!text) {
    return [];
  }
  try {
    const data = JSON.parse(text);
    if (!Array.isArray(data)) {
      log('[ERROR] mcp_sync list --json: ожидался массив');
      return [];
    }
    return data;
  } catch (err) {
    log(`[ERROR] Разбор JSON MCP: ${err instanceof Error ? err.message : String(err)}`);
    return [];
  }
}

/**
 * @param {string} workspaceRoot
 * @returns {Promise<Record<string, any>>}
 */
async function readExistingMcpServers(workspaceRoot) {
  const mcpPath = path.join(workspaceRoot, '.cursor', 'mcp.json');
  try {
    const raw = await fsp.readFile(mcpPath, 'utf8');
    const data = JSON.parse(raw);
    if (data && typeof data === 'object' && data.mcpServers && typeof data.mcpServers === 'object') {
      return data.mcpServers;
    }
  } catch {
    // нет файла или битый JSON
  }
  return {};
}

/**
 * Все серверы в mcp.json (установлены). Новые — disabled: true; уже существующие — сохранить disabled.
 * @param {string} workspaceRoot
 * @param {{ name: string, config: { command: string, args: string[] } }[]} entries
 * @returns {Promise<Record<string, any>>}
 */
async function writeMcpJsonInstalled(workspaceRoot, entries) {
  const existing = await readExistingMcpServers(workspaceRoot);
  /** @type {Record<string, any>} */
  const servers = {};

  for (const entry of entries) {
    const cfg = entry.config || {};
    if (!entry.name || !cfg.command) {
      continue;
    }
    const prev = existing[entry.name];
    const disabled =
      prev && typeof prev === 'object' && typeof prev.disabled === 'boolean'
        ? prev.disabled
        : true;

    servers[entry.name] = {
      command: cfg.command,
      args: Array.isArray(cfg.args) ? cfg.args : [],
      disabled,
    };
  }

  const mcpPath = path.join(workspaceRoot, '.cursor', 'mcp.json');
  await fsp.writeFile(
    mcpPath,
    `${JSON.stringify({ mcpServers: servers }, null, 4)}\n`,
    'utf8',
  );

  const enabledCount = Object.values(servers).filter((s) => s && s.disabled === false).length;
  const disabledCount = Object.keys(servers).length - enabledCount;
  log(
    `[OK] .cursor/mcp.json: ${Object.keys(servers).length} установлено ` +
      `(включено ${enabledCount}, выключено ${disabledCount})`,
  );
  return servers;
}

/**
 * @param {string} workspaceRoot
 * @param {string[]} names
 * @param {boolean} disabled
 */
async function setDisabledFlags(workspaceRoot, names, disabled) {
  const existing = await readExistingMcpServers(workspaceRoot);
  const nameSet = new Set(names);
  for (const [name, cfg] of Object.entries(existing)) {
    if (!nameSet.has(name) || !cfg || typeof cfg !== 'object') {
      continue;
    }
    existing[name] = { ...cfg, disabled };
  }
  const mcpPath = path.join(workspaceRoot, '.cursor', 'mcp.json');
  await fsp.writeFile(
    mcpPath,
    `${JSON.stringify({ mcpServers: existing }, null, 4)}\n`,
    'utf8',
  );
}

/**
 * @param {boolean} [showInfo]
 */
async function syncMcpServers(showInfo = false) {
  const workspaceRoot = findWorkspaceRoot();
  if (!workspaceRoot) {
    log('[WARNING] Корень workspace не найден');
    if (showInfo) {
      vscode.window.showWarningMessage('ERGO MS Module MCP: корень workspace не найден');
    }
    return;
  }

  log(`[INFO] Workspace: ${workspaceRoot}`);
  const entries = await loadMcpEntries(workspaceRoot);
  log(`[INFO] MCP: в каталоге ${entries.length}`);

  const servers = await writeMcpJsonInstalled(workspaceRoot, entries);
  const enabledNames = Object.entries(servers)
    .filter(([, cfg]) => cfg && cfg.disabled === false)
    .map(([name]) => name);

  const api = getCursorMcpApi();
  if (!api) {
    if (!mcpApiWarningShown) {
      mcpApiWarningShown = true;
      log(
        '[WARNING] vscode.cursor.mcp.registerServer недоступен. ' +
          'Серверы в mcp.json (disabled по умолчанию). Reload MCP / включите в Settings → Tools & MCP.',
      );
    }
    if (showInfo) {
      vscode.window.showInformationMessage(
        `ERGO MS Module MCP: ${entries.length} установлено, ${enabledNames.length} включено`,
      );
    }
    return;
  }

  unregisterMcpServers();
  /** @type {string[]} */
  const okNames = [];
  for (const entry of entries) {
    if (!enabledNames.includes(entry.name)) {
      continue;
    }
    const cfg = entry.config || {};
    if (!entry.name || !cfg.command) {
      continue;
    }
    try {
      api.registerServer({
        name: entry.name,
        server: {
          command: cfg.command,
          args: Array.isArray(cfg.args) ? cfg.args : [],
          env: {},
        },
      });
      okNames.push(entry.name);
      log(`[OK] registerServer: ${entry.name} (${entry.source})`);
    } catch (err) {
      log(
        `[ERROR] registerServer ${entry.name}: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }
  registeredMcpNames = okNames;
  log(
    `[OK] Sync: установлено ${entries.length}, registerServer для включённых: ${okNames.length}`,
  );

  if (showInfo) {
    vscode.window.showInformationMessage(
      `ERGO MS Module MCP: ${entries.length} установлено, ${okNames.length} включено`,
    );
  }
}

/**
 * @returns {Promise<void>}
 */
async function enableMcpServers() {
  const workspaceRoot = findWorkspaceRoot();
  if (!workspaceRoot) {
    vscode.window.showWarningMessage('ERGO MS Module MCP: корень workspace не найден');
    return;
  }
  const servers = await readExistingMcpServers(workspaceRoot);
  const names = Object.keys(servers).sort();
  if (names.length === 0) {
    await syncMcpServers(false);
    const again = await readExistingMcpServers(workspaceRoot);
    if (Object.keys(again).length === 0) {
      vscode.window.showInformationMessage('ERGO MS Module MCP: серверы не найдены');
      return;
    }
  }
  const current = await readExistingMcpServers(workspaceRoot);
  const items = Object.keys(current)
    .sort()
    .map((name) => ({
      label: name,
      description: current[name] && current[name].disabled === false ? 'включён' : 'выключен',
      picked: current[name] && current[name].disabled === false,
    }));
  const picked = await vscode.window.showQuickPick(items, {
    canPickMany: true,
    placeHolder: 'Отметьте серверы для включения (остальные останутся выключенными)',
    title: 'ERGO MS: Enable MCP Servers',
  });
  if (!picked) {
    return;
  }
  const enableSet = new Set(picked.map((p) => p.label));
  for (const name of Object.keys(current)) {
    current[name] = {
      ...current[name],
      disabled: !enableSet.has(name),
    };
  }
  const mcpPath = path.join(workspaceRoot, '.cursor', 'mcp.json');
  await fsp.writeFile(
    mcpPath,
    `${JSON.stringify({ mcpServers: current }, null, 4)}\n`,
    'utf8',
  );
  await syncMcpServers(true);
}

/**
 * @returns {Promise<void>}
 */
async function disableMcpServers() {
  const workspaceRoot = findWorkspaceRoot();
  if (!workspaceRoot) {
    vscode.window.showWarningMessage('ERGO MS Module MCP: корень workspace не найден');
    return;
  }
  const current = await readExistingMcpServers(workspaceRoot);
  const enabled = Object.keys(current).filter(
    (name) => current[name] && current[name].disabled === false,
  );
  if (enabled.length === 0) {
    vscode.window.showInformationMessage('ERGO MS Module MCP: нет включённых серверов');
    return;
  }
  const items = enabled.map((name) => ({
    label: name,
    picked: false,
  }));
  const picked = await vscode.window.showQuickPick(items, {
    canPickMany: true,
    placeHolder: 'Отметьте серверы, которые нужно выключить',
    title: 'ERGO MS: Disable MCP Servers',
  });
  if (!picked || picked.length === 0) {
    return;
  }
  await setDisabledFlags(
    workspaceRoot,
    picked.map((p) => p.label),
    true,
  );
  await syncMcpServers(true);
}

function scheduleSync() {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
  debounceTimer = setTimeout(() => {
    debounceTimer = undefined;
    syncMcpServers(false).catch((err) => {
      log(`[ERROR] sync: ${err instanceof Error ? err.message : String(err)}`);
    });
  }, SYNC_DEBOUNCE_MS);
}

/**
 * @param {vscode.ExtensionContext} context
 * @param {string} workspaceRoot
 * @param {string} glob
 */
function addWatcher(context, workspaceRoot, glob) {
  const pattern = new vscode.RelativePattern(workspaceRoot, glob);
  const watcher = vscode.workspace.createFileSystemWatcher(pattern);
  watcher.onDidCreate(() => scheduleSync());
  watcher.onDidChange(() => scheduleSync());
  watcher.onDidDelete(() => scheduleSync());
  context.subscriptions.push(watcher);
  watchers.push(watcher);
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
  output = vscode.window.createOutputChannel(OUTPUT_CHANNEL_NAME);
  log('[INFO] ERGO MS Module MCP активировано (серверы установлены, по умолчанию выключены)');

  context.subscriptions.push(
    vscode.commands.registerCommand('ergo-ms-module-mcp.sync', () => syncMcpServers(true)),
    vscode.commands.registerCommand('ergo-ms-module-mcp.enable', () => enableMcpServers()),
    vscode.commands.registerCommand('ergo-ms-module-mcp.disable', () => disableMcpServers()),
  );

  const workspaceRoot = findWorkspaceRoot();
  if (workspaceRoot) {
    addWatcher(context, workspaceRoot, 'modules/*/mcp/**');
    addWatcher(context, workspaceRoot, '.cursor/mcp.registry.yaml');
    addWatcher(context, workspaceRoot, 'databases.yaml');
  }

  syncMcpServers(false).catch((err) => {
    log(`[ERROR] initial sync: ${err instanceof Error ? err.message : String(err)}`);
  });
}

function deactivate() {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
    debounceTimer = undefined;
  }
  unregisterMcpServers();
  watchers = [];
}

module.exports = {
  activate,
  deactivate,
};
