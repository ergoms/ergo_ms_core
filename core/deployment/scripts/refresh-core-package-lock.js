/**
 * Пересобирает package-lock.json только для ядра (virtual_env/npm + core/client).
 * Workspaces модулей временно убираются, чтобы lock не содержал modules.
 */

import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { sanitizePackageLockFile } from './sanitize-package-lock.js'
import { runNpm } from './run_npm_spawn.js'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const NPM_ROOT = path.join(ROOT, 'virtual_env', 'npm')
const PACKAGE_JSON_PATH = path.join(NPM_ROOT, 'package.json')
const CORE_CLIENT_WORKSPACE = '../../core/client'
const VALIDATE_SCRIPT = path.join(ROOT, 'core/deployment/scripts/validate_npm_lock.js')

function readPackageJson() {
  return JSON.parse(fs.readFileSync(PACKAGE_JSON_PATH, 'utf8'))
}

function writePackageJson(data) {
  fs.writeFileSync(PACKAGE_JSON_PATH, `${JSON.stringify(data, null, 2)}\n`, 'utf8')
}

function removeModuleWorkspaceLinks() {
  const ergoMsDir = path.join(NPM_ROOT, 'node_modules', '@ergo-ms')
  if (!fs.existsSync(ergoMsDir)) {
    return
  }

  for (const dirent of fs.readdirSync(ergoMsDir, { withFileTypes: true })) {
    if (!dirent.isDirectory() && !dirent.isSymbolicLink()) {
      continue
    }
    if (dirent.name === 'core-client') {
      continue
    }
    fs.rmSync(path.join(ergoMsDir, dirent.name), { recursive: true, force: true })
  }
}

function runNpmInstall() {
  const lockPath = path.join(NPM_ROOT, 'package-lock.json')
  if (fs.existsSync(lockPath)) {
    fs.unlinkSync(lockPath)
    console.log('[npm] Удалён старый package-lock.json перед пересборкой.')
  }

  const result = runNpm(
    ['install', '--include-workspace-root', '--ignore-scripts', '--package-lock'],
    { cwd: NPM_ROOT },
  )

  if (result.status !== 0) {
    process.exit(result.status ?? 1)
  }
}

function runValidation() {
  const result = spawnSync(process.execPath, [VALIDATE_SCRIPT], {
    cwd: ROOT,
    stdio: 'inherit',
    env: process.env,
  })

  if (result.status !== 0) {
    process.exit(result.status ?? 1)
  }
}

function main() {
  if (!fs.existsSync(PACKAGE_JSON_PATH)) {
    console.error('[npm] package.json не найден в virtual_env/npm')
    process.exit(1)
  }

  const original = readPackageJson()
  const fullWorkspaces = original.workspaces ?? []

  console.log('[npm] Пересборка package-lock.json (только ядро)...')
  console.log(`[npm] Полный список workspaces (${fullWorkspaces.length}): ${fullWorkspaces.join(', ')}`)

  const patched = {
    ...original,
    workspaces: [CORE_CLIENT_WORKSPACE],
  }
  writePackageJson(patched)

  try {
    removeModuleWorkspaceLinks()
    runNpmInstall()
    sanitizePackageLockFile(path.join(NPM_ROOT, 'package-lock.json'))
  } finally {
    writePackageJson(original)
    console.log('[npm] Workspaces в package.json восстановлены.')
  }

  console.log('[npm] Проверка package-lock.json...')
  runValidation()
  console.log('[npm] package-lock.json обновлён (ядро).')
}

main()
