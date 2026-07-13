/**
 * Удаляет из package-lock.json записи модулей и их workspace-пакетов.
 */

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const LOCK_PATH = path.join(ROOT, 'package-lock.json')
const ALLOWED_ERGO_MS_PACKAGES = new Set(['@ergo-ms/core-client'])

function isModuleWorkspaceKey(key) {
  return key.startsWith('modules/')
}

function isModuleErgoMsNodeModulesKey(key) {
  if (!key.startsWith('node_modules/@ergo-ms/')) {
    return false
  }
  const packageName = key.slice('node_modules/'.length)
  return !ALLOWED_ERGO_MS_PACKAGES.has(packageName)
}

function shouldDropPackageEntry(key, value) {
  if (isModuleWorkspaceKey(key)) {
    return true
  }
  if (isModuleErgoMsNodeModulesKey(key)) {
    return true
  }
  if (value && typeof value === 'object' && typeof value.resolved === 'string') {
    if (value.resolved.startsWith('modules/')) {
      return true
    }
  }
  if (value && typeof value === 'object' && typeof value.name === 'string') {
    if (value.name.startsWith('@ergo-ms/') && !ALLOWED_ERGO_MS_PACKAGES.has(value.name)) {
      return true
    }
  }
  return false
}

export function sanitizePackageLockData(lockData) {
  const packages = lockData.packages ?? {}
  const cleaned = {}

  for (const [key, value] of Object.entries(packages)) {
    if (shouldDropPackageEntry(key, value)) {
      continue
    }
    cleaned[key] = value
  }

  if (cleaned[''] && typeof cleaned[''] === 'object') {
    const workspaces = cleaned[''].workspaces ?? []
    cleaned[''].workspaces = workspaces.filter((workspace) => !workspace.includes('modules/'))
    if (!cleaned[''].workspaces.includes('core/client')) {
      cleaned[''].workspaces = ['core/client', ...cleaned[''].workspaces]
    }
  }

  return {
    ...lockData,
    packages: cleaned,
  }
}

export function sanitizePackageLockFile(lockPath = LOCK_PATH) {
  if (!fs.existsSync(lockPath)) {
    return false
  }

  const lockData = JSON.parse(fs.readFileSync(lockPath, 'utf8'))
  const sanitized = sanitizePackageLockData(lockData)
  fs.writeFileSync(lockPath, `${JSON.stringify(sanitized, null, 2)}\n`, 'utf8')
  return true
}

function main() {
  if (!sanitizePackageLockFile()) {
    console.error('[npm] package-lock.json не найден.')
    process.exit(1)
  }
  console.log('[npm] package-lock.json очищен от записей модулей.')
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : ''
const selfPath = fileURLToPath(import.meta.url)
if (invokedPath === selfPath) {
  main()
}
