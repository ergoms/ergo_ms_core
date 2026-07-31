const vscode = require('vscode');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');

const OUTPUT_CHANNEL_NAME = 'ERGO MS Module Rules';
const STAGING_REL = path.join('virtual_env', 'cache', 'cursor-module-plugins');
const SYNC_DEBOUNCE_MS = 400;

/** @type {vscode.OutputChannel | undefined} */
let output;
/** @type {string[]} */
let registeredPluginPaths = [];
/** @type {string | undefined} */
let registeredLegacyPath;
/** @type {boolean} */
let apiWarningShown = false;
/** @type {NodeJS.Timeout | undefined} */
let debounceTimer;
/** @type {vscode.FileSystemWatcher | undefined} */
let watcher;

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
 * @param {string} dir
 * @returns {Promise<boolean>}
 */
async function isDir(dir) {
  try {
    const st = await fsp.stat(dir);
    return st.isDirectory();
  } catch {
    return false;
  }
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
      fs.existsSync(path.join(root, 'modules')) &&
      fs.existsSync(path.join(root, '.cursor'))
    ) {
      return root;
    }
  }
  return folders[0].uri.fsPath;
}

/**
 * @param {string} name
 * @returns {string}
 */
function toKebab(name) {
  return String(name)
    .replace(/_/g, '-')
    .replace(/[^a-zA-Z0-9.-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase();
}

/**
 * @param {string} rulesDir
 * @returns {Promise<string[]>}
 */
async function listMdcFiles(rulesDir) {
  if (!(await isDir(rulesDir))) {
    return [];
  }
  const entries = await fsp.readdir(rulesDir, { withFileTypes: true });
  return entries
    .filter((e) => e.isFile() && e.name.endsWith('.mdc'))
    .map((e) => e.name)
    .sort();
}

/**
 * @param {string} workspaceRoot
 * @returns {Promise<{ moduleName: string, rulesDir: string, files: string[] }[]>}
 */
async function scanModules(workspaceRoot) {
  const modulesRoot = path.join(workspaceRoot, 'modules');
  if (!(await isDir(modulesRoot))) {
    return [];
  }
  const entries = await fsp.readdir(modulesRoot, { withFileTypes: true });
  /** @type {{ moduleName: string, rulesDir: string, files: string[] }[]} */
  const result = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.') || entry.name === '__pycache__') {
      continue;
    }
    const rulesDir = path.join(modulesRoot, entry.name, '.cursor', 'rules');
    const files = await listMdcFiles(rulesDir);
    if (files.length === 0) {
      continue;
    }
    result.push({ moduleName: entry.name, rulesDir, files });
  }
  result.sort((a, b) => a.moduleName.localeCompare(b.moduleName));
  return result;
}

/**
 * @param {string} dir
 */
async function rmrf(dir) {
  await fsp.rm(dir, { recursive: true, force: true });
}

/**
 * @param {string} stagingRoot
 * @param {{ moduleName: string, rulesDir: string, files: string[] }[]} modules
 * @returns {Promise<string[]>} absolute plugin roots (each with .cursor-plugin/plugin.json)
 */
async function buildStaging(stagingRoot, modules) {
  await rmrf(stagingRoot);
  await fsp.mkdir(stagingRoot, { recursive: true });

  /** @type {string[]} */
  const pluginRoots = [];

  for (const mod of modules) {
    const pluginDir = path.join(stagingRoot, mod.moduleName);
    const pluginMetaDir = path.join(pluginDir, '.cursor-plugin');
    const rulesOut = path.join(pluginDir, 'rules');
    await fsp.mkdir(pluginMetaDir, { recursive: true });
    await fsp.mkdir(rulesOut, { recursive: true });

    const kebab = toKebab(mod.moduleName);
    const pluginJson = {
      name: `ergo-module-${kebab}`,
      description: `Cursor rules for module ${mod.moduleName}`,
    };
    await fsp.writeFile(
      path.join(pluginMetaDir, 'plugin.json'),
      `${JSON.stringify(pluginJson, null, 2)}\n`,
      'utf8',
    );

    for (const file of mod.files) {
      const src = path.join(mod.rulesDir, file);
      const dest = path.join(rulesOut, file);
      await fsp.copyFile(src, dest);
    }

    pluginRoots.push(pluginDir);
  }

  return pluginRoots;
}

/**
 * Реальный API Cursor: addPlugin / removePlugin ({ path }).
 * В устаревшей документации — registerPath / unregisterPath (строка).
 *
 * @returns {{
 *   mode: 'addPlugin' | 'registerPath',
 *   addPlugin?: (config: { path: string }) => void | Thenable<void>,
 *   removePlugin?: (config: { path: string }) => void | Thenable<void>,
 *   registerPath?: (p: string) => void,
 *   unregisterPath?: (p: string) => void,
 * } | undefined}
 */
function getCursorPluginsApi() {
  const cursor = /** @type {any} */ (vscode).cursor;
  if (!cursor || !cursor.plugins) {
    return undefined;
  }
  const plugins = cursor.plugins;

  if (typeof plugins.addPlugin === 'function' && typeof plugins.removePlugin === 'function') {
    return {
      mode: 'addPlugin',
      addPlugin: plugins.addPlugin.bind(plugins),
      removePlugin: plugins.removePlugin.bind(plugins),
    };
  }

  if (typeof plugins.registerPath === 'function' && typeof plugins.unregisterPath === 'function') {
    return {
      mode: 'registerPath',
      registerPath: plugins.registerPath.bind(plugins),
      unregisterPath: plugins.unregisterPath.bind(plugins),
    };
  }

  const keys = Object.keys(plugins).join(', ') || '(пусто)';
  log(`[WARNING] vscode.cursor.plugins есть, но без addPlugin/registerPath. Ключи: ${keys}`);
  return undefined;
}

/**
 * @param {unknown} value
 * @returns {Promise<void>}
 */
async function awaitMaybe(value) {
  if (value != null && typeof /** @type {any} */ (value).then === 'function') {
    await value;
  }
}

async function unregisterStaging() {
  const api = getCursorPluginsApi();
  if (!api) {
    registeredPluginPaths = [];
    registeredLegacyPath = undefined;
    return;
  }

  if (api.mode === 'addPlugin' && api.removePlugin) {
    for (const pluginPath of registeredPluginPaths) {
      try {
        await awaitMaybe(api.removePlugin({ path: pluginPath }));
        log(`[INFO] removePlugin: ${pluginPath}`);
      } catch (err) {
        log(`[WARNING] removePlugin: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
  } else if (api.mode === 'registerPath' && api.unregisterPath && registeredLegacyPath) {
    try {
      api.unregisterPath(registeredLegacyPath);
      log(`[INFO] unregisterPath: ${registeredLegacyPath}`);
    } catch (err) {
      log(`[WARNING] unregisterPath: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  registeredPluginPaths = [];
  registeredLegacyPath = undefined;
}

/**
 * @param {boolean} [showInfo]
 * @returns {Promise<void>}
 */
async function syncModuleRules(showInfo = false) {
  const workspaceRoot = findWorkspaceRoot();
  if (!workspaceRoot) {
    log('[WARNING] Корень workspace не найден');
    if (showInfo) {
      vscode.window.showWarningMessage('ERGO MS Module Rules: корень workspace не найден');
    }
    return;
  }

  const modules = await scanModules(workspaceRoot);
  const stagingRoot = path.join(workspaceRoot, STAGING_REL);

  log(`[INFO] Workspace: ${workspaceRoot}`);
  log(`[INFO] Модулей с .cursor/rules: ${modules.length}`);

  const pluginRoots = await buildStaging(stagingRoot, modules);

  for (const mod of modules) {
    log(`[OK] ${mod.moduleName}: ${mod.files.length} — ${mod.files.join(', ')}`);
  }

  const api = getCursorPluginsApi();
  if (!api) {
    if (!apiWarningShown) {
      apiWarningShown = true;
      log(
        '[WARNING] vscode.cursor.plugins.addPlugin / registerPath недоступен. ' +
          'Нужен Cursor с Extension API plugins. Модульные .mdc не зарегистрированы; ' +
          'остаётся fallback AGENTS.md в модуле.',
      );
      vscode.window.showWarningMessage(
        'ERGO MS Module Rules: Cursor plugins API недоступен. Используйте Cursor или AGENTS.md в модуле.',
      );
    }
    if (showInfo) {
      vscode.window.showInformationMessage(
        `ERGO MS Module Rules: staging обновлён (${modules.length} модулей), API plugins недоступен`,
      );
    }
    return;
  }

  await unregisterStaging();

  try {
    if (api.mode === 'addPlugin' && api.addPlugin) {
      // addPlugin принимает корень одного плагина (.cursor-plugin/plugin.json), не родитель staging
      for (const pluginPath of pluginRoots) {
        await awaitMaybe(api.addPlugin({ path: pluginPath }));
        registeredPluginPaths.push(pluginPath);
        log(`[OK] addPlugin: ${pluginPath}`);
      }
    } else if (api.mode === 'registerPath' && api.registerPath) {
      api.registerPath(stagingRoot);
      registeredLegacyPath = stagingRoot;
      log(`[OK] registerPath: ${stagingRoot}`);
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[ERROR] plugins API: ${msg}`);
    if (showInfo) {
      vscode.window.showErrorMessage(`ERGO MS Module Rules: ошибка plugins API — ${msg}`);
    }
    return;
  }

  const rulesCount = modules.reduce((n, m) => n + m.files.length, 0);
  if (showInfo) {
    vscode.window.showInformationMessage(
      `ERGO MS Module Rules: ${modules.length} модулей, ${rulesCount} правил`,
    );
  }
}

function scheduleSync() {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
  debounceTimer = setTimeout(() => {
    debounceTimer = undefined;
    syncModuleRules(false).catch((err) => {
      log(`[ERROR] sync: ${err instanceof Error ? err.message : String(err)}`);
    });
  }, SYNC_DEBOUNCE_MS);
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
  output = vscode.window.createOutputChannel(OUTPUT_CHANNEL_NAME);
  log('[INFO] ERGO MS Module Rules активировано');

  context.subscriptions.push(
    vscode.commands.registerCommand('ergo-ms-module-rules.sync', () =>
      syncModuleRules(true),
    ),
  );

  const workspaceRoot = findWorkspaceRoot();
  if (workspaceRoot) {
    const pattern = new vscode.RelativePattern(
      workspaceRoot,
      'modules/*/.cursor/rules/**',
    );
    watcher = vscode.workspace.createFileSystemWatcher(pattern);
    watcher.onDidCreate(() => scheduleSync());
    watcher.onDidChange(() => scheduleSync());
    watcher.onDidDelete(() => scheduleSync());
    context.subscriptions.push(watcher);
  }

  syncModuleRules(false).catch((err) => {
    log(`[ERROR] initial sync: ${err instanceof Error ? err.message : String(err)}`);
  });
}

function deactivate() {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
    debounceTimer = undefined;
  }
  unregisterStaging().catch((err) => {
    log(`[WARNING] deactivate unregister: ${err instanceof Error ? err.message : String(err)}`);
  });
}

module.exports = {
  activate,
  deactivate,
};
