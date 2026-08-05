"""
Единые имена OS-служб ERGO MS.

Префикс: ergo_ms_ (Windows NSSM и Linux systemd).
"""

from __future__ import annotations

import sys

# Приложение
API_DEV = 'ergo_ms_api_dev'
CLIENT_DEV = 'ergo_ms_client_dev'
MEDIA_API = 'ergo_ms_media_api'
CELERY_BEAT = 'ergo_ms_celery_beat'
CELERY_WORKER = 'ergo_ms_celery_worker'

# Portable infra
REDIS = 'ergo_ms_redis'
MEILISEARCH = 'ergo_ms_meilisearch'
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

# Точные legacy → текущие (воркеры с суффиксом — отдельно в normalize_service_name)
_LEGACY_EXACT = {
    'ergo-api-dev': API_DEV,
    'ergo-client-dev': CLIENT_DEV,
    'ergo-media-api': MEDIA_API,
    'ergo-celery-beat': CELERY_BEAT,
    'ergo-celery-worker': CELERY_WORKER,
    'ergo-redis': REDIS,
    'ergo-postgres': POSTGRES,
    'media_api': MEDIA_API,
}


def celery_worker(key: str | None = None) -> str:
    if not key:
        return CELERY_WORKER
    return f'{CELERY_WORKER}_{key}'


def is_celery_worker(name: str) -> bool:
    base = name.replace('.service', '')
    return (
        base == CELERY_WORKER
        or base.startswith(f'{CELERY_WORKER}_')
        or base == 'ergo-celery-worker'
        or base.startswith('ergo-celery-worker-')
    )


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


def normalize_service_name(name: str) -> str:
    """Привести legacy/алиас к текущему имени OS-службы (для logs/status)."""
    if not name:
        return name
    suffix = '.service' if name.endswith('.service') else ''
    base = name[:-len('.service')] if suffix else name

    if base in _LEGACY_EXACT:
        return _LEGACY_EXACT[base] + suffix

    legacy_worker = 'ergo-celery-worker-'
    if base.startswith(legacy_worker):
        key = base[len(legacy_worker):]
        return celery_worker(key) + suffix if key else CELERY_WORKER + suffix

    return name


def _cli_main() -> int:
    if len(sys.argv) < 2:
        print('usage: service_names.py normalize <name>', file=sys.stderr)
        return 1
    command = sys.argv[1]
    if command == 'normalize' and len(sys.argv) >= 3:
        print(normalize_service_name(sys.argv[2]), end='')
        return 0
    print(f'Неизвестная команда: {command}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(_cli_main())
