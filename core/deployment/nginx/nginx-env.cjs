/**
 * Общая логика nginx-сценария для Node (Vite, скрипты ergoms).
 * Дублирует src.config.nginx_runtime (Python).
 */

function readBool(value, defaultValue = false) {
  if (value === undefined || value === null || value === '') {
    return defaultValue
  }
  const normalized = String(value).trim().toLowerCase()
  return normalized === 'true' || normalized === '1' || normalized === 'yes'
}

function nginxEnabled(env = process.env) {
  return readBool(env.NGINX_ENABLED, false)
}

function detectLanIp() {
  try {
    const os = require('os')
    const ifaces = os.networkInterfaces()
    for (const entries of Object.values(ifaces)) {
      for (const iface of entries || []) {
        if (iface.family === 'IPv4' && !iface.internal) {
          return iface.address
        }
      }
    }
  } catch {
    // ignore
  }
  return ''
}

function nginxPublicHost(env = process.env) {
  const explicit = (env.NGINX_PUBLIC_HOST || '').trim()
  if (explicit) {
    return explicit
  }

  const serverName = (env.NGINX_SERVER_NAME || 'localhost').trim()
  if (nginxEnabled(env) && (!serverName || serverName === 'localhost' || serverName === '127.0.0.1')) {
    const detected = detectLanIp()
    if (detected) {
      return detected
    }
  }

  return serverName || 'localhost'
}

function nginxListenHost(env = process.env) {
  return (env.NGINX_LISTEN_HOST || '0.0.0.0').trim() || '0.0.0.0'
}

function nginxListenPort(env = process.env) {
  return (env.NGINX_LISTEN_PORT || '80').trim() || '80'
}

function nginxUseHttps(env = process.env) {
  if (readBool(env.NGINX_USE_HTTPS, false)) {
    return true
  }
  return nginxListenPort(env) === '443'
}

function nginxPublicBaseUrl(env = process.env) {
  const override = (env.FRONTEND_BASE_URL || '').trim()
  if (override && !nginxEnabled(env)) {
    return override.replace(/\/$/, '')
  }

  const scheme = nginxUseHttps(env) ? 'https' : 'http'
  const host = nginxPublicHost(env)
  const port = nginxListenPort(env)
  if ((scheme === 'http' && port === '80') || (scheme === 'https' && port === '443')) {
    return `${scheme}://${host}`
  }
  return `${scheme}://${host}:${port}`
}

function applyNginxClientEnv(env = process.env) {
  if (!nginxEnabled(env)) {
    return env
  }
  return {
    ...env,
    CLIENT_USE_RELATIVE_API: 'true',
    CLIENT_DEPLOY_TYPE: env.CLIENT_DEPLOY_TYPE || 'production',
    API_HOST: env.API_HOST || '127.0.0.1',
  }
}

/** @deprecated используйте applyNginxClientEnv */
const applyNginxViteEnv = applyNginxClientEnv

module.exports = {
  nginxEnabled,
  nginxPublicHost,
  nginxListenHost,
  nginxListenPort,
  nginxUseHttps,
  nginxPublicBaseUrl,
  applyNginxClientEnv,
  applyNginxViteEnv,
}
