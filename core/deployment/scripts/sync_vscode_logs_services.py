"""Генерация runtime YAML для VS Code: логи и опциональные сервисы (nginx, client, Redis)."""

from __future__ import annotations

from pathlib import Path

from deployment_env import PROJECT_ROOT, is_nginx_enabled, is_redis_enabled

LOGS_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'logs-services.runtime.yaml'
OPTIONAL_SERVICES_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'optional-services.runtime.yaml'
REDIS_DEV_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'redis-dev.runtime.yaml'
CLIENT_DEV_RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'client-dev.runtime.yaml'

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


def _service_block(name: str, description: str) -> str:
    return f'  {name}:\n    description: "{description}"\n'


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


def main() -> int:
    LOGS_RUNTIME_YAML.parent.mkdir(parents=True, exist_ok=True)
    LOGS_RUNTIME_YAML.write_text(build_logs_yaml(), encoding='utf-8')
    OPTIONAL_SERVICES_RUNTIME_YAML.write_text(build_optional_services_yaml(), encoding='utf-8')
    REDIS_DEV_RUNTIME_YAML.write_text(build_redis_dev_yaml(), encoding='utf-8')
    CLIENT_DEV_RUNTIME_YAML.write_text(build_client_dev_yaml(), encoding='utf-8')
    mode = 'nginx' if is_nginx_enabled() else 'client'
    redis = 'redis' if is_redis_enabled() else 'no-redis'
    print(f'[ergoms] Updated {LOGS_RUNTIME_YAML} (mode: {mode}, {redis})')
    print(f'[ergoms] Updated {OPTIONAL_SERVICES_RUNTIME_YAML} (mode: {mode}, {redis})')
    print(f'[ergoms] Updated {REDIS_DEV_RUNTIME_YAML} ({redis})')
    print(f'[ergoms] Updated {CLIENT_DEV_RUNTIME_YAML} (mode: {mode})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
