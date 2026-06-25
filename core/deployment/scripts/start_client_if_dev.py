"""
Запуск Vite dev-сервера только если NGINX_ENABLED=false.

При nginx-сценарии клиент отдаётся из dist через nginx; :8001 не нужен.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
CLIENT_DIR = PROJECT_ROOT / 'core' / 'client'
DEPLOYMENT_NGINX = PROJECT_ROOT / 'core' / 'deployment' / 'nginx'


def _read_env(name: str, default: str = '') -> str:
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


def _resolve_public_host() -> str:
    explicit = _read_env('NGINX_PUBLIC_HOST')
    if explicit:
        return explicit

    server_name = _read_env('NGINX_SERVER_NAME', 'localhost')
    if server_name not in ('', 'localhost', '127.0.0.1'):
        return server_name

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


def main() -> int:
    if _read_env('NGINX_ENABLED', 'false').lower() in ('1', 'true', 'yes'):
        public_host = _resolve_public_host()
        port = _read_env('NGINX_LISTEN_PORT', '80')
        print('[ergoms] NGINX_ENABLED=true — Vite dev (:8001) is skipped.')
        print(f'[ergoms] Open http://{public_host}' + (f':{port}' if port not in ('80', '443') else ''))
        print('[ergoms] After UI changes: ergoms client-build && ergoms reload-nginx')
        return 0

    npm_cmd = 'npm.cmd' if os.name == 'nt' else 'npm'
    return subprocess.call([npm_cmd, 'run', 'dev'], cwd=str(CLIENT_DIR))


if __name__ == '__main__':
    raise SystemExit(main())
