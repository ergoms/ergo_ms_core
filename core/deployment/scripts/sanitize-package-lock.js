/**
 * Удаляет из package-lock.json записи модулей и их workspace-пакетов.
 */

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const NPM_ROOT = path.join(ROOT, 'virtual_env', 'npm')
const LOCK_PATH = path.join(NPM_ROOT, 'package-lock.json')
const CORE_CLIENT_WORKSPACE = '../../core/client'
const ALLOWED_ERGO_MS_PACKAGES = new Set(['@ergo-ms/core-client'])

function isModuleWorkspaceKey(key) {
  return key.includes('modules/') || key.includes('modules\\')
}

function isModuleErgoMsNodeModulesKey(key) {
  if (!key.includes('node_modules/@ergo-ms/')) {
    return false
  }
  const idx = key.lastIndexOf('node_modules/')
  const packageName = key.slice(idx + 'node_modules/'.length)
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
    if (value.resolved.includes('modules/') || value.resolved.includes('modules\\')) {
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

function isCoreClientWorkspace(workspace) {
  const normalized = workspace.replace(/\\/g, '/')
  return normalized === 'core/client' || normalized.endsWith('/core/client')
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
    cleaned[''].workspaces = workspaces.filter(
      (workspace) => !String(workspace).includes('modules/'),
    )
    if (!cleaned[''].workspaces.some(isCoreClientWorkspace)) {
      cleaned[''].workspaces = [CORE_CLIENT_WORKSPACE, ...cleaned[''].workspaces]
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
    console.error('[npm] package-lock.json не найден в virtual_env/npm.')
    process.exit(1)
  }
  console.log('[npm] package-lock.json очищен от записей модулей.')
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : ''
const selfPath = fileURLToPath(import.meta.url)
if (invokedPath === selfPath) {
  main()
}
