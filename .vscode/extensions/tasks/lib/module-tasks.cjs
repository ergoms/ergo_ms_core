/**
 * Discovery модульных задач VS Code из modules/<name>/vscode.tasks.yaml.
 * Без зависимости от vscode API (warn — колбэк).
 */

const fs = require('fs');
const path = require('path');

const MODULE_TASKS_FILENAME = 'vscode.tasks.yaml';
const ERGO_MODULE_TASK_TYPE = 'ergo-module';
/** Подпись группы в Run Task (не путать с type). */
const ERGO_MODULE_TASK_SOURCE = 'ERGO MS Modules';

function unquoteYamlScalar(value) {
  const s = String(value || '').trim();
  if (
    (s.startsWith('"') && s.endsWith('"'))
    || (s.startsWith("'") && s.endsWith("'"))
  ) {
    return s.slice(1, -1);
  }
  return s;
}

/**
 * Простой парсер YAML: map, списки строк, списки объектов.
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
      const rest = trimmed.substring(2).trim();
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
      if (!Array.isArray(arr)) {
        continue;
      }
      const colonIndex = rest.indexOf(':');
      const looksLikeMapItem =
        colonIndex > 0
        && !rest.startsWith('"')
        && !rest.startsWith("'");
      if (looksLikeMapItem) {
        const key = rest.substring(0, colonIndex).trim();
        let value = unquoteYamlScalar(rest.substring(colonIndex + 1).trim());
        const item = {};
        if (value === '' || value === '|' || value === '>') {
          item[key] = {};
          arr.push(item);
          stack.push({ obj: item[key], indent: indent + 2 });
        } else {
          item[key] = value;
          arr.push(item);
          stack.push({ obj: item, indent: indent });
        }
      } else {
        arr.push(unquoteYamlScalar(rest));
      }
      continue;
    }

    const colonIndex = trimmed.indexOf(':');
    if (colonIndex > 0) {
      const key = trimmed.substring(0, colonIndex).trim();
      let value = unquoteYamlScalar(trimmed.substring(colonIndex + 1).trim());

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

function parseDisabledModules(raw) {
  return new Set(
    String(raw || '')
      .split(',')
      .map((item) => item.trim())
      .filter(Boolean)
  );
}

function yamlTruthy(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'yes';
}

/**
 * @param {string} workspaceRoot
 * @param {(key: string) => string|undefined} getEnv
 * @returns {{name: string, moduleDir: string}[]}
 */
function listEnabledModuleDirs(workspaceRoot, getEnv) {
  const modulesRoot = path.join(workspaceRoot, 'modules');
  if (!fs.existsSync(modulesRoot)) {
    return [];
  }
  const disabled = parseDisabledModules(getEnv('DISABLED_MODULES'));
  const entries = fs.readdirSync(modulesRoot, { withFileTypes: true });
  const dirs = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }
    const name = entry.name;
    if (disabled.has(name)) {
      continue;
    }
    const moduleDir = path.join(modulesRoot, name);
    const hasApi = fs.existsSync(path.join(moduleDir, 'api'));
    const hasClient = fs.existsSync(path.join(moduleDir, 'client'));
    if (!hasApi && !hasClient) {
      continue;
    }
    dirs.push({ name, moduleDir });
  }
  return dirs.sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * @param {string} workspaceRoot
 * @param {(key: string) => string|undefined} getEnv
 * @param {(message: string) => void} [warn]
 * @returns {object[]}
 */
function discoverModuleTaskDefs(workspaceRoot, getEnv, warn = () => {}) {
  const seenLabels = new Set();
  const defs = [];
  for (const { name, moduleDir } of listEnabledModuleDirs(workspaceRoot, getEnv)) {
    const filePath = path.join(moduleDir, MODULE_TASKS_FILENAME);
    if (!fs.existsSync(filePath)) {
      continue;
    }
    let data;
    try {
      data = parseYaml(fs.readFileSync(filePath, 'utf8'));
    } catch (error) {
      warn(`${name}: не удалось разобрать ${MODULE_TASKS_FILENAME}: ${error.message}`);
      continue;
    }
    const declaredModule = String(data.module || '').trim();
    if (declaredModule && declaredModule !== name) {
      warn(
        `${name}: поле module «${declaredModule}» не совпадает с каталогом — задачи пропущены`
      );
      continue;
    }
    const tasks = Array.isArray(data.tasks) ? data.tasks : [];
    for (const raw of tasks) {
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
        warn(`${name}: элемент tasks должен быть объектом — пропуск`);
        continue;
      }
      const label = String(raw.label || '').trim();
      const detail = String(raw.detail || '').trim();
      const command = String(raw.command || '').trim();
      if (!label || !detail || !command) {
        warn(`${name}: задача без label/detail/command — пропуск`);
        continue;
      }
      if (!/^ergoms(\s|$)/.test(command)) {
        warn(`${name}: «${label}» — command должен начинаться с ergoms — пропуск`);
        continue;
      }
      if (yamlTruthy(raw.hide)) {
        continue;
      }
      if (seenLabels.has(label)) {
        warn(`${name}: label «${label}» уже объявлен — повтор пропущен`);
        continue;
      }
      seenLabels.add(label);
      const panelRaw = String(raw.panel || 'shared').trim().toLowerCase();
      defs.push({
        type: ERGO_MODULE_TASK_TYPE,
        label,
        detail,
        command,
        module: name,
        panel: panelRaw === 'new' ? 'new' : 'shared'
      });
    }
  }
  return defs;
}

module.exports = {
  MODULE_TASKS_FILENAME,
  ERGO_MODULE_TASK_TYPE,
  ERGO_MODULE_TASK_SOURCE,
  parseYaml,
  parseDisabledModules,
  listEnabledModuleDirs,
  discoverModuleTaskDefs
};
