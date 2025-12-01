const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

// Хранилище запущенных задач по группам
const taskGroups = new Map();

/**
 * Простой парсер YAML (без зависимостей)
 */
function parseYaml(content) {
    const lines = content.split('\n');
    const result = {};
    const stack = [{ obj: result, indent: -1 }];
    
    for (let line of lines) {
        if (line.trim().startsWith('#') || line.trim() === '') continue;
        
        const indent = line.search(/\S/);
        if (indent === -1) continue;
        
        line = line.trimEnd();
        
        while (stack.length > 1 && stack[stack.length - 1].indent >= indent) {
            stack.pop();
        }
        
        const current = stack[stack.length - 1].obj;
        const trimmed = line.trim();
        
        if (trimmed.startsWith('- ')) {
            const value = trimmed.substring(2).trim();
            if (!Array.isArray(current)) {
                const parentInfo = stack[stack.length - 2];
                if (parentInfo) {
                    const keys = Object.keys(parentInfo.obj);
                    const lastKey = keys[keys.length - 1];
                    parentInfo.obj[lastKey] = [];
                    stack[stack.length - 1].obj = parentInfo.obj[lastKey];
                }
            }
            const arr = stack[stack.length - 1].obj;
            if (Array.isArray(arr)) {
                arr.push(value.replace(/^["']|["']$/g, ''));
            }
            continue;
        }
        
        const colonIndex = trimmed.indexOf(':');
        if (colonIndex > 0) {
            const key = trimmed.substring(0, colonIndex).trim();
            let value = trimmed.substring(colonIndex + 1).trim();
            value = value.replace(/^["']|["']$/g, '');
            
            if (value === '' || value === '|' || value === '>') {
                current[key] = {};
                stack.push({ obj: current[key], indent: indent });
            } else {
                current[key] = value;
            }
        }
    }
    
    return result;
}

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
 * Читает список из YAML/JSON файла
 */
function readSourceFile(workspaceRoot, sourceConfig) {
    const filePath = path.join(workspaceRoot, sourceConfig.file);
    
    if (!fs.existsSync(filePath)) {
        vscode.window.showErrorMessage(`Файл не найден: ${sourceConfig.file}`);
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
        vscode.window.showWarningMessage(`Путь "${sourceConfig.path}" не найден в ${sourceConfig.file}`);
        return [];
    }
    
    if (typeof items === 'object' && !Array.isArray(items)) {
        return Object.keys(items);
    }
    
    return Array.isArray(items) ? items : [];
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
 * Определяет платформу
 */
function isWindows() {
    return process.platform === 'win32';
}

/**
 * Создаёт и запускает задачу
 */
async function runTask(name, command, cwd, group) {
    const taskDefinition = {
        type: 'shell',
        task: name
    };
    
    let execution;
    
    if (isWindows()) {
        // Windows: ProcessExecution с cmd.exe для bat-файлов (ergoms)
        // PowerShell для прямых вызовов .ps1 скриптов
        const usePowerShell = (command.includes('.ps1') && command.includes('powershell')) || 
                              (command.startsWith('powershell') && command.includes('.ps1'));
        
        if (usePowerShell) {
            // Для PowerShell скриптов
            const processExecution = new vscode.ProcessExecution('powershell.exe', [
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-Command', command
            ], {
                cwd: cwd
            });
            
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
            
            execution = await vscode.tasks.executeTask(task);
        } else {
            // Для обычных команд (ergoms и т.д.) используем cmd.exe
            const processExecution = new vscode.ProcessExecution('cmd.exe', ['/d', '/c', command], {
                cwd: cwd
            });
            
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
            
            execution = await vscode.tasks.executeTask(task);
        }
    } else {
        // Linux/macOS: ProcessExecution с bash
        const processExecution = new vscode.ProcessExecution('/bin/bash', ['-l', '-c', command], {
            cwd: cwd
        });
        
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
        
        execution = await vscode.tasks.executeTask(task);
    }
    
    // Сохраняем в группу
    if (group) {
        if (!taskGroups.has(group)) {
            taskGroups.set(group, []);
        }
        taskGroups.get(group).push(execution);
    }
    
    return execution;
}

/**
 * Обрабатывает один источник данных и возвращает список задач
 */
function processSource(workspaceRoot, sourceConfig, defaultCwd) {
    const items = readSourceFile(workspaceRoot, sourceConfig);
    const commandTemplate = sourceConfig.commandTemplate || 'echo ${key}';
    const nameTemplate = sourceConfig.nameTemplate || 'Task: ${key}';
    
    return items.map(item => ({
        name: applyTemplate(nameTemplate, { key: item, item: item }),
        command: applyTemplate(commandTemplate, { key: item, item: item }),
        cwd: sourceConfig.cwd ? path.join(workspaceRoot, sourceConfig.cwd) : defaultCwd
    }));
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
    
    let tasks = [];
    
    // Вариант 1: Статический список
    if (definition.terminals && Array.isArray(definition.terminals)) {
        tasks = definition.terminals.map(t => ({
            name: t.name,
            command: t.command,
            cwd: t.cwd ? path.join(workspaceRoot, t.cwd) : cwd
        }));
    }
    
    // Вариант 2: Один источник из файла (обратная совместимость)
    if (definition.source && definition.source.file) {
        const sourceWithTemplates = {
            ...definition.source,
            commandTemplate: definition.commandTemplate || 'echo ${key}',
            nameTemplate: definition.nameTemplate || 'Task: ${key}'
        };
        tasks = tasks.concat(processSource(workspaceRoot, sourceWithTemplates, cwd));
    }
    
    // Вариант 3: Несколько источников (НОВОЕ!)
    if (definition.sources && Array.isArray(definition.sources)) {
        for (const sourceConfig of definition.sources) {
            const sourceTasks = processSource(workspaceRoot, sourceConfig, cwd);
            tasks = tasks.concat(sourceTasks);
        }
    }
    
    if (tasks.length === 0) {
        vscode.window.showWarningMessage('Нет задач для запуска');
        return;
    }
    
    // Останавливаем старые задачи этой группы
    if (taskGroups.has(group)) {
        for (const exec of taskGroups.get(group)) {
            try {
                exec.terminate();
            } catch (e) {}
        }
        taskGroups.set(group, []);
    }
    
    // Запускаем задачи
    for (const t of tasks) {
        await runTask(t.name, t.command, t.cwd, group);
        await sleep(delay);
    }
}

/**
 * Останавливает все задачи группы
 */
function stopAllTasks() {
    let count = 0;
    
    for (const [group, executions] of taskGroups) {
        for (const exec of executions) {
            try {
                exec.terminate();
                count++;
            } catch (e) {}
        }
    }
    
    taskGroups.clear();
    
    if (count > 0) {
        vscode.window.showInformationMessage(`Остановлено ${count} задач(и)`);
    } else {
        vscode.window.showInformationMessage('Нет запущенных задач');
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
        this.writeEmitter.fire('ERGO MS Multi-Terminal: Запуск задач...\r\n\r\n');
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
    console.log('ERGO MS Multi-Terminal extension is now active');
    
    // Регистрируем провайдер задач
    const taskProvider = vscode.tasks.registerTaskProvider(
        'multi-terminal',
        new MultiTerminalTaskProvider()
    );
    
    // Команда остановки всех задач
    const stopAllCmd = vscode.commands.registerCommand(
        'ergo-ms-multi-terminal.stopAll',
        stopAllTasks
    );
    
    // Отслеживаем завершение задач
    const taskEndListener = vscode.tasks.onDidEndTask(e => {
        for (const [group, executions] of taskGroups) {
            const index = executions.findIndex(exec => exec === e.execution);
            if (index > -1) {
                executions.splice(index, 1);
                break;
            }
        }
    });
    
    context.subscriptions.push(taskProvider, stopAllCmd, taskEndListener);
}

function deactivate() {
    taskGroups.clear();
}

module.exports = { activate, deactivate };
