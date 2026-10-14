"""Стек Swarm для воркеров Celery. Файл генерируется, в git не входит."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

DOCKER_DIR = Path(__file__).resolve().parent
DEPLOYMENT_DIR = DOCKER_DIR.parent
PROJECT_ROOT = DEPLOYMENT_DIR.parent.parent
OUTPUT = DOCKER_DIR / 'docker-stack.workers.generated.yml'

if str(DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(DEPLOYMENT_DIR))

from cli_locale import t  # noqa: E402


def render_stack(
    *,
    image: str,
    manager_host: str,
    databases_file: str,
    env_file: str,
    gpu: bool,
    media_url: str = '',
    ollama_url: str = '',
) -> str:
    gpu_block = ''
    if gpu:
        gpu_block = """
      resources:
        reservations:
          generic_resources:
            - discrete_resource_spec:
                kind: NVIDIA-GPU
                value: 1
"""
    remote_env = ''
    if media_url:
        remote_env += (
            '      ERGO_MEDIA: remote\n'
            f'      MEDIA_API_INTERNAL_URL: "{media_url}"\n'
        )
    if ollama_url:
        remote_env += f'      OLLAMA_BASE_URL: "{ollama_url}"\n'
    service_configs = """    configs:
      - source: ergo_dotenv
        target: /app/.env
      - source: ergo_databases
        target: /app/databases.yaml
"""
    return f"""# Автогенерация: ergoms docker-swarm-deploy (не редактировать вручную)
services:
  ergo-celery-agent:
    image: {image}
    environment:
      CELERY_CLUSTER: "on"
      CELERY_CLUSTER_ROLE: agent
      ERGO_NODE_ID: "{{{{.Node.Hostname}}}}"
      DOCKER_ENABLED: "true"
      ERGO_BROKER: redis
      REDIS_HOST: {manager_host}
      ERGO_DOCKER_DB_HOST: {manager_host}
      DOCKER_DATABASE: container
      DOCKER_PROFILE_POSTGRES: "true"
      ERGO_DATABASES_YAML: /app/databases.yaml
{service_configs}    command: ["python", "core/deployment/celery_balance/cli.py", "--watch"]
    deploy:
      mode: global
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.labels.ergo.worker == true
  ergo-celery-worker:
    image: {image}
    environment:
      CELERY_CLUSTER: "on"
      CELERY_CLUSTER_ROLE: agent
      ERGO_NODE_ID: "{{{{.Node.Hostname}}}}"
      DOCKER_ENABLED: "true"
      ERGO_BROKER: redis
      REDIS_HOST: {manager_host}
      ERGO_DOCKER_DB_HOST: {manager_host}
      DOCKER_DATABASE: container
      DOCKER_PROFILE_POSTGRES: "true"
      ERGO_DATABASES_YAML: /app/databases.yaml
      NVIDIA_VISIBLE_DEVICES: all
{remote_env}{service_configs}    command: ["sh", "-c", "if [ -f /app/core/deployment/scripts/prepare_swarm_packages.py ]; then python /app/core/deployment/scripts/prepare_swarm_packages.py || exit 1; fi; exec python /app/core/api/scripts/start_celery_worker.py"]
    networks:
      - host
    volumes:
      - ergo_worker_cache:/app/virtual_env/cache
      - ergo_worker_packages:/app/virtual_env/packages
      - /var/run/docker.sock:/var/run/docker.sock
    stop_grace_period: 60s
    deploy:
      mode: global
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.labels.ergo.worker == true
{gpu_block}networks:
  host:
    external: true
    name: host
volumes:
  ergo_worker_cache:
  ergo_worker_packages:
configs:
  ergo_dotenv:
    file: {env_file}
  ergo_databases:
    file: {databases_file}
"""


def main() -> int:
    parser = argparse.ArgumentParser(description='Generate Swarm worker stack')
    parser.add_argument('--output', type=Path, default=OUTPUT)
    parser.add_argument('--image', required=True)
    parser.add_argument('--manager-host', required=True)
    parser.add_argument('--databases-file', required=True)
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--gpu', action='store_true')
    parser.add_argument('--media-url', default='')
    parser.add_argument('--ollama-url', default='')
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args()
    content = render_stack(
        image=args.image,
        manager_host=args.manager_host,
        databases_file=args.databases_file,
        env_file=args.env_file,
        gpu=args.gpu,
        media_url=args.media_url,
        ollama_url=args.ollama_url,
    )
    args.output.write_text(content, encoding='utf-8')
    if not args.quiet:
        print(t('docker_swarm_stack_written', output=args.output))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
