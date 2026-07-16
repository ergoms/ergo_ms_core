"""Каталог служб ERGO MS."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

CORE_SERVICE_IDS = ('api', 'client', 'media', 'beat')


@dataclass(frozen=True)
class ServiceEntry:
    service_id: str
    unit_name: str
    install_op: str
    optional: bool = False


def _load_workers(project_root: Path) -> list[ServiceEntry]:
    path = project_root / 'celery_workers.yaml'
    if not path.is_file():
        return [ServiceEntry('worker-all', 'ergo-celery-worker-all', 'install-workers')]
    try:
        import yaml  # noqa: WPS433

        data = yaml.safe_load(path.read_text(encoding='utf-8')) or {}
        workers = data.get('workers') or {}
        entries: list[ServiceEntry] = []
        for key in workers:
            entries.append(
                ServiceEntry(
                    f'worker-{key}',
                    f'ergo-celery-worker-{key}',
                    'install-workers',
                )
            )
        return entries or [ServiceEntry('worker-all', 'ergo-celery-worker-all', 'install-workers')]
    except Exception:
        return [ServiceEntry('worker-all', 'ergo-celery-worker-all', 'install-workers')]


def list_core_services() -> list[ServiceEntry]:
    return [
        ServiceEntry('api', 'ergo-api-dev', 'install-api'),
        ServiceEntry('client', 'ergo-client-dev', 'install-client', optional=True),
        ServiceEntry('media', 'ergo-media-api', 'install-media'),
        ServiceEntry('beat', 'ergo-celery-beat', 'install-beat'),
    ]


def resolve_service_catalog(project_root: Path, disabled_modules: set[str]) -> list[ServiceEntry]:
    catalog = list_core_services()
    if 'ollama_framework' in disabled_modules:
        pass
    catalog.extend(_load_workers(project_root))
    return catalog
