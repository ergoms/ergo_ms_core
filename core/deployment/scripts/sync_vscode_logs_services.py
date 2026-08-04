"""Генерация runtime YAML для VS Code: логи и опциональные сервисы (nginx, client, Redis, модули)."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import yaml

from deployment_env import PROJECT_ROOT, is_nginx_enabled, is_redis_enabled

_SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from cli_locale import t  # noqa: E402
from module_tasks_loader import (  # noqa: E402
    INCLUDE_LOGS_ALL,
    INCLUDE_START_ALL,
    tasks_for_target,
)
from service_names import celery_worker  # noqa: E402

LOGS_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'logs-services.runtime.yaml'
LOGS_ALL_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'logs-all.runtime.yaml'
OPTIONAL_SERVICES_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'optional-services.runtime.yaml'
REDIS_DEV_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'redis-dev.runtime.yaml'
CLIENT_DEV_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'client-dev.runtime.yaml'
MODULE_START_SERVICES_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'module-start-services.runtime.yaml'
MODULE_LOGS_SERVICES_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'module-logs-services.runtime.yaml'

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

MODULE_LOGS_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Модульные логи из vscode.tasks.yaml (include_in: logs-all).
"""

LOGS_ALL_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Единый список для Logs: All Services (полные command — не зависят от шаблона tasks.json).
"""


def _service_block(name: str, description: str, *, command: str = '') -> str:
    lines = [f'  {name}:', f'    description: "{description}"']
    if command:
        # YAML double-quoted; escape backslash and quote
        escaped = command.replace('\\', '\\\\').replace('"', '\\"')
        lines.append(f'    command: "{escaped}"')
    return '\n'.join(lines) + '\n'


def _core_log_services(*, with_commands: bool) -> list[tuple[str, str, str]]:
    """Список (key, description, command) ядра для логов."""
    items: list[tuple[str, str, str]] = [
        ('ergo_ms_api_dev', 'Django API server', 'ergoms logs ergo_ms_api_dev 500'),
    ]
    if is_nginx_enabled():
        items.append(
            ('ergo_ms_nginx', 'Nginx reverse proxy', 'ergoms logs ergo_ms_nginx 500')
        )
    else:
        items.append(
            (
                'ergo_ms_client_dev',
                'Vue.js client dev server',
                'ergoms logs ergo_ms_client_dev 500',
            )
        )
    items.append(
        ('ergo_ms_media_api', 'Media API (CDN / file server)', 'ergoms logs ergo_ms_media_api 500')
    )
    items.append(
        ('ergo_ms_celery_beat', 'Celery Beat scheduler', 'ergoms logs ergo_ms_celery_beat 500')
    )
    if is_redis_enabled():
        items.append(('ergo_ms_redis', 'Redis', 'ergoms logs ergo_ms_redis 500'))
    if not with_commands:
        return [(key, desc, '') for key, desc, _cmd in items]
    return items


def _celery_worker_keys() -> list[str]:
    path = PROJECT_ROOT / 'celery_workers.yaml'
    if not path.is_file():
        return ['all']
    try:
        data: Any = yaml.safe_load(path.read_text(encoding='utf-8')) or {}
    except (OSError, yaml.YAMLError):
        return ['all']
    workers = data.get('workers') or {}
    if not isinstance(workers, dict) or not workers:
        return ['all']
    return [str(key) for key in workers]


def build_logs_yaml() -> str:
    lines = [LOGS_HEADER.rstrip(), '', 'services:']
    for key, desc, _cmd in _core_log_services(with_commands=False):
        lines.append(_service_block(key, desc).rstrip())
    return '\n'.join(lines) + '\n'


def build_logs_all_yaml() -> str:
    """Полный список логов с command — устойчив к устаревшему commandTemplate в tasks.json."""
    lines = [LOGS_ALL_HEADER.rstrip(), '', 'services:']
    for key, desc, command in _core_log_services(with_commands=True):
        lines.append(_service_block(key, desc, command=command).rstrip())
    for worker_key in _celery_worker_keys():
        unit = celery_worker(worker_key)
        lines.append(
            _service_block(
                unit,
                f'Celery Worker-{worker_key}',
                command=f'ergoms logs {unit} 500',
            ).rstrip()
        )
    seen_keys: set[str] = set()
    for entry in tasks_for_target(PROJECT_ROOT, INCLUDE_LOGS_ALL):
        key = entry.service_key
        if key in seen_keys:
            key = f'{entry.module}_{key}'
        seen_keys.add(key)
        desc = entry.label.replace('"', "'")
        lines.append(_service_block(key, desc, command=entry.command).rstrip())
        if entry.stop_command:
            escaped = entry.stop_command.replace('\\', '\\\\').replace('"', '\\"')
            lines[-1] = lines[-1] + f'\n    stop_command: "{escaped}"'
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


def _build_module_services_yaml(header: str, include_target: str) -> str:
    lines = [header.rstrip(), '', 'services:']
    tasks = tasks_for_target(PROJECT_ROOT, include_target)
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


def build_module_start_services_yaml() -> str:
    return _build_module_services_yaml(MODULE_START_HEADER, INCLUDE_START_ALL)


def build_module_logs_services_yaml() -> str:
    return _build_module_services_yaml(MODULE_LOGS_HEADER, INCLUDE_LOGS_ALL)


def main() -> int:
    LOGS_RUNTIME_YAML.parent.mkdir(parents=True, exist_ok=True)
    LOGS_RUNTIME_YAML.write_text(build_logs_yaml(), encoding='utf-8')
    LOGS_ALL_RUNTIME_YAML.write_text(build_logs_all_yaml(), encoding='utf-8')
    OPTIONAL_SERVICES_RUNTIME_YAML.write_text(build_optional_services_yaml(), encoding='utf-8')
    REDIS_DEV_RUNTIME_YAML.write_text(build_redis_dev_yaml(), encoding='utf-8')
    CLIENT_DEV_RUNTIME_YAML.write_text(build_client_dev_yaml(), encoding='utf-8')
    MODULE_START_SERVICES_RUNTIME_YAML.write_text(
        build_module_start_services_yaml(), encoding='utf-8'
    )
    MODULE_LOGS_SERVICES_RUNTIME_YAML.write_text(
        build_module_logs_services_yaml(), encoding='utf-8'
    )
    mode = 'nginx' if is_nginx_enabled() else 'client'
    redis = 'redis' if is_redis_enabled() else 'no-redis'
    module_n = len(tasks_for_target(PROJECT_ROOT, INCLUDE_START_ALL))
    module_logs_n = len(tasks_for_target(PROJECT_ROOT, INCLUDE_LOGS_ALL))
    logs_all_n = (
        len(_core_log_services(with_commands=True))
        + len(_celery_worker_keys())
        + module_logs_n
    )
    print(t('vscode_sync_updated', path=LOGS_RUNTIME_YAML, mode=mode, redis=redis))
    print(
        t(
            'vscode_sync_logs_all',
            path=LOGS_ALL_RUNTIME_YAML,
            count=logs_all_n,
            mode=mode,
            redis=redis,
        )
    )
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
    print(
        t(
            'vscode_sync_module_logs',
            path=MODULE_LOGS_SERVICES_RUNTIME_YAML,
            count=module_logs_n,
        )
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
