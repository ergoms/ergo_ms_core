/**
 * Сканирует package.json в modules/<name>/client и проверяет, что все модульные
 * npm-зависимости установлены в корневом node_modules (npm workspaces + hoisted).
 *
 * Вызывается из postinstall; при отсутствующих пакетах — повторный npm install
 * с --workspaces --include-workspace-root (без lifecycle-скриптов, чтобы не зациклиться).
 */

import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const MODULES_ROOT = path.join(ROOT, 'modules')
const INSTALL_MISSING = process.argv.includes('--install-missing')

function collectModuleDependencies() {
  if (!fs.existsSync(MODULES_ROOT)) {
    return []
  }

  const entries = []

  for (const dirent of fs.readdirSync(MODULES_ROOT, { withFileTypes: true })) {
    if (!dirent.isDirectory()) {
      continue
    }

    const packageJsonPath = path.join(MODULES_ROOT, dirent.name, 'client', 'package.json')
    if (!fs.existsSync(packageJsonPath)) {
      continue
    }

    const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'))
    const dependencies = pkg.dependencies ?? {}

    for (const [depName, depVersion] of Object.entries(dependencies)) {
      entries.push({
        module: dirent.name,
        workspace: pkg.name,
        depName,
        depVersion,
      })
    }
  }

  return entries
}

function isDependencyInstalled(depName) {
  const rootDepPath = path.join(ROOT, 'node_modules', depName)
  if (fs.existsSync(rootDepPath)) {
    return true
  }

  for (const dirent of fs.readdirSync(MODULES_ROOT, { withFileTypes: true })) {
    if (!dirent.isDirectory()) {
      continue
    }

    const nestedDepPath = path.join(
      MODULES_ROOT,
      dirent.name,
      'client',
      'node_modules',
      depName,
    )
    if (fs.existsSync(nestedDepPath)) {
      return true
    }
  }

  return false
}

function installWorkspaceDependencies() {
  const npmCmd = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const result = spawnSync(
    npmCmd,
    ['install', '--workspaces', '--include-workspace-root', '--ignore-scripts'],
    {
      cwd: ROOT,
      stdio: 'inherit',
      env: process.env,
    },
  )

  if (result.status !== 0) {
    process.exit(result.status ?? 1)
  }
}

function main() {
  const moduleDeps = collectModuleDependencies()

  if (moduleDeps.length === 0) {
    return
  }

  const missing = moduleDeps.filter((entry) => !isDependencyInstalled(entry.depName))

  if (missing.length === 0) {
    console.log(`[npm] Модульные зависимости (${moduleDeps.length}) установлены.`)
    return
  }

  console.log(`[npm] Не установлено модульных зависимостей: ${missing.length}`)
  for (const entry of missing) {
    console.log(`  - ${entry.depName} (${entry.module})`)
  }

  if (!INSTALL_MISSING) {
    console.log('[npm] Запустите: ergoms npm install')
    return
  }

  console.log('[npm] Доустановка зависимостей workspace...')
  installWorkspaceDependencies()

  const stillMissing = missing.filter((entry) => !isDependencyInstalled(entry.depName))
  if (stillMissing.length > 0) {
    console.error('[npm] Не удалось установить модульные зависимости:')
    for (const entry of stillMissing) {
      console.error(`  - ${entry.depName} (${entry.module})`)
    }
    process.exit(1)
  }

  console.log('[npm] Модульные зависимости успешно установлены.')
}

main()
