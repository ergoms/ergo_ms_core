"""Чтение переменных развёртывания из .env без Django."""

from __future__ import annotations

import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_NGINX = PROJECT_ROOT / 'core' / 'deployment' / 'nginx'
_HOST_LOOPBACK = '127.0.0.1'


def running_in_container() -> bool:
    if Path('/.dockerenv').is_file():
        return True
    cgroup = Path('/proc/self/cgroup')
    if cgroup.is_file():
        try:
            return 'docker' in cgroup.read_text(encoding='utf-8', errors='ignore')
        except OSError:
            pass
    return False


def effective_redis_host() -> str:
    """Хост Redis для portable Redis на хосте (имя compose-сервиса → 127.0.0.1)."""
    host = read_env('REDIS_HOST', _HOST_LOOPBACK).strip() or _HOST_LOOPBACK
    service = read_env('DOCKER_SERVICE_REDIS', 'redis').strip().lower() or 'redis'
    if not running_in_container() and host.lower() in {service, 'redis'}:
        return _HOST_LOOPBACK
    return host


def effective_redis_port() -> int:
    raw = read_env('REDIS_PORT', '6379').strip() or '6379'
    try:
        return int(raw)
    except ValueError:
        return 6379


def read_env(name: str, default: str = '') -> str:
    value = os.environ.get(name)
    if value is not None and str(value).strip() != '':
        return str(value).strip()
    env_path = PROJECT_ROOT / '.env'
    if not env_path.is_file():
        return default
    for line in env_path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, raw = line.partition('=')
        if key.strip() == name:
            return raw.strip().strip('"').strip("'")
    return default


def is_nginx_enabled() -> bool:
    return read_env('NGINX_ENABLED', 'false').lower() in ('1', 'true', 'yes')


def is_redis_enabled() -> bool:
    return read_env('REDIS_ENABLED', 'false').lower() in ('1', 'true', 'yes')


def _env_truthy(name: str, default: str = 'false') -> bool:
    return read_env(name, default).lower() in ('1', 'true', 'yes', 'on')


def is_portable_python_enabled() -> bool:
    """Ставить portable Python в virtual_env при setup-full (по умолчанию да)."""
    return _env_truthy('PORTABLE_PYTHON_ENABLED', 'true')


def is_portable_nodejs_enabled() -> bool:
    """Ставить portable Node.js в virtual_env при setup-full (по умолчанию да)."""
    return _env_truthy('PORTABLE_NODEJS_ENABLED', 'true')


def resolve_public_host() -> str:
    explicit = read_env('NGINX_PUBLIC_HOST')
    if explicit:
        return explicit

    server_name = read_env('NGINX_SERVER_NAME', 'localhost')
    if server_name not in ('', 'localhost', '127.0.0.1'):
        return server_name

    import sys

    sys.path.insert(0, str(DEPLOYMENT_NGINX))
    try:
        from detect_lan_ip import detect_lan_ip  # noqa: WPS433
        detected = detect_lan_ip()
        if detected:
            return detected
    finally:
        if str(DEPLOYMENT_NGINX) in sys.path:
            sys.path.remove(str(DEPLOYMENT_NGINX))

    return 'localhost'


def is_postgres_force_install() -> bool:
    """POSTGRES_FORCE_INSTALL=true — portable даже при системной службе."""
    return read_env('POSTGRES_FORCE_INSTALL', 'false').lower() in ('1', 'true', 'yes')
