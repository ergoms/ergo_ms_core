"""Чтение переменных развёртывания из .env без Django."""

from __future__ import annotations

import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_NGINX = PROJECT_ROOT / 'core' / 'deployment' / 'nginx'


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
