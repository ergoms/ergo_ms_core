"""
Дополняет .env для Redis-сценария: URL кэша и channel layer.

Вызывается из install-redis перед генерацией конфига и при REDIS_ENABLED=true.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]


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


def _redis_url(host: str, port: str, db: str) -> str:
    return f'redis://{host}:{port}/{db}'


def sync_redis_env(
    *,
    env_path: Path | None = None,
    configure: bool = False,
) -> bool:
    """Синхронизирует .env. Возвращает True, если файл изменён."""
    env_path = env_path or (PROJECT_ROOT / '.env')
    values = _read_env(env_path)
    if configure:
        values['REDIS_ENABLED'] = 'true'

    if not _truthy(values.get('REDIS_ENABLED', '')):
        return False

    content = env_path.read_text(encoding='utf-8') if env_path.is_file() else ''
    changed = False

    host = values.get('REDIS_HOST', '').strip() or '127.0.0.1'
    port = values.get('REDIS_PORT', '').strip() or '6379'
    db_cache = values.get('REDIS_DB_CACHE', '').strip() or '1'
    db_channel = values.get('REDIS_DB_CHANNEL', '').strip() or '0'

    updates = {
        'REDIS_ENABLED': 'true',
        'REDIS_HOST': host,
        'REDIS_PORT': port,
        'REDIS_DB_CACHE': db_cache,
        'REDIS_DB_CHANNEL': db_channel,
        'API_CACHE_BACKEND': 'redis',
        'API_CACHE_REDIS_URL': _redis_url(host, port, db_cache),
        'CHANNEL_LAYER_BACKEND': 'redis',
        'CHANNEL_LAYER_REDIS_URL': _redis_url(host, port, db_channel),
    }

    for key, value in updates.items():
        if values.get(key, '').strip() != value:
            content = _set_env_var(content, key, value)
            changed = True

    if changed:
        env_path.write_text(content, encoding='utf-8')
        print(f'[ergoms] .env updated for Redis ({host}:{port})')
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description='Sync .env for Redis scenario')
    parser.add_argument(
        '--configure',
        action='store_true',
        help='Set REDIS_ENABLED=true and sync cache/channel URLs',
    )
    args = parser.parse_args()
    sync_redis_env(configure=args.configure)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
