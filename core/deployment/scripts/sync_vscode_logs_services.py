"""Генерация runtime YAML для VS Code: логи и опциональные сервисы (nginx, client, Redis, модули)."""

from __future__ import annotations

import sys
from pathlib import Path

from deployment_env import PROJECT_ROOT, is_nginx_enabled, is_redis_enabled

_SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from cli_locale import t  # noqa: E402
from module_tasks_loader import INCLUDE_START_ALL, tasks_for_target  # noqa: E402

LOGS_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'logs-services.runtime.yaml'
OPTIONAL_SERVICES_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'optional-services.runtime.yaml'
REDIS_DEV_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'redis-dev.runtime.yaml'
CLIENT_DEV_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'client-dev.runtime.yaml'
MODULE_START_SERVICES_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'module-start-services.runtime.yaml'

LOGS_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Источник: .vscode/logs-services.yaml + ERGO_PROXY / ERGO_BROKER (или legacy NGINX_ENABLED / REDIS_ENABLED)
"""

OPTIONAL_SERVICES_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Источник: ERGO_PROXY / ERGO_BROKER из .env (порядок: Redis → client/nginx)
"""

REDIS_DEV_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Redis-терминал для Start All Services (перед API).
"""

CLIENT_DEV_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Клиент / nginx для Start All Services (после API).
"""

MODULE_START_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Модульные сервисы из vscode.tasks.yaml (include_in: start-all).
"""


def _service_block(name: str, description: str, *, command: str = '') -> str:
    lines = [f'  {name}:', f'    description: "{description}"']
    if command:
        # YAML double-quoted; escape backslash and quote
        escaped = command.replace('\\', '\\\\').replace('"', '\\"')
        lines.append(f'    command: "{escaped}"')
    return '\n'.join(lines) + '\n'


def build_logs_yaml() -> str:
    lines = [LOGS_HEADER.rstrip(), '', 'services:']
    lines.append(_service_block('ergo_ms_api_dev', 'Django API server').rstrip())
    if is_nginx_enabled():
        lines.append(_service_block('ergo_ms_nginx', 'Nginx reverse proxy').rstrip())
    else:
        lines.append(_service_block('ergo_ms_client_dev', 'Vue.js client dev server').rstrip())
    lines.append(_service_block('ergo_ms_media_api', 'Media API (CDN / file server)').rstrip())
    lines.append(_service_block('ergo_ms_celery_beat', 'Celery Beat scheduler').rstrip())
    if is_redis_enabled():
        lines.append(_service_block('ergo_ms_redis', 'Redis').rstrip())
    return '\n'.join(lines) + '\n'


def build_optional_services_yaml() -> str:
    """Совместимость: Redis первым, затем client/nginx."""
    lines = [OPTIONAL_SERVICES_HEADER.rstrip(), '', 'services:']
    if is_redis_enabled():
        lines.append(_service_block('redis', 'Redis').rstrip())
    if is_nginx_enabled():
        lines.append(_service_block('nginx', 'Nginx reverse proxy').rstrip())
    else:
        lines.append(_service_block('client', 'Vue.js client dev server').rstrip())
    return '\n'.join(lines) + '\n'


def build_redis_dev_yaml() -> str:
    lines = [REDIS_DEV_HEADER.rstrip(), '', 'services:']
    if is_redis_enabled():
        lines.append(_service_block('redis', 'Redis').rstrip())
    return '\n'.join(lines) + '\n'


def build_client_dev_yaml() -> str:
    lines = [CLIENT_DEV_HEADER.rstrip(), '', 'services:']
    if is_nginx_enabled():
        lines.append(_service_block('nginx', 'Nginx reverse proxy').rstrip())
    else:
        lines.append(_service_block('client', 'Vue.js client dev server').rstrip())
    return '\n'.join(lines) + '\n'


def build_module_start_services_yaml() -> str:
    lines = [MODULE_START_HEADER.rstrip(), '', 'services:']
    tasks = tasks_for_target(PROJECT_ROOT, INCLUDE_START_ALL)
    seen_keys: set[str] = set()
    for entry in tasks:
        key = entry.service_key
        if key in seen_keys:
            key = f'{entry.module}_{key}'
        seen_keys.add(key)
        # description → имя терминала в multi-terminal (label задачи)
        desc = entry.label.replace('"', "'")
        lines.append(
            _service_block(key, desc, command=entry.command).rstrip()
        )
        if entry.stop_command:
            # stop_command — отдельное поле для multi-terminal extension
            escaped = entry.stop_command.replace('\\', '\\\\').replace('"', '\\"')
            lines[-1] = lines[-1] + f'\n    stop_command: "{escaped}"'
    return '\n'.join(lines) + '\n'


def main() -> int:
    LOGS_RUNTIME_YAML.parent.mkdir(parents=True, exist_ok=True)
    LOGS_RUNTIME_YAML.write_text(build_logs_yaml(), encoding='utf-8')
    OPTIONAL_SERVICES_RUNTIME_YAML.write_text(build_optional_services_yaml(), encoding='utf-8')
    REDIS_DEV_RUNTIME_YAML.write_text(build_redis_dev_yaml(), encoding='utf-8')
    CLIENT_DEV_RUNTIME_YAML.write_text(build_client_dev_yaml(), encoding='utf-8')
    MODULE_START_SERVICES_RUNTIME_YAML.write_text(
        build_module_start_services_yaml(), encoding='utf-8'
    )
    mode = 'nginx' if is_nginx_enabled() else 'client'
    redis = 'redis' if is_redis_enabled() else 'no-redis'
    module_n = len(tasks_for_target(PROJECT_ROOT, INCLUDE_START_ALL))
    print(t('vscode_sync_updated', path=LOGS_RUNTIME_YAML, mode=mode, redis=redis))
    print(t('vscode_sync_updated', path=OPTIONAL_SERVICES_RUNTIME_YAML, mode=mode, redis=redis))
    print(t('vscode_sync_updated', path=REDIS_DEV_RUNTIME_YAML, mode=mode, redis=redis))
    print(t('vscode_sync_updated', path=CLIENT_DEV_RUNTIME_YAML, mode=mode, redis=redis))
    print(
        t(
            'vscode_sync_module_start',
            path=MODULE_START_SERVICES_RUNTIME_YAML,
            count=module_n,
        )
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
