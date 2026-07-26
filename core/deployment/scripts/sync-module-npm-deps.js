/**
 * Сканирует package.json в modules/<name>/client и проверяет, что все модульные
 * npm-зависимости установлены в virtual_env/npm/node_modules (hoisted).
 *
 * Установка — через npm install <pkg>@<ver> --no-save --no-package-lock,
 * чтобы модульные пакеты не попадали в package-lock.json npm-root.
 *
 * С --install-missing / --update в конце: npm prune (лишнее у ядра), затем снова
 * ставит модульные пакеты — prune считает --no-save лишними, хотя они нужны модулям.
 * После этого чистит virtual_env/cache/npm от tarball'ов пакетов, которых нет
 * в текущем node_modules, и мусор в virtual_env/cache/tmp.
 *
 * С --update — переустанавливает модульные пакеты в пределах semver из package.json.
 */

import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { loadDisabledModules } from '../../../core/client/scripts/lib/parse-disabled-modules.js'
import { runNpm } from './run_npm_spawn.js'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const NPM_ROOT = path.join(ROOT, 'virtual_env', 'npm')
const NPM_CACHE = path.join(ROOT, 'virtual_env', 'cache', 'npm')
const CACHE_TMP = path.join(ROOT, 'virtual_env', 'cache', 'tmp')
const MODULES_ROOT = path.join(ROOT, 'modules')
const NODE_MODULES = path.join(NPM_ROOT, 'node_modules')
const INSTALL_MISSING = process.argv.includes('--install-missing')
const UPDATE = process.argv.includes('--update')
const PACKAGE_FILTERS = process.argv
  .slice(2)
  .filter((arg) => arg && !arg.startsWith('-'))
const TMP_PREFIXES = ['ergo_install_', 'ergo_update_', 'ergo-npm-', 'ergo_npm_', 'ergo-npm-mod-']

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
  const cacheTmp = path.join(ROOT, 'virtual_env', 'cache', 'tmp')
  fs.mkdirSync(cacheTmp, { recursive: true })
  const staging = fs.mkdtempSync(path.join(cacheTmp, 'ergo-npm-mod-'))
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

function filterModuleDeps(moduleDeps) {
  if (PACKAGE_FILTERS.length === 0) {
    return moduleDeps
  }
  const wanted = new Set(PACKAGE_FILTERS.map((name) => name.toLowerCase()))
  return moduleDeps.filter((entry) => wanted.has(entry.depName.toLowerCase()))
}

function installPackageSpecs(specs, label) {
  if (specs.length === 0) {
    return
  }

  if (isDockerNpmInstall()) {
    installMissingPackagesDocker(specs)
    return
  }

  console.log(`[npm] ${label} (${specs.length}): ${specs.join(', ')}`)

  const result = runNpm(
    ['install', ...specs, '--no-save', '--no-package-lock', '--ignore-scripts'],
    { cwd: NPM_ROOT },
  )

  if (result.status !== 0) {
    process.exit(result.status ?? 1)
  }
}

function installMissingPackages(missing) {
  const unique = uniqueMissingPackages(missing)
  const specs = unique.map((entry) => `${entry.depName}@${entry.depVersion}`)
  installPackageSpecs(specs, 'Доустановка пакетов')
}

function updateModulePackages(moduleDeps) {
  const unique = uniqueMissingPackages(moduleDeps)
  const specs = unique.map((entry) => `${entry.depName}@${entry.depVersion}`)
  installPackageSpecs(specs, 'Обновление модульных пакетов в пределах semver')
}

function pruneExtraneousPackages(allModuleDeps) {
  console.log('[npm] Удаление пакетов, которых нет в package.json ядра...')
  const result = runNpm(
    ['prune', '--no-package-lock', '--ignore-scripts'],
    { cwd: NPM_ROOT },
  )
  if (result.status !== 0) {
    process.exit(result.status ?? 1)
  }

  // npm prune считает пакеты из `npm install --no-save` лишними, даже если они
  // объявлены в package.json workspace-модуля (их нет в package-lock ядра).
  const missingAfterPrune = allModuleDeps.filter(
    (entry) => !isDependencyInstalled(entry.depName),
  )
  if (missingAfterPrune.length > 0) {
    console.log(
      `[npm] Восстановление ${uniqueMissingPackages(missingAfterPrune).length} модульных пакетов после prune...`,
    )
    installMissingPackages(missingAfterPrune)
  }
}

function ensureNpmCacheEnv() {
  fs.mkdirSync(NPM_CACHE, { recursive: true })
  process.env.npm_config_cache = NPM_CACHE
  process.env.NPM_CONFIG_CACHE = NPM_CACHE
}

function cleanCacheTmp() {
  if (!fs.existsSync(CACHE_TMP)) {
    return
  }
  let removed = 0
  for (const entry of fs.readdirSync(CACHE_TMP, { withFileTypes: true })) {
    if (!TMP_PREFIXES.some((prefix) => entry.name.startsWith(prefix))) {
      continue
    }
    const full = path.join(CACHE_TMP, entry.name)
    try {
      fs.rmSync(full, { recursive: true, force: true })
      removed += 1
    } catch {
      // ignore
    }
  }
  if (removed > 0) {
    console.log(`[npm] Очистка virtual_env/cache/tmp: удалено ${removed} временных путей.`)
  }
}

function collectInstalledPackageNames(nodeModulesDir, names = new Set()) {
  if (!fs.existsSync(nodeModulesDir)) {
    return names
  }
  for (const entry of fs.readdirSync(nodeModulesDir, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) {
      continue
    }
    if (entry.name.startsWith('@')) {
      const scopeDir = path.join(nodeModulesDir, entry.name)
      for (const pkg of fs.readdirSync(scopeDir, { withFileTypes: true })) {
        if (!pkg.isDirectory()) {
          continue
        }
        const pkgDir = path.join(scopeDir, pkg.name)
        readPackageName(pkgDir, names)
        collectInstalledPackageNames(path.join(pkgDir, 'node_modules'), names)
      }
      continue
    }
    const pkgDir = path.join(nodeModulesDir, entry.name)
    readPackageName(pkgDir, names)
    collectInstalledPackageNames(path.join(pkgDir, 'node_modules'), names)
  }
  return names
}

function readPackageName(pkgDir, names) {
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'))
    if (pkg.name) {
      names.add(String(pkg.name).toLowerCase())
    }
  } catch {
    // ignore broken/incomplete installs
  }
}

function parsePackageFromNpmCacheKey(key) {
  const marker = 'registry.npmjs.org/'
  const idx = key.indexOf(marker)
  if (idx < 0) {
    return null
  }
  let rest = key.slice(idx + marker.length)
  try {
    rest = decodeURIComponent(rest)
  } catch {
    // keep raw
  }
  if (rest.startsWith('@')) {
    const match = rest.match(/^(@[^/]+\/[^/]+)/)
    return match ? match[1].toLowerCase() : null
  }
  const match = rest.match(/^([^/@]+)/)
  return match ? match[1].toLowerCase() : null
}

function cleanNpmLogs() {
  const logsDir = path.join(NPM_CACHE, '_logs')
  if (!fs.existsSync(logsDir)) {
    return
  }
  let removed = 0
  for (const entry of fs.readdirSync(logsDir, { withFileTypes: true })) {
    if (!entry.isFile()) {
      continue
    }
    try {
      fs.rmSync(path.join(logsDir, entry.name), { force: true })
      removed += 1
    } catch {
      // ignore
    }
  }
  if (removed > 0) {
    console.log(`[npm] Кэш npm: удалено ${removed} файлов логов.`)
  }
}

function pruneUnusedNpmCache() {
  ensureNpmCacheEnv()
  cleanCacheTmp()
  cleanNpmLogs()

  const keep = collectInstalledPackageNames(NODE_MODULES)
  if (keep.size === 0) {
    console.log('[npm] Кэш npm: node_modules пуст — очистка кэша пропущена.')
    return
  }

  const listed = runNpm(['cache', 'ls'], {
    cwd: NPM_ROOT,
    stdio: 'pipe',
    encoding: 'utf8',
  })
  if (listed.status !== 0) {
    console.log('[npm] Кэш npm: не удалось получить список (cache ls).')
    return
  }

  const keys = String(listed.stdout || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)

  const toClean = []
  const unusedPackages = new Set()
  for (const key of keys) {
    const pkg = parsePackageFromNpmCacheKey(key)
    if (!pkg || keep.has(pkg)) {
      continue
    }
    toClean.push(key)
    unusedPackages.add(pkg)
  }

  if (toClean.length === 0) {
    console.log('[npm] Кэш npm: лишних индексных записей нет.')
  } else {
    console.log(
      `[npm] Кэш npm: удаление ${toClean.length} записей (${unusedPackages.size} пакетов вне node_modules)...`,
    )
    for (const key of toClean) {
      runNpm(['cache', 'clean', key], {
        cwd: NPM_ROOT,
        stdio: 'pipe',
        encoding: 'utf8',
      })
    }
  }

  // cache clean по ключу часто оставляет blob'ы в _cacache — verify их собирает.
  console.log('[npm] Кэш npm: проверка и сжатие (_cacache verify)...')
  runNpm(['cache', 'verify'], {
    cwd: NPM_ROOT,
    stdio: 'inherit',
  })
}

function finalizeDependencySync(allModuleDeps) {
  pruneExtraneousPackages(allModuleDeps)
  pruneUnusedNpmCache()
}

function main() {
  ensureNpmCacheEnv()
  const allModuleDeps = collectModuleDependencies()
  const moduleDeps = filterModuleDeps(allModuleDeps)
  const applyChanges = INSTALL_MISSING || UPDATE

  if (UPDATE) {
    if (moduleDeps.length === 0) {
      console.log('[npm] Модульных npm-зависимостей для обновления не найдено.')
    } else {
      updateModulePackages(moduleDeps)
      console.log('[npm] Модульные зависимости обновлены.')
    }
    finalizeDependencySync(allModuleDeps)
    return
  }

  if (moduleDeps.length === 0) {
    console.log('[npm] Модульных npm-зависимостей не найдено.')
  } else {
    const missing = moduleDeps.filter((entry) => !isDependencyInstalled(entry.depName))

    if (missing.length === 0) {
      console.log(`[npm] Модульные зависимости (${moduleDeps.length}) установлены.`)
    } else {
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
  }

  if (applyChanges) {
    finalizeDependencySync(allModuleDeps)
  }
}

main()
