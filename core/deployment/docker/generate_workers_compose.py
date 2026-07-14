"""
Генерация docker-compose.workers.generated.yml из celery_workers.yaml.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import yaml

DOCKER_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = DOCKER_DIR.parent.parent.parent
WORKERS_CONFIG = PROJECT_ROOT / 'celery_workers.yaml'
WORKERS_EXAMPLE = PROJECT_ROOT / 'celery_workers.yaml.example'
OUTPUT = DOCKER_DIR / 'docker-compose.workers.generated.yml'

# Дублирует x-python-volumes из docker-compose.yml (якоря не работают между -f файлами).
PYTHON_VOLUMES_YAML = """    volumes:
      - ${ERGO_PROJECT_ROOT:-../../..}:/app
      - ./.compose.databases.yaml:/app/databases.yaml:ro
      - ${ERGO_LOGS_BIND:-../../../logs}:/app/logs
      - ${ERGO_MEDIA_BIND:-../../../media}:/app/media
      - celery_cache:/app/virtual_env/cache
      - poetry_venv:/app/virtual_env/python"""

PYTHON_SERVICE_TEMPLATE = """
  celery-worker-{name}:
    image: ${{DOCKER_PYTHON_IMAGE:-ergo_ms-python:local}}
    env_file:
      - .compose.env
{volumes}
    depends_on:
      redis:
        condition: service_started
      api:
        condition: service_started
    networks:
      - ergo_net
    command: ["python", "core/api/scripts/start_celery_worker.py", "--worker={worker_key}"]
    restart: unless-stopped
"""


def load_workers_config() -> dict[str, Any]:
    path = WORKERS_CONFIG if WORKERS_CONFIG.is_file() else WORKERS_EXAMPLE
    if not path.is_file():
        return {}
    with open(path, encoding='utf-8') as handle:
        data = yaml.safe_load(handle) or {}
    return data.get('workers') or {}


def generate(workers: dict[str, Any]) -> str:
    header = """# Автогенерация: ergoms docker-gen-workers (не редактировать вручную)
services:
"""
    if not workers:
        body = "  {}\n"
        return header + body

    blocks = []
    for name in workers:
        safe = ''.join(ch if ch.isalnum() or ch in '-_' else '-' for ch in name)
        blocks.append(
            PYTHON_SERVICE_TEMPLATE.format(
                name=safe,
                worker_key=name,
                volumes=PYTHON_VOLUMES_YAML,
            )
        )
    return header + '\n'.join(blocks)


def main() -> int:
    parser = argparse.ArgumentParser(description='Generate docker-compose workers fragment')
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()

    workers = load_workers_config()
    content = generate(workers)
    args.output.write_text(content, encoding='utf-8')
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    print(f'[OK] Сгенерировано worker-сервисов: {len(workers)} -> {args.output}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
