"""Каталог служб ERGO MS."""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parents[2] / 'scripts'
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from service_names import (  # noqa: E402
    API_DEV,
    CELERY_BEAT,
    CLIENT_DEV,
    MEDIA_API,
    celery_worker,
)

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
        return [ServiceEntry('worker-all', celery_worker('all'), 'install-workers')]
    try:
        import yaml  # noqa: WPS433

        data = yaml.safe_load(path.read_text(encoding='utf-8')) or {}
        workers = data.get('workers') or {}
        entries: list[ServiceEntry] = []
        for key in workers:
            entries.append(
                ServiceEntry(
                    f'worker-{key}',
                    celery_worker(str(key)),
                    'install-workers',
                )
            )
        return entries or [ServiceEntry('worker-all', celery_worker('all'), 'install-workers')]
    except Exception:
        return [ServiceEntry('worker-all', celery_worker('all'), 'install-workers')]


def list_core_services() -> list[ServiceEntry]:
    return [
        ServiceEntry('api', API_DEV, 'install-api'),
        ServiceEntry('client', CLIENT_DEV, 'install-client', optional=True),
        ServiceEntry('media', MEDIA_API, 'install-media'),
        ServiceEntry('beat', CELERY_BEAT, 'install-beat'),
    ]


def resolve_service_catalog(project_root: Path, disabled_modules: set[str]) -> list[ServiceEntry]:
    catalog = list_core_services()
    catalog.extend(_load_workers(project_root))
    return catalog
