const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const osAbstraction = require('./lib/os-abstraction.cjs');
const {
    MODULE_TASKS_FILENAME,
    ERGO_MODULE_TASK_TYPE,
    ERGO_MODULE_TASK_SOURCE,
    parseYaml,
    discoverModuleTaskDefs: discoverModuleTaskDefsFromFs
} = require('./lib/module-tasks.cjs');

// Хранилище запущенных задач по группам
const taskGroups = new Map();

/** @type {vscode.OutputChannel|null} */
let moduleTasksLog = null;

/** @type {Array<object>|null} */
let moduleTasksCache = null;

/**
 * Получает значение по пути в объекте
 */
function getValueByPath(obj, pathStr) {
    if (!pathStr) return obj;
    const parts = pathStr.split('.');
    let current = obj;
    for (const part of parts) {
        if (current === undefined || current === null) return undefined;
        current = current[part];
    }
    return current;
}

/**
 * Читает KEY=VALUE из корневого .env и env/*.env (nginx.env, docker.env).
 */
function readMergedEnv(workspaceRoot) {
    const merged = {};
    const files = [path.join(workspaceRoot, '.env')];
    const envDir = path.join(workspaceRoot, 'env');
    if (fs.existsSync(envDir)) {
        const priority = ['nginx.env', 'docker.env'];
        const names = fs.readdirSync(envDir).filter(
            (name) => name.endsWith('.env') && !name.endsWith('.example'),
        );
        for (const name of priority) {
            if (names.includes(name)) {
                files.push(path.join(envDir, name));
            }
        }
        for (const name of names.sort()) {
            if (!priority.includes(name)) {
                files.push(path.join(envDir, name));
            }
        }
    }
    for (const envPath of files) {
        if (!fs.existsSync(envPath)) {
            continue;
        }
        const lines = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
        for (const raw of lines) {
            const line = raw.trim();
            if (!line || line.startsWith('#') || !line.includes('=')) {
                continue;
            }
            const eq = line.indexOf('=');
            const key = line.substring(0, eq).trim();
            const value = line.substring(eq + 1).trim().replace(/^["']|["']$/g, '');
            merged[key] = value;
        }
    }
    return merged;
}

function envTruthy(value) {
    const normalized = String(value || '').trim().toLowerCase();
    return normalized === '1' || normalized === 'true' || normalized === 'yes';
}

/**
 * Effective nginx/redis: явный NGINX_ENABLED/REDIS_ENABLED или ERGO_PROXY/ERGO_BROKER.
 */
function readEnvFlag(workspaceRoot, name) {
    const env = readMergedEnv(workspaceRoot);
    if (name === 'NGINX_ENABLED') {
        if (env.NGINX_ENABLED !== undefined && String(env.NGINX_ENABLED).trim() !== '') {
            return envTruthy(env.NGINX_ENABLED);
        }
        return String(env.ERGO_PROXY || 'none').trim().toLowerCase() === 'nginx';
    }
    if (name === 'REDIS_ENABLED') {
        if (env.REDIS_ENABLED !== undefined && String(env.REDIS_ENABLED).trim() !== '') {
            return envTruthy(env.REDIS_ENABLED);
        }
        return String(env.ERGO_BROKER || 'local').trim().toLowerCase() === 'redis';
    }
    return envTruthy(env[name]);
}

/**
 * Обновляет runtime YAML (nginx/client/redis) перед чтением источников.
 */
function ensureLogsServicesRuntime(workspaceRoot) {
    const { spawnSync } = require('child_process');
    const isWin = process.platform === 'win32';
    const python = isWin
        ? path.join(workspaceRoot, 'virtual_env', 'python', 'Scripts', 'python.exe')
        : path.join(workspaceRoot, 'virtual_env', 'python', 'bin', 'python');
    const script = path.join(
        workspaceRoot,
        'core',
        'deployment',
        'scripts',
        'sync_vscode_logs_services.py'
    );
    if (!fs.existsSync(python) || !fs.existsSync(script)) {
        return;
    }
    try {
        spawnSync(python, [script], {
            cwd: workspaceRoot,
            encoding: 'utf8',
            windowsHide: true
        });
    } catch (_) {
        // runtime YAML мог остаться от прошлого sync — дальше сработает фильтр по .env
    }
}

/**
 * Исключает службы, несовместимые с NGINX_ENABLED / REDIS_ENABLED.
 * Runtime YAML уже собран sync_vscode_logs_services.py — не фильтруем повторно
 * (иначе JS и Python могут разойтись и выкинуть redis/nginx).
 */
function filterServiceKeys(workspaceRoot, items, sourceFile) {
    const file = String(sourceFile || '').replace(/\\/g, '/');
    if (
        file.includes('logs-all.runtime.yaml')
        || file.includes('logs-services.runtime.yaml')
        || file.includes('optional-services.runtime.yaml')
        || file.includes('redis-dev.runtime.yaml')
        || file.includes('client-dev.runtime.yaml')
        || file.includes('module-start-services.runtime.yaml')
        || file.includes('module-logs-services.runtime.yaml')
    ) {
        return items;
    }

    const nginx = readEnvFlag(workspaceRoot, 'NGINX_ENABLED');
    const redis = readEnvFlag(workspaceRoot, 'REDIS_ENABLED');

    return items.filter((key) => {
        if (file.includes('logs-services')) {
            if (key === 'ergo_ms_client_dev' && nginx) {
                return false;
            }
            if (key === 'ergo_ms_nginx' && !nginx) {
                return false;
            }
            if (key === 'ergo_ms_redis' && !redis) {
                return false;
            }
            return true;
        }
        if (file.includes('optional-services')) {
            if (key === 'client' && nginx) {
                return false;
            }
            if (key === 'nginx' && !nginx) {
                return false;
            }
            if (key === 'redis' && !redis) {
                return false;
            }
            return true;
        }
        return true;
    });
}

/**
 * Читает источник: ключи + опциональные command / stop_command из map.
 * @returns {{ key: string, command: string, stopCommand: string }[]}
 */
function readSourceEntries(workspaceRoot, sourceConfig, silent = false) {
    const relFile = String(sourceConfig.file || '').replace(/\\/g, '/');
    if (
        relFile.includes('logs-all.runtime.yaml')
        || relFile.includes('logs-services.runtime.yaml')
        || relFile.includes('optional-services.runtime.yaml')
        || relFile.includes('redis-dev.runtime.yaml')
        || relFile.includes('client-dev.runtime.yaml')
        || relFile.includes('module-start-services.runtime.yaml')
        || relFile.includes('module-logs-services.runtime.yaml')
    ) {
        ensureLogsServicesRuntime(workspaceRoot);
    }

    const filePath = path.join(workspaceRoot, sourceConfig.file);

    if (!fs.existsSync(filePath)) {
        if (!silent) {
            vscode.window.showErrorMessage(`Файл не найден: ${sourceConfig.file}`);
        }
        return [];
    }

    const content = fs.readFileSync(filePath, 'utf8');
    const ext = path.extname(filePath).toLowerCase();

    let data;
    if (ext === '.json') {
        data = JSON.parse(content);
    } else if (ext === '.yaml' || ext === '.yml') {
        data = parseYaml(content);
    } else {
        vscode.window.showErrorMessage(`Неподдерживаемый формат: ${ext}`);
        return [];
    }

    const items = getValueByPath(data, sourceConfig.path);

    if (!items) {
        // Пустой services: в runtime.yaml (Redis выключен) — не ошибка.
        if (!silent) {
            vscode.window.showWarningMessage(`Путь "${sourceConfig.path}" не найден в ${sourceConfig.file}`);
        }
        return [];
    }

    let entries;
    if (typeof items === 'object' && !Array.isArray(items)) {
        entries = Object.keys(items).map((key) => {
            const meta = items[key];
            const isMap = meta && typeof meta === 'object' && !Array.isArray(meta);
            const command = isMap ? String(meta.command || '').trim() : '';
            const stopCommand = isMap ? String(meta.stop_command || '').trim() : '';
            const description = isMap ? String(meta.description || '').trim() : '';
            return { key, command, stopCommand, description };
        });
    } else {
        entries = (Array.isArray(items) ? items : []).map((key) => ({
            key: String(key),
            command: '',
            stopCommand: '',
            description: ''
        }));
    }

    const allowedKeys = new Set(
        filterServiceKeys(
            workspaceRoot,
            entries.map((e) => e.key),
            sourceConfig.file
        )
    );
    return entries.filter((e) => allowedKeys.has(e.key));
}

/**
 * Читает список ключей из YAML/JSON файла (обратная совместимость).
 */
function readSourceFile(workspaceRoot, sourceConfig, silent = false) {
    return readSourceEntries(workspaceRoot, sourceConfig, silent).map((e) => e.key);
}

/**
 * Заменяет переменные в шаблоне
 */
function applyTemplate(template, variables) {
    let result = template;
    for (const [key, value] of Object.entries(variables)) {
        result = result.replace(new RegExp(`\\$\\{${key}\\}`, 'g'), value);
    }
    return result;
}

/**
 * Задержка
 */
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Получает корневую папку
 */
function getWorkspaceRoot() {
    const folders = vscode.workspace.workspaceFolders;
    return folders && folders.length > 0 ? folders[0].uri.fsPath : null;
}


/**
 * Создаёт и запускает задачу
 */
async function runTask(name, command, cwd, group, stopCommand) {
    const taskDefinition = {
        type: 'shell',
        task: name
    };

    const workspaceRoot = cwd || getWorkspaceRoot();
    const env = { ...process.env };
    if (workspaceRoot) {
        const bin = path.join(workspaceRoot, 'core', 'deployment', 'bin');
        const sep = process.platform === 'win32' ? ';' : ':';
        env.PATH = `${bin}${sep}${env.PATH || ''}`;
    }
    
    const { executable, args, options } = osAbstraction.getProcessExecution(command, cwd, env);
    const processExecution = new vscode.ProcessExecution(executable, args, options);

    const task = new vscode.Task(
        taskDefinition,
        vscode.TaskScope.Workspace,
        name,
        'multi-terminal',
        processExecution,
        []
    );

    task.presentationOptions = {
        reveal: vscode.TaskRevealKind.Always,
        panel: vscode.TaskPanelKind.New,
        focus: false,
        echo: true,
        showReuseMessage: false,
        clear: false
    };

    const execution = await vscode.tasks.executeTask(task);
    
    // Сохраняем в группу
    if (group) {
        if (!taskGroups.has(group)) {
            taskGroups.set(group, []);
        }
        taskGroups.get(group).push({
            execution,
            stopCommand: stopCommand || null,
            cwd,
            name
        });
    }
    
    return execution;
}

/**
 * Маппинг ergoms stop-*-dev → прямой вызов Python (без powershell-обёртки ergoms).
 * На Windows `ergoms stop-redis-dev` часто занимает 10+ с и упирается в timeout.
 */
const STOP_DEV_SCRIPTS = {
    'stop-redis-dev': path.join('core', 'deployment', 'scripts', 'stop_redis_if_enabled.py'),
    'stop-nginx-dev': path.join('core', 'deployment', 'scripts', 'stop_nginx_if_enabled.py'),
    'stop-client-dev': path.join('core', 'deployment', 'scripts', 'stop_client_if_enabled.py')
};

function resolvePythonExecutable(workspaceRoot) {
    if (!workspaceRoot) {
        return null;
    }
    if (process.platform === 'win32') {
        const winPy = path.join(workspaceRoot, 'virtual_env', 'python', 'Scripts', 'python.exe');
        if (fs.existsSync(winPy)) {
            return winPy;
        }
    } else {
        const unixPy = path.join(workspaceRoot, 'virtual_env', 'python', 'bin', 'python');
        if (fs.existsSync(unixPy)) {
            return unixPy;
        }
    }
    return null;
}

/**
 * Преобразует stop-команду в быстрый spawn (python script) или shell fallback.
 */
function resolveStopInvocation(stopCommand, workspaceRoot) {
    const trimmed = String(stopCommand || '').trim();
    const match = trimmed.match(/^ergoms\s+(stop-[a-z0-9-]+-dev)\s*$/i);
    if (match && workspaceRoot) {
        const scriptRel = STOP_DEV_SCRIPTS[match[1].toLowerCase()];
        const pythonExe = resolvePythonExecutable(workspaceRoot);
        if (scriptRel && pythonExe) {
            return {
                executable: pythonExe,
                args: [path.join(workspaceRoot, scriptRel)],
                envExtra: {
                    PYTHONIOENCODING: 'utf-8',
                    PYTHONUTF8: '1'
                }
            };
        }
    }
    const isWin = process.platform === 'win32';
    return {
        executable: isWin ? 'cmd.exe' : '/bin/bash',
        args: isWin ? ['/d', '/c', trimmed] : ['-lc', trimmed],
        envExtra: {}
    };
}

/**
 * Выполняет stop-команду после закрытия терминала (синхронно — иначе на Windows
 * detached-процесс может не успеть отработать).
 */
function runStopCommand(stopCommand, cwd) {
    if (!stopCommand) {
        return;
    }
    const { spawnSync } = require('child_process');
    const workspaceRoot = cwd || getWorkspaceRoot();
    const invocation = resolveStopInvocation(stopCommand, workspaceRoot);
    const env = { ...process.env, ...invocation.envExtra };
    if (workspaceRoot) {
        const bin = path.join(workspaceRoot, 'core', 'deployment', 'bin');
        const sep = process.platform === 'win32' ? ';' : ':';
        env.PATH = `${bin}${sep}${env.PATH || ''}`;
        env.PYTHONIOENCODING = env.PYTHONIOENCODING || 'utf-8';
        env.PYTHONUTF8 = env.PYTHONUTF8 || '1';
    }
    try {
        spawnSync(invocation.executable, invocation.args, {
            cwd: workspaceRoot || undefined,
            stdio: 'ignore',
            windowsHide: true,
            env,
            timeout: 45000
        });
    } catch (_) {
        // stop best-effort: Redis/nginx могли уже остановиться в atexit
    }
}

/**
 * Находит запись задачи по TaskExecution (ссылка или имя — на Windows ссылка часто другая).
 */
function findTrackedTask(execution) {
    const taskName = execution && execution.task ? execution.task.name : null;
    for (const [group, items] of taskGroups) {
        const index = items.findIndex((item) => (
            item.execution === execution
            || (taskName && item.name === taskName)
        ));
        if (index > -1) {
            return { group, index, item: items[index] };
        }
    }
    return null;
}

/**
 * Находит запись по имени терминала VS Code (Task - redis / redis).
 */
function findTrackedTaskByTerminalName(terminalName) {
    if (!terminalName) {
        return null;
    }
    const normalized = String(terminalName).replace(/^Task\s*-\s*/i, '').trim();
    for (const [group, items] of taskGroups) {
        const index = items.findIndex((item) => (
            item.name === terminalName
            || item.name === normalized
            || terminalName === `Task - ${item.name}`
        ));
        if (index > -1) {
            return { group, index, item: items[index] };
        }
    }
    return null;
}

function releaseTrackedTask(found) {
    if (!found) {
        return;
    }
    const { group, index, item } = found;
    const items = taskGroups.get(group);
    if (!items) {
        return;
    }
    items.splice(index, 1);
    if (items.length === 0) {
        taskGroups.delete(group);
    }
    runStopCommand(item.stopCommand, item.cwd);
}

/**
 * Обрабатывает один источник данных и возвращает список задач
 */
function processSource(workspaceRoot, sourceConfig, defaultCwd, silent = false, defaultStopTemplate = null) {
    const entries = readSourceEntries(workspaceRoot, sourceConfig, silent);
    const commandTemplate = sourceConfig.commandTemplate || 'echo ${key}';
    const nameTemplate = sourceConfig.nameTemplate || 'Task: ${key}';
    const stopTemplate = sourceConfig.stopCommandTemplate || defaultStopTemplate;

    return entries.map((entry) => {
        const item = entry.key;
        const stopFromTemplate = stopTemplate
            ? applyTemplate(stopTemplate, { key: item, item: item })
            : null;
        const stopCommand = entry.stopCommand || stopFromTemplate || null;
        const command = entry.command
            || applyTemplate(commandTemplate, { key: item, item: item });
        const templatedName = applyTemplate(nameTemplate, { key: item, item: item });
        const sourceFile = String(sourceConfig.file || '').replace(/\\/g, '/');
        const useDescriptionName = (
            entry.description
            && (
                sourceFile.includes('logs-all.runtime.yaml')
                || sourceFile.includes('module-start-services.runtime.yaml')
                || sourceFile.includes('module-logs-services.runtime.yaml')
            )
        );
        return {
            name: useDescriptionName ? entry.description : templatedName,
            command,
            cwd: sourceConfig.cwd ? path.join(workspaceRoot, sourceConfig.cwd) : defaultCwd,
            stopCommand
        };
    });
}

/**
 * Выполняет multi-terminal задачу
 */
async function executeMultiTerminalTask(task) {
    const workspaceRoot = getWorkspaceRoot();
    if (!workspaceRoot) {
        vscode.window.showErrorMessage('Откройте папку проекта');
        return;
    }
    
    const definition = task.definition;
    const delay = definition.delay || 300;
    const group = definition.group || task.name;
    const cwd = definition.cwd ? path.join(workspaceRoot, definition.cwd) : workspaceRoot;
    const silentEmpty = Boolean(definition.hideControlTerminal);
    const stopCommandTemplate = definition.stopCommandTemplate || null;
    
    let tasks = [];
    
    // Вариант 1: Статический список
    if (definition.terminals && Array.isArray(definition.terminals)) {
        tasks = definition.terminals.map(t => ({
            name: t.name,
            command: t.command,
            cwd: t.cwd ? path.join(workspaceRoot, t.cwd) : cwd,
            stopCommand: t.stopCommand || null
        }));
    }
    
    // Вариант 2: Один источник из файла (обратная совместимость)
    if (definition.source && definition.source.file) {
        const sourceWithTemplates = {
            ...definition.source,
            commandTemplate: definition.commandTemplate || 'echo ${key}',
            nameTemplate: definition.nameTemplate || 'Task: ${key}',
            stopCommandTemplate: definition.source.stopCommandTemplate || stopCommandTemplate
        };
        tasks = tasks.concat(processSource(workspaceRoot, sourceWithTemplates, cwd, silentEmpty, stopCommandTemplate));
    }
    
    // Вариант 3: Несколько источников (НОВОЕ!)
    if (definition.sources && Array.isArray(definition.sources)) {
        for (const sourceConfig of definition.sources) {
            const sourceTasks = processSource(workspaceRoot, sourceConfig, cwd, silentEmpty, stopCommandTemplate);
            tasks = tasks.concat(sourceTasks);
        }
    }
    
    if (tasks.length === 0) {
        // Пустой список нормален для Redis Dev при REDIS_ENABLED=false —
        // не пугаем toast'ом «Нет задач для запуска» в Start All Services.
        if (!silentEmpty) {
            vscode.window.showWarningMessage('Нет задач для запуска');
        }
        return;
    }

    if (String(group || '').startsWith('logs')) {
        vscode.window.showInformationMessage(
            `ERGO MS Logs: открываю ${tasks.length} терминал(ов)…`
        );
    }
    
    // Останавливаем старые задачи этой группы
    if (taskGroups.has(group)) {
        for (const item of taskGroups.get(group)) {
            try {
                item.execution.terminate();
            } catch (e) {}
            runStopCommand(item.stopCommand, item.cwd || cwd);
        }
        taskGroups.set(group, []);
    }
    
    // Запускаем задачи
    for (const t of tasks) {
        await runTask(t.name, t.command, t.cwd, group, t.stopCommand);
        await sleep(delay);
    }
}

/**
 * Останавливает все задачи группы
 */
function stopAllTasks() {
    let count = 0;
    
    for (const [group, executions] of taskGroups) {
        for (const item of executions) {
            try {
                item.execution.terminate();
                count++;
            } catch (e) {}
            runStopCommand(item.stopCommand, item.cwd);
        }
    }
    
    taskGroups.clear();
    
    if (count > 0) {
        vscode.window.showInformationMessage(`Остановлено ${count} задач(и)`);
    } else {
        vscode.window.showInformationMessage('Нет запущенных задач');
    }
}

function getModuleTasksLog() {
    if (!moduleTasksLog) {
        moduleTasksLog = vscode.window.createOutputChannel('ERGO MS Module Tasks');
    }
    return moduleTasksLog;
}

function logModuleTasksWarn(message) {
    const text = `[WARNING] ${message}`;
    console.warn(`ERGO MS Module Tasks: ${message}`);
    getModuleTasksLog().appendLine(text);
}

function invalidateModuleTasksCache() {
    moduleTasksCache = null;
}

/**
 * PATH с core/deployment/bin — как в .vscode/tasks.json.
 */
function buildErgomsEnv(workspaceRoot) {
    const bin = path.join(workspaceRoot, 'core', 'deployment', 'bin');
    const sep = process.platform === 'win32' ? ';' : ':';
    return {
        ...process.env,
        PATH: `${bin}${sep}${process.env.PATH || ''}`,
        PYTHONIOENCODING: process.env.PYTHONIOENCODING || 'utf-8',
        PYTHONUTF8: process.env.PYTHONUTF8 || '1'
    };
}

/**
 * Читает modules/<name>/vscode.tasks.yaml (с кэшем).
 */
function discoverModuleTaskDefs(workspaceRoot) {
    if (moduleTasksCache) {
        return moduleTasksCache;
    }
    const env = readMergedEnv(workspaceRoot);
    moduleTasksCache = discoverModuleTaskDefsFromFs(
        workspaceRoot,
        (key) => env[key],
        logModuleTasksWarn
    );
    return moduleTasksCache;
}

/**
 * Собирает vscode.Task из декларации ergo-module.
 */
function buildErgoModuleTask(definition, workspaceRoot) {
    const env = buildErgomsEnv(workspaceRoot);
    const { executable, args, options } = osAbstraction.getProcessExecution(
        definition.command,
        workspaceRoot,
        env
    );
    const processExecution = new vscode.ProcessExecution(executable, args, options);
    const task = new vscode.Task(
        {
            type: ERGO_MODULE_TASK_TYPE,
            label: definition.label,
            detail: definition.detail,
            command: definition.command,
            module: definition.module || '',
            panel: definition.panel || 'shared'
        },
        vscode.TaskScope.Workspace,
        definition.label,
        ERGO_MODULE_TASK_SOURCE,
        processExecution,
        []
    );
    task.detail = definition.detail;
    task.presentationOptions = {
        reveal: vscode.TaskRevealKind.Always,
        panel: definition.panel === 'new'
            ? vscode.TaskPanelKind.New
            : vscode.TaskPanelKind.Shared,
        focus: false,
        echo: true,
        showReuseMessage: false,
        clear: false
    };
    return task;
}

/**
 * Провайдер модульных задач из modules/<name>/vscode.tasks.yaml
 */
class ErgoModuleTaskProvider {
    provideTasks() {
        const workspaceRoot = getWorkspaceRoot();
        if (!workspaceRoot) {
            return [];
        }
        return discoverModuleTaskDefs(workspaceRoot).map((def) =>
            buildErgoModuleTask(def, workspaceRoot)
        );
    }

    resolveTask(task) {
        const definition = task.definition;
        if (definition.type !== ERGO_MODULE_TASK_TYPE) {
            return undefined;
        }
        const workspaceRoot = getWorkspaceRoot();
        if (!workspaceRoot) {
            return undefined;
        }
        if (!definition.command || !definition.label || !definition.detail) {
            return undefined;
        }
        if (!/^ergoms(\s|$)/.test(String(definition.command).trim())) {
            return undefined;
        }
        return buildErgoModuleTask(
            {
                label: definition.label,
                detail: definition.detail,
                command: definition.command,
                module: definition.module || '',
                panel: definition.panel || 'shared'
            },
            workspaceRoot
        );
    }
}

/**
 * Провайдер задач multi-terminal
 */
class MultiTerminalTaskProvider {
    constructor() {
        this.type = 'multi-terminal';
    }
    
    provideTasks() {
        return [];
    }
    
    resolveTask(task) {
        const definition = task.definition;
        
        if (definition.type === 'multi-terminal') {
            const newTask = new vscode.Task(
                definition,
                task.scope || vscode.TaskScope.Workspace,
                task.name,
                'multi-terminal',
                new vscode.CustomExecution(async () => {
                    return new MultiTerminalTaskTerminal(task);
                })
            );
            
            // Если hideControlTerminal: true - скрываем управляющий терминал
            if (definition.hideControlTerminal) {
                newTask.presentationOptions = {
                    reveal: vscode.TaskRevealKind.Silent,
                    panel: vscode.TaskPanelKind.Dedicated,
                    focus: false,
                    echo: false,
                    showReuseMessage: false,
                    clear: true,
                    close: true
                };
            }
            
            return newTask;
        }
        
        return undefined;
    }
}

/**
 * Псевдо-терминал для запуска задач
 */
class MultiTerminalTaskTerminal {
    constructor(task) {
        this.task = task;
        this.writeEmitter = new vscode.EventEmitter();
        this.closeEmitter = new vscode.EventEmitter();
        this.onDidWrite = this.writeEmitter.event;
        this.onDidClose = this.closeEmitter.event;
    }
    
    open() {
        this.execute();
    }
    
    close() {}
    
    async execute() {
        const hideControl = this.task.definition.hideControlTerminal;
        
        if (!hideControl) {
        this.writeEmitter.fire('ERGO MS Tasks: Запуск multi-terminal...\r\n\r\n');
        }
        
        try {
            await executeMultiTerminalTask(this.task);
            if (!hideControl) {
            this.writeEmitter.fire('\r\n OK Все задачи запущены!\r\n');
            }
        } catch (error) {
            this.writeEmitter.fire(`\r\n ERROR Ошибка: ${error.message}\r\n`);
        }
        
        // Закрываем управляющий терминал
        // Если hideControlTerminal - закрываем сразу, иначе через секунду
        const closeDelay = hideControl ? 100 : 1000;
        setTimeout(() => {
            this.closeEmitter.fire(0);
        }, closeDelay);
    }
}

/**
 * Активация расширения
 */
function activate(context) {
    console.log('ERGO MS Tasks extension is now active');

    const taskProvider = vscode.tasks.registerTaskProvider(
        'multi-terminal',
        new MultiTerminalTaskProvider()
    );
    const moduleTaskProvider = vscode.tasks.registerTaskProvider(
        ERGO_MODULE_TASK_TYPE,
        new ErgoModuleTaskProvider()
    );

    const stopAllCmd = vscode.commands.registerCommand(
        'ergo-ms-tasks.stopAll',
        stopAllTasks
    );

    const onTaskProcessEnd = (execution) => {
        releaseTrackedTask(findTrackedTask(execution));
    };

    const taskEndListener = vscode.tasks.onDidEndTaskProcess((e) => {
        onTaskProcessEnd(e.execution);
    });
    const taskEndListener2 = vscode.tasks.onDidEndTask((e) => {
        onTaskProcessEnd(e.execution);
    });
    const terminalCloseListener = vscode.window.onDidCloseTerminal((terminal) => {
        releaseTrackedTask(findTrackedTaskByTerminalName(terminal && terminal.name));
    });

    const watchers = [
        vscode.workspace.createFileSystemWatcher(`**/modules/*/${MODULE_TASKS_FILENAME}`),
        vscode.workspace.createFileSystemWatcher('**/.env'),
        vscode.workspace.createFileSystemWatcher('**/env/*.env')
    ];
    for (const watcher of watchers) {
        watcher.onDidCreate(invalidateModuleTasksCache);
        watcher.onDidChange(invalidateModuleTasksCache);
        watcher.onDidDelete(invalidateModuleTasksCache);
    }

    context.subscriptions.push(
        taskProvider,
        moduleTaskProvider,
        stopAllCmd,
        taskEndListener,
        taskEndListener2,
        terminalCloseListener,
        getModuleTasksLog(),
        ...watchers
    );
}

function deactivate() {
    // Закрытие окна / reload extension host: погасить portable Redis/nginx.
    for (const [, items] of taskGroups) {
        for (const item of items) {
            runStopCommand(item.stopCommand, item.cwd);
        }
    }
    taskGroups.clear();
    invalidateModuleTasksCache();
    moduleTasksLog = null;
}

module.exports = { activate, deactivate };
