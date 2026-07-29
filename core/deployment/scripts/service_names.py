"""
Единые имена OS-служб ERGO MS.

Префикс: ergo_ms_ (Windows NSSM и Linux systemd).
"""

from __future__ import annotations

# Приложение
API_DEV = 'ergo_ms_api_dev'
CLIENT_DEV = 'ergo_ms_client_dev'
MEDIA_API = 'ergo_ms_media_api'
CELERY_BEAT = 'ergo_ms_celery_beat'
CELERY_WORKER = 'ergo_ms_celery_worker'

# Portable infra
REDIS = 'ergo_ms_redis'
NGINX = 'ergo_ms_nginx'
POSTGRES = 'ergo_ms_postgres'

BASE_SERVICES = (API_DEV, CLIENT_DEV, MEDIA_API, CELERY_BEAT)

# Старые имена (до унификации) — stop/clean/uninstall
LEGACY_SERVICE_NAMES = (
    'ergo-api-dev',
    'ergo-client-dev',
    'ergo-media-api',
    'ergo-celery-beat',
    'ergo-celery-worker',
    'ergo-redis',
    'ergo-postgres',
)


def celery_worker(key: str | None = None) -> str:
    if not key:
        return CELERY_WORKER
    return f'{CELERY_WORKER}_{key}'


def is_celery_worker(name: str) -> bool:
    base = name.replace('.service', '')
    return base == CELERY_WORKER or base.startswith(f'{CELERY_WORKER}_')


def celery_worker_key(name: str) -> str | None:
    base = name.replace('.service', '')
    prefix = f'{CELERY_WORKER}_'
    if base.startswith(prefix):
        return base[len(prefix):] or None
    if base == CELERY_WORKER:
        return None
    # legacy
    legacy = 'ergo-celery-worker-'
    if base.startswith(legacy):
        return base[len(legacy):] or None
    if base == 'ergo-celery-worker':
        return None
    return None
