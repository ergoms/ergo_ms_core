const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const OUTPUT_NAME = 'ERGO MS Actions';
const CHECK_TIMEOUT_MS = 90000;
const SHELL_WAIT_MS = 3000;
const SUPPORTED_LANGUAGES = ['ru', 'en', 'fr'];
const FALLBACK_LANGUAGE = 'ru';

/** @type {Record<string, string>} */
let messages = {};

/** @type {vscode.OutputChannel | undefined} */
let output;
/** @type {Set<string>} */
const dismissed = new Set();
let checking = false;

function log(message) {
  if (!output) {
    output = vscode.window.createOutputChannel(OUTPUT_NAME);
  }
  output.appendLine(message);
}

function workspaceRoot() {
  const folders = vscode.workspace.workspaceFolders || [];
  for (const folder of folders) {
    const marker = path.join(folder.uri.fsPath, 'core', 'deployment', 'commands.conf');
    if (fs.existsSync(marker)) {
      return folder.uri.fsPath;
    }
  }
  return '';
}

function venvPython(root) {
  const relative = process.platform === 'win32'
    ? ['virtual_env', 'python', 'Scripts', 'python.exe']
    : ['virtual_env', 'python', 'bin', 'python'];
  const full = path.join(root, ...relative);
  return fs.existsSync(full) ? full : '';
}

function actionText(action) {
  const detail = typeof action.detail === 'string' ? action.detail : '';
  if (typeof action.title === 'string' && action.title.trim()) {
    return detail ? `${action.title.trim()} ${detail}` : action.title.trim();
  }
  switch (action.id) {
    case 'python-env':
      return t('Python environment is not installed.');
    case 'python-packages':
      return t('Python packages do not match the lock file.');
    case 'npm-packages':
      return t('npm packages do not match the manifests.');
    case 'migrations':
      return t('{0} migrations are not applied.', String(action.count || ''));
    case 'git-behind':
      return t('Commits are not pulled: {0}.', detail);
    default:
      return detail || String(action.id || '');
  }
}

function actionCommands(action) {
  if (Array.isArray(action.commands) && action.commands.length) {
    return action.commands.filter((item) => typeof item === 'string' && item.trim());
  }
  if (typeof action.command === 'string' && action.command.trim()) {
    return [action.command.trim()];
  }
  return [];
}

function signature(action) {
  return `${action.id}|${action.detail || ''}|${action.count || ''}|${actionCommands(action).join(';')}`;
}

function languageCode(tag) {
  const primary = String(tag || '').trim().toLowerCase().replace(/_/g, '-').split(/[-.]/)[0];
  return SUPPORTED_LANGUAGES.includes(primary) ? primary : '';
}

function readRegistryValue(key, name) {
  try {
    const result = spawnSync('reg', ['query', key, '/v', name], {
      encoding: 'utf8',
      windowsHide: true,
    });
    if (result.status !== 0 || !result.stdout) {
      return '';
    }
    const match = result.stdout.match(/REG_(?:SZ|MULTI_SZ)\s+(\S+)/);
    return match ? match[1].split('\\0')[0] : '';
  } catch {
    return '';
  }
}

function deviceLanguageTag() {
  if (process.platform === 'win32') {
    return readRegistryValue('HKCU\\Control Panel\\Desktop\\MuiCached', 'MachinePreferredUILanguages')
      || readRegistryValue('HKCU\\Control Panel\\International', 'LocaleName');
  }
  if (process.platform === 'darwin') {
    try {
      const result = spawnSync('defaults', ['read', '-g', 'AppleLanguages'], {
        encoding: 'utf8',
        windowsHide: true,
      });
      const match = String(result.stdout || '').match(/[A-Za-z]{2}(?:[-_][A-Za-z]{2})?/);
      return match ? match[0] : '';
    } catch {
      return '';
    }
  }
  return process.env.LC_ALL || process.env.LC_MESSAGES || process.env.LANG || '';
}

function resolveLanguage() {
  return languageCode(deviceLanguageTag()) || FALLBACK_LANGUAGE;
}

function loadMessages(language) {
  if (language === 'en') {
    messages = {};
    return;
  }
  const file = path.join(__dirname, 'l10n', `bundle.l10n.${language}.json`);
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    messages = parsed && typeof parsed === 'object' ? parsed : {};
  } catch (error) {
    log(String(error));
    messages = {};
  }
}

function t(message, ...args) {
  const template = typeof messages[message] === 'string' ? messages[message] : message;
  return template.replace(/\{(\d+)\}/g, (match, index) => {
    const value = args[Number(index)];
    return value == null ? match : String(value);
  });
}

function shellIntegrationEnabled() {
  return vscode.workspace.getConfiguration('terminal.integrated').get('shellIntegration.enabled') !== false;
}

function actionsTerminal(root) {
  return vscode.window.createTerminal({ name: OUTPUT_NAME, cwd: root });
}

function waitForShellIntegration(terminal) {
  if (terminal.shellIntegration) {
    return Promise.resolve(terminal.shellIntegration);
  }
  if (!shellIntegrationEnabled() || typeof vscode.window.onDidChangeTerminalShellIntegration !== 'function') {
    return Promise.resolve(undefined);
  }
  return new Promise((resolve) => {
    let disposable;
    const timer = setTimeout(() => {
      disposable.dispose();
      resolve(terminal.shellIntegration);
    }, SHELL_WAIT_MS);
    disposable = vscode.window.onDidChangeTerminalShellIntegration((event) => {
      if (event.terminal !== terminal) {
        return;
      }
      clearTimeout(timer);
      disposable.dispose();
      resolve(event.shellIntegration);
    });
  });
}

function trackExecution(terminal) {
  let execution;
  let earlyEnd;
  let settled = false;
  let endListener;
  let closeListener;
  let resolvePromise;
  const promise = new Promise((resolve) => {
    resolvePromise = resolve;
  });
  const finish = (result) => {
    if (settled) {
      return;
    }
    settled = true;
    endListener.dispose();
    closeListener.dispose();
    resolvePromise(result);
  };
  endListener = vscode.window.onDidEndTerminalShellExecution((event) => {
    if (event.terminal !== terminal) {
      return;
    }
    if (!execution) {
      earlyEnd = event;
      return;
    }
    if (event.execution === execution) {
      finish('finished');
    }
  });
  closeListener = vscode.window.onDidCloseTerminal((closed) => {
    if (closed === terminal) {
      finish('closed');
    }
  });
  return {
    promise,
    setExecution(value) {
      execution = value;
      if (earlyEnd && earlyEnd.execution === value) {
        finish('finished');
      }
    },
  };
}

function markerCommand(markerPath) {
  const shell = (vscode.env.shell || '').toLowerCase();
  if (shell.includes('powershell') || shell.includes('pwsh')) {
    return `Set-Content -LiteralPath '${markerPath.replace(/'/g, "''")}' -Value done`;
  }
  if (shell.includes('cmd.exe') || shell.endsWith('\\cmd.exe')) {
    return `echo done> "${markerPath.replace(/"/g, '""')}"`;
  }
  const posixPath = markerPath.replace(/\\/g, '/').replace(/'/g, `'\\''`);
  return `touch '${posixPath}'`;
}

function executeWithMarker(root, terminal, commands) {
  const cacheDir = path.join(root, 'virtual_env', 'cache');
  fs.mkdirSync(cacheDir, { recursive: true });
  const markerPath = path.join(cacheDir, `.ergo-ide-action-${process.pid}-${Date.now()}`);
  for (const command of commands) {
    terminal.sendText(command);
  }
  terminal.sendText(markerCommand(markerPath));
  log('shell integration is unavailable; waiting until the terminal command finishes');
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) {
        return;
      }
      settled = true;
      clearInterval(timer);
      closeListener.dispose();
      fs.rmSync(markerPath, { force: true });
      resolve(result);
    };
    const timer = setInterval(() => {
      if (fs.existsSync(markerPath)) {
        finish('finished');
      }
    }, 300);
    const closeListener = vscode.window.onDidCloseTerminal((closed) => {
      if (closed === terminal) {
        finish('closed');
      }
    });
  });
}

async function runCommands(root, commands) {
  const terminal = actionsTerminal(root);
  terminal.show();
  const integration = await waitForShellIntegration(terminal);
  if (
    integration
    && typeof integration.executeCommand === 'function'
    && typeof vscode.window.onDidEndTerminalShellExecution === 'function'
  ) {
    for (const command of commands) {
      const tracked = trackExecution(terminal);
      tracked.setExecution(integration.executeCommand(command));
      const result = await tracked.promise;
      if (result === 'closed') {
        return 'closed';
      }
    }
    return 'finished';
  }
  return executeWithMarker(root, terminal, commands);
}

async function offerRemaining(root, pending) {
  const remaining = pending.slice();
  while (remaining.length) {
    const picked = await vscode.window.showQuickPick(
      remaining.map((action) => ({
        label: actionText(action),
        description: actionCommands(action)[0],
        action,
      })),
      {
        title: t('Required actions'),
        canPickMany: false,
        ignoreFocusOut: true,
      },
    );
    if (!picked) {
      return;
    }
    const result = await runCommands(root, actionCommands(picked.action));
    if (result !== 'finished') {
      continue;
    }
    dismissed.add(signature(picked.action));
    const index = remaining.indexOf(picked.action);
    if (index >= 0) {
      remaining.splice(index, 1);
    }
  }
}

function loadActions(root, python) {
  const script = path.join(root, 'core', 'deployment', 'scripts', 'ide_actions.py');
  return new Promise((resolve) => {
    const child = spawn(python, [script], {
      cwd: root,
      windowsHide: true,
      env: {
        ...process.env,
        PYTHONIOENCODING: 'utf-8',
        PYTHONUTF8: '1',
        PYTHONUNBUFFERED: '1',
      },
    });
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    let stdout = '';
    let stderr = '';
    let settled = false;
    let timer;
    const finish = (actions) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(actions);
    };
    timer = setTimeout(() => {
      child.kill();
      log('check timed out');
      finish(null);
    }, CHECK_TIMEOUT_MS);
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', (error) => {
      log(String(error));
      finish(null);
    });
    child.on('close', () => {
      if (stderr.trim()) {
        log(stderr.trim());
      }
      try {
        const payload = JSON.parse(stdout.trim());
        finish(Array.isArray(payload.actions) ? payload.actions : null);
      } catch (error) {
        log(stdout.trim() || String(error));
        finish(null);
      }
    });
  });
}

async function present(root, actions) {
  const pending = actions.filter((action) => actionCommands(action).length && !dismissed.has(signature(action)));
  if (!pending.length) {
    return;
  }
  const later = t('Later');
  if (pending.length === 1) {
    const action = pending[0];
    const choice = await vscode.window.showWarningMessage(
      actionText(action),
      t('Run'),
      later,
    );
    if (choice === later || !choice) {
      dismissed.add(signature(action));
      return;
    }
    await runCommands(root, actionCommands(action));
    dismissed.add(signature(action));
    return;
  }
  const summary = pending.map((action) => actionText(action)).join(' ');
  const choice = await vscode.window.showWarningMessage(
    t('{0} actions need attention.', String(pending.length)) + ' ' + summary,
    t('Review'),
    later,
  );
  if (choice === later || !choice) {
    pending.forEach((action) => dismissed.add(signature(action)));
    return;
  }
  await offerRemaining(root, pending);
}

function loadWithProgress(root, python) {
  return vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: t('Checking required actions…') },
    () => loadActions(root, python),
  );
}

async function check(manual) {
  if (checking) {
    if (manual) {
      vscode.window.showInformationMessage(t('The check is already running.'));
    }
    return;
  }
  const root = workspaceRoot();
  if (!root) {
    if (manual) {
      vscode.window.showWarningMessage(t('Open the ERGO MS project folder to check required actions.'));
    }
    return;
  }
  checking = true;
  try {
    const python = venvPython(root);
    if (!python) {
      await present(root, [{ id: 'python-env', commands: ['ergoms install-python'] }]);
      return;
    }
    const actions = manual ? await loadWithProgress(root, python) : await loadActions(root, python);
    if (actions === null) {
      if (manual) {
        const details = t('Details');
        const choice = await vscode.window.showWarningMessage(t('Could not check required actions.'), details);
        if (choice === details && output) {
          output.show(true);
        }
      }
      return;
    }
    const pending = actions.filter((action) => actionCommands(action).length);
    if (!pending.length) {
      if (manual) {
        vscode.window.showInformationMessage(t('No actions needed.'));
      }
      return;
    }
    await present(root, pending);
  } finally {
    checking = false;
  }
}

function activate(context) {
  loadMessages(resolveLanguage());
  context.subscriptions.push(
    vscode.commands.registerCommand('ergo-ms-actions.check', () => {
      dismissed.clear();
      return check(true);
    }),
  );
  return check(false);
}

function deactivate() {}

module.exports = { activate, deactivate };
