/**
 * ОС-абстракция для .vscode (расширения и скрипты).
 * Для тестов: setImpl(mock) / resetImpl()
 */

const path = require('path');

let _impl = null;

function getImpl() {
  if (_impl) return _impl;
  _impl = process.platform === 'win32' ? createWindowsImpl() : createUnixImpl();
  return _impl;
}

function setImpl(impl) {
  _impl = impl;
}

function resetImpl() {
  _impl = null;
}

function createWindowsImpl() {
  return {
    isWindows: () => true,
    isDarwin: () => false,
    getGlobalConfigDir: (homeDir, appName, isCursor) => {
      const app = isCursor ? 'Cursor' : 'Code';
      return path.join(process.env.APPDATA || '', app, 'User');
    },
    getLocalExtensionsDir: (homeDir, isCursor) => {
      const dir = isCursor ? '.cursor' : '.vscode';
      return path.join(homeDir, dir, 'extensions');
    },
    getRemoteExtensionsDirs: () => [],
    supportsRemoteInstall: () => false,
    getProcessExecution: (command, cwd) => {
      const usePowerShell =
        (command.includes('.ps1') && command.includes('powershell')) ||
        (command.startsWith('powershell') && command.includes('.ps1'));
      if (usePowerShell) {
        return {
          executable: 'powershell.exe',
          args: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
          options: { cwd }
        };
      }
      return {
        executable: 'cmd.exe',
        args: ['/d', '/c', command],
        options: { cwd }
      };
    }
  };
}

function createUnixImpl() {
  return {
    isWindows: () => false,
    isDarwin: () => process.platform === 'darwin',
    getGlobalConfigDir: (homeDir, appName, isCursor) => {
      const app = isCursor ? 'Cursor' : 'Code';
      if (process.platform === 'darwin') {
        return path.join(homeDir, 'Library', 'Application Support', app, 'User');
      }
      return path.join(homeDir, '.config', app, 'User');
    },
    getLocalExtensionsDir: (homeDir, isCursor) => {
      const dir = isCursor ? '.cursor' : '.vscode';
      return path.join(homeDir, dir, 'extensions');
    },
    getRemoteExtensionsDirs: (homeDir) => {
      const dirs = [];
      const possibleDirs = [
        path.join(homeDir, '.vscode-server', 'extensions'),
        path.join(homeDir, '.cursor-server', 'extensions')
      ];
      const fs = require('fs');
      for (const dir of possibleDirs) {
        const serverDir = path.join(dir, '..');
        if (fs.existsSync(serverDir)) {
          dirs.push(dir);
        }
      }
      return dirs;
    },
    supportsRemoteInstall: () => true,
    getProcessExecution: (command, cwd) => ({
      executable: '/bin/bash',
      args: ['-l', '-c', command],
      options: { cwd }
    })
  };
}

function isWindows() {
  return getImpl().isWindows();
}

function isDarwin() {
  return getImpl().isDarwin();
}

function getGlobalConfigDir(homeDir, appName, isCursor) {
  return getImpl().getGlobalConfigDir(homeDir, appName, isCursor);
}

function getLocalExtensionsDir(homeDir, isCursor) {
  return getImpl().getLocalExtensionsDir(homeDir, isCursor);
}

function getRemoteExtensionsDirs(homeDir) {
  return getImpl().getRemoteExtensionsDirs(homeDir);
}

function supportsRemoteInstall() {
  return getImpl().supportsRemoteInstall();
}

function getProcessExecution(command, cwd) {
  return getImpl().getProcessExecution(command, cwd);
}

module.exports = {
  setImpl,
  resetImpl,
  isWindows,
  isDarwin,
  getGlobalConfigDir,
  getLocalExtensionsDir,
  getRemoteExtensionsDirs,
  supportsRemoteInstall,
  getProcessExecution
};
