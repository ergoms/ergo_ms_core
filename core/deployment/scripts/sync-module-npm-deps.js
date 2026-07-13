/**
 * Сканирует package.json в modules/<name>/client и проверяет, что все модульные
 * npm-зависимости установлены в корневом node_modules (hoisted).
 *
 * Установка — через npm install <pkg>@<ver> --no-save --no-package-lock,
 * чтобы модульные пакеты не попадали в корневой package-lock.json.
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

  if (!fs.existsSync(MODULES_ROOT)) {
    return false
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

function uniqueMissingPackages(missing) {
  const byName = new Map()
  for (const entry of missing) {
    if (!byName.has(entry.depName)) {
      byName.set(entry.depName, entry)
    }
  }
  return [...byName.values()]
}

function installMissingPackages(missing) {
  const npmCmd = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const unique = uniqueMissingPackages(missing)
  const specs = unique.map((entry) => `${entry.depName}@${entry.depVersion}`)

  console.log(`[npm] Доустановка пакетов (${specs.length}): ${specs.join(', ')}`)

  const result = spawnSync(
    npmCmd,
    ['install', ...specs, '--no-save', '--no-package-lock', '--ignore-scripts'],
    {
      cwd: ROOT,
      stdio: 'inherit',
      env: process.env,
      shell: process.platform === 'win32',
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

  const uniqueMissing = uniqueMissingPackages(missing)
  console.log(`[npm] Не установлено пакетов: ${uniqueMissing.length}`)
  for (const entry of uniqueMissing) {
    console.log(`  - ${entry.depName}`)
  }

  if (!INSTALL_MISSING) {
    console.log('[npm] Запустите: ergoms npm run install:all')
    return
  }

  installMissingPackages(missing)

  const stillMissing = missing.filter((entry) => !isDependencyInstalled(entry.depName))
  if (stillMissing.length > 0) {
    console.error('[npm] Не удалось установить пакеты:')
    for (const entry of uniqueMissingPackages(stillMissing)) {
      const sources = stillMissing
        .filter((item) => item.depName === entry.depName)
        .map((item) => item.module)
      console.error(`  - ${entry.depName} (модули: ${sources.join(', ')})`)
    }
    process.exit(1)
  }

  console.log('[npm] Модульные зависимости успешно установлены.')
}

main()
