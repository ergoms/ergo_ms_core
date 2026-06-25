"""
Дополняет .env для nginx-сценария: публичный IP, listen, relative API.

Вызывается из install-nginx перед генерацией конфига.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_DIR = PROJECT_ROOT / 'core' / 'deployment'
sys.path.insert(0, str(DEPLOYMENT_DIR / 'nginx'))

from detect_lan_ip import detect_lan_ip  # noqa: E402


def _read_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    result: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or '=' not in stripped:
            continue
        key, _, raw = stripped.partition('=')
        result[key.strip()] = raw.strip().strip('"').strip("'")
    return result


def _set_env_var(content: str, key: str, value: str) -> str:
    pattern = re.compile(rf'^{re.escape(key)}=.*$', re.MULTILINE)
    line = f'{key}={value}'
    if pattern.search(content):
        return pattern.sub(line, content, count=1)
    if content and not content.endswith('\n'):
        content += '\n'
    return content + line + '\n'


def _truthy(value: str) -> bool:
    return value.strip().lower() in ('1', 'true', 'yes')


def _use_https(values: dict[str, str]) -> bool:
    if _truthy(values.get('NGINX_USE_HTTPS', '')):
        return True
    return values.get('NGINX_LISTEN_PORT', '').strip() == '443'


def _default_listen_host(values: dict[str, str]) -> str:
    if _use_https(values):
        return '127.0.0.1'
    return '0.0.0.0'


def main() -> int:
    env_path = PROJECT_ROOT / '.env'
    values = _read_env(env_path)
    if not _truthy(values.get('NGINX_ENABLED', '')):
        return 0

    content = env_path.read_text(encoding='utf-8') if env_path.is_file() else ''
    changed = False

    public_host = values.get('NGINX_PUBLIC_HOST', '').strip()
    if not public_host or public_host in ('localhost', '127.0.0.1'):
        detected = detect_lan_ip()
        if detected:
            public_host = detected
            content = _set_env_var(content, 'NGINX_PUBLIC_HOST', public_host)
            changed = True

    if not values.get('NGINX_LISTEN_HOST', '').strip():
        listen_host = _default_listen_host(values)
        content = _set_env_var(content, 'NGINX_LISTEN_HOST', listen_host)
        changed = True

    server_name = values.get('NGINX_SERVER_NAME', '').strip()
    if public_host and server_name in ('', 'localhost', '127.0.0.1'):
        content = _set_env_var(content, 'NGINX_SERVER_NAME', public_host)
        changed = True

    if not _truthy(values.get('VITE_USE_RELATIVE_API', '')):
        content = _set_env_var(content, 'VITE_USE_RELATIVE_API', 'true')
        changed = True

    if not values.get('API_HOST', '').strip():
        content = _set_env_var(content, 'API_HOST', '127.0.0.1')
        changed = True

    media_host = values.get('MEDIA_API_HOST', '').strip()
    if public_host and media_host in ('', 'localhost', '127.0.0.1'):
        content = _set_env_var(content, 'MEDIA_API_HOST', public_host)
        changed = True

    if changed:
        env_path.write_text(content, encoding='utf-8')
        print(f'[ergoms] .env updated for nginx (public host: {public_host or "localhost"})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
