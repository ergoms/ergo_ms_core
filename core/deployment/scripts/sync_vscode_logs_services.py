"""Генерация .vscode/logs-services.runtime.yaml с учётом NGINX_ENABLED."""

from __future__ import annotations

from pathlib import Path

from deployment_env import PROJECT_ROOT, is_nginx_enabled

RUNTIME_YAML = PROJECT_ROOT / '.vscode' / 'logs-services.runtime.yaml'

BASE_HEADER = """# Сгенерировано sync_vscode_logs_services.py — не редактировать вручную.
# Источник: .vscode/logs-services.yaml + NGINX_ENABLED из .env
"""


def _service_block(name: str, description: str) -> str:
    return f'  {name}:\n    description: "{description}"\n'


def build_yaml() -> str:
    lines = [BASE_HEADER.rstrip(), '', 'services:']
    lines.append(_service_block('ergo-api-dev', 'Django API server').rstrip())
    if is_nginx_enabled():
        lines.append(_service_block('ergo_ms_nginx', 'Nginx reverse proxy').rstrip())
    else:
        lines.append(_service_block('ergo-client-dev', 'Vue.js client dev server').rstrip())
    lines.append(_service_block('ergo-media-api', 'Media API (CDN / file server)').rstrip())
    lines.append(_service_block('ergo-celery-beat', 'Celery Beat scheduler').rstrip())
    lines.append(_service_block('ergo-redis', 'Redis (optional)').rstrip())
    return '\n'.join(lines) + '\n'


def main() -> int:
    RUNTIME_YAML.parent.mkdir(parents=True, exist_ok=True)
    RUNTIME_YAML.write_text(build_yaml(), encoding='utf-8')
    mode = 'nginx' if is_nginx_enabled() else 'client'
    print(f'[ergoms] Updated {RUNTIME_YAML} (mode: {mode})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
