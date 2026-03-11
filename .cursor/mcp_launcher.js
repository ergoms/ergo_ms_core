#!/usr/bin/env node
/**
 * Кроссплатформенный launcher для MCP Python серверов.
 * Node.js не зависит от line endings и работает везде, где есть npx.
 * Windows: py -3 | Linux/macOS: python3
 */
import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const isWindows = process.platform === 'win32';
const pythonCmd = isWindows ? 'py' : 'python3';
const pythonArgs = isWindows ? ['-3'] : [];

const projectRoot = path.resolve(__dirname, '..');
const wrapperPath = path.join(__dirname, 'mcp_python_wrapper.py');
const scriptArgs = process.argv.slice(2);

const args = [...pythonArgs, wrapperPath, ...scriptArgs];
const proc = spawn(pythonCmd, args, {
  cwd: projectRoot,
  stdio: 'inherit',
  shell: isWindows,
});

proc.on('error', (err) => {
  console.error(`MCP launcher: failed to run ${pythonCmd}:`, err.message);
  process.exit(1);
});

proc.on('exit', (code, signal) => {
  process.exit(code != null ? code : signal ? 1 : 0);
});
