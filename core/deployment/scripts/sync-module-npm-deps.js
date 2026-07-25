/**
 * Сканирует package.json в modules/<name>/client и проверяет, что все модульные
 * npm-зависимости установлены в virtual_env/npm/node_modules (hoisted).
 *
 * Установка — через npm install <pkg>@<ver> --no-save --no-package-lock,
 * чтобы модульные пакеты не попадали в package-lock.json npm-root.
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { loadDisabledModules } from '../../../core/client/scripts/lib/parse-disabled-modules.js'
import { runNpm } from './run_npm_spawn.js'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const NPM_ROOT = path.join(ROOT, 'virtual_env', 'npm')
const MODULES_ROOT = path.join(ROOT, 'modules')
const INSTALL_MISSING = process.argv.includes('--install-missing')

function collectModuleDependencies() {
  if (!fs.existsSync(MODULES_ROOT)) {
    return []
  }

  const disabledModules = loadDisabledModules()
  const entries = []

  for (const dirent of fs.readdirSync(MODULES_ROOT, { withFileTypes: true })) {
    if (!dirent.isDirectory()) {
      continue
    }
    if (disabledModules.has(dirent.name)) {
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
  const rootDepPath = path.join(NPM_ROOT, 'node_modules', depName)
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

const DOCKER_NPM_FLAGS = [
  '--no-save',
  '--no-package-lock',
  '--ignore-scripts',
  '--no-audit',
  '--no-fund',
]

function isDockerNpmInstall() {
  return Boolean(process.env.ERGO_DOCKER_SERVICE_NAME?.trim())
}

function copyPackageTree(sourceDir, targetDir) {
  if (fs.existsSync(targetDir)) {
    fs.rmSync(targetDir, { recursive: true, force: true })
  }
  fs.cpSync(sourceDir, targetDir, { recursive: true, force: true })
}

function installMissingPackagesDocker(specs) {
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'ergo-npm-mod-'))
  const npmCmd = 'npm'

  console.log(`[npm] Доустановка пакетов в staging (${specs.length}): ${specs.join(', ')}`)

  try {
    const result = spawnSync(
      npmCmd,
      ['install', ...specs, ...DOCKER_NPM_FLAGS, '--loglevel=warn'],
      {
        cwd: staging,
        stdio: 'inherit',
        env: process.env,
      },
    )

    if (result.status !== 0) {
      process.exit(result.status ?? 1)
    }

    const stagingModules = path.join(staging, 'node_modules')
    const targetModules = path.join(NPM_ROOT, 'node_modules')
    fs.mkdirSync(targetModules, { recursive: true })

    for (const entry of fs.readdirSync(stagingModules)) {
      if (entry.startsWith('.')) {
        continue
      }
      copyPackageTree(
        path.join(stagingModules, entry),
        path.join(targetModules, entry),
      )
    }
  } finally {
    fs.rmSync(staging, { recursive: true, force: true })
  }
}

function installMissingPackages(missing) {
  const unique = uniqueMissingPackages(missing)
  const specs = unique.map((entry) => `${entry.depName}@${entry.depVersion}`)

  if (isDockerNpmInstall()) {
    installMissingPackagesDocker(specs)
    return
  }

  console.log(`[npm] Доустановка пакетов (${specs.length}): ${specs.join(', ')}`)

  const result = runNpm(
    ['install', ...specs, '--no-save', '--no-package-lock', '--ignore-scripts'],
    { cwd: NPM_ROOT },
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
