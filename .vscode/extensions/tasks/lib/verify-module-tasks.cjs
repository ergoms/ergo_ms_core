/**
 * Локальная проверка discovery модульных задач (без vscode API).
 * Запуск: node .vscode/extensions/tasks/lib/verify-module-tasks.cjs
 */
const path = require('path');
const fs = require('fs');
const os = require('os');
const {
  parseYaml,
  discoverModuleTaskDefs,
  discoverModuleIncludeTasks,
  ERGO_MODULE_TASK_TYPE
} = require('./module-tasks.cjs');

const root = path.resolve(__dirname, '../../../..');
const warn = () => {};

const yaml = fs.readFileSync(
  path.join(root, 'modules/module_template/vscode.tasks.yaml'),
  'utf8'
);
const parsed = parseYaml(yaml);
if (parsed.module !== 'module_template') {
  throw new Error('module field mismatch');
}
if (!Array.isArray(parsed.tasks) || parsed.tasks.length < 1) {
  throw new Error('tasks not array of objects');
}
if (parsed.tasks[0].label !== 'Template: Migrate') {
  throw new Error(`label parse fail: ${JSON.stringify(parsed.tasks[0])}`);
}
if (!String(parsed.tasks[0].command).startsWith('ergoms')) {
  throw new Error('command parse fail');
}
console.log('[OK] parseYaml list-of-objects');

const defs = discoverModuleTaskDefs(root, () => '', warn);
const tpl = defs.find(
  (d) => d.module === 'module_template' && d.label === 'Template: Migrate'
);
if (!tpl) {
  throw new Error(`template task not discovered: ${JSON.stringify(defs)}`);
}
if (tpl.type !== ERGO_MODULE_TASK_TYPE) {
  throw new Error('wrong type');
}
if (tpl.command !== 'ergoms module_template:migrate') {
  throw new Error('wrong command');
}
console.log(`[OK] discover enabled module_template (${defs.length} tasks total)`);

const disabledDefs = discoverModuleTaskDefs(
  root,
  (k) => (k === 'DISABLED_MODULES' ? 'module_template' : ''),
  warn
);
if (disabledDefs.some((d) => d.module === 'module_template')) {
  throw new Error('disabled module still present');
}
console.log('[OK] DISABLED_MODULES hides module_template');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergo-mtasks-'));
const modDir = path.join(tmpDir, 'modules', 'fake_mod');
fs.mkdirSync(path.join(modDir, 'api'), { recursive: true });
fs.writeFileSync(
  path.join(modDir, 'vscode.tasks.yaml'),
  [
    'module: fake_mod',
    'tasks:',
    '  - label: "Bad"',
    '    detail: "Тест"',
    '    command: "python manage.py migrate"',
    '  - label: "Good"',
    '    detail: "Ок"',
    '    command: "ergoms help"'
  ].join('\n')
);
const w2 = [];
const fakeDefs = discoverModuleTaskDefs(tmpDir, () => '', (m) => w2.push(m));
if (fakeDefs.some((d) => d.label === 'Bad')) {
  throw new Error('invalid command accepted');
}
if (!fakeDefs.some((d) => d.label === 'Good')) {
  throw new Error('valid command missing');
}
if (!w2.some((m) => m.includes('ergoms'))) {
  throw new Error('expected warning for non-ergoms');
}
console.log('[OK] non-ergoms command skipped with warning');
fs.rmSync(tmpDir, { recursive: true, force: true });

const includeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergo-mtasks-inc-'));
const incMod = path.join(includeDir, 'modules', 'agg_mod');
fs.mkdirSync(path.join(incMod, 'api'), { recursive: true });
fs.writeFileSync(
  path.join(incMod, 'vscode.tasks.yaml'),
  [
    'module: agg_mod',
    'tasks:',
    '  - label: "Agg: Install"',
    '    detail: "Установка"',
    '    command: "ergoms agg_mod:install"',
    '    hide: true',
    '    include_in:',
    '      - setup-full',
    '  - label: "Agg: Start"',
    '    detail: "Запуск"',
    '    command: "ergoms agg_mod:start"',
    '    panel: new',
    '    include_in:',
    '      - start-all'
  ].join('\n')
);
const includeParsed = parseYaml(
  fs.readFileSync(path.join(incMod, 'vscode.tasks.yaml'), 'utf8')
);
if (!Array.isArray(includeParsed.tasks[0].include_in)) {
  throw new Error('include_in not parsed as array');
}
if (!includeParsed.tasks[0].include_in.includes('setup-full')) {
  throw new Error('include_in setup-full missing in parse');
}
const setupTasks = discoverModuleIncludeTasks(
  includeDir,
  () => '',
  'setup-full',
  () => {}
);
if (!setupTasks.some((t) => t.label === 'Agg: Install' && t.hide)) {
  throw new Error('hide+setup-full task missing from aggregate');
}
const startTasks = discoverModuleIncludeTasks(
  includeDir,
  () => '',
  'start-all',
  () => {}
);
if (!startTasks.some((t) => t.label === 'Agg: Start')) {
  throw new Error('start-all task missing from aggregate');
}
const runTaskDefs = discoverModuleTaskDefs(includeDir, () => '', () => {});
if (runTaskDefs.some((t) => t.label === 'Agg: Install')) {
  throw new Error('hide task leaked into Run Task discovery');
}
if (!runTaskDefs.some((t) => t.label === 'Agg: Start')) {
  throw new Error('visible start task missing from Run Task discovery');
}
console.log('[OK] include_in setup-full/start-all aggregation');
fs.rmSync(includeDir, { recursive: true, force: true });

const vsixDir = path.join(root, '.vscode/local-extensions');
const vsixMatch = fs.existsSync(vsixDir)
  ? fs.readdirSync(vsixDir).find((name) => /^ergo-ms-tasks-[\d.]+\.vsix$/.test(name))
  : null;
if (!vsixMatch) {
  throw new Error('VSIX ergo-ms-tasks missing in .vscode/local-extensions');
}
console.log(`[OK] VSIX ${vsixMatch} present`);
console.log('[OK] all checks passed');
