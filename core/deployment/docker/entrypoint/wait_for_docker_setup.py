#!/usr/bin/env python3
"""
Ожидание завершения первичной установки Docker (ergoms docker-init / bootstrap up).

Сервисы с ERGO_DOCKER_REQUIRES_SETUP=1 не запускают основной процесс, пока нет маркера.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path


def _deployment_dir() -> Path:
    mounted = Path('/app/core/deployment')
    if (mounted / 'cli_locale.py').is_file():
        return mounted
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / 'cli_locale.py').is_file():
            return parent
    return mounted


_DEPLOYMENT_DIR = _deployment_dir()
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import t  # noqa: E402

MARKER = Path(os.environ.get('ERGO_DOCKER_SETUP_MARKER', '/app/logs/.ergo-docker-setup-ok'))
POLL_SEC = float(os.environ.get('ERGO_DOCKER_SETUP_POLL_SEC', '5'))


def _truthy(name: str) -> bool:
    value = os.environ.get(name, '').strip().lower()
    return value in ('1', 'true', 'yes', 'on')


def main() -> int:
    if not _truthy('ERGO_DOCKER_REQUIRES_SETUP'):
        return 0

    if MARKER.is_file():
        return 0

    print(t('wait_docker_setup'), flush=True)
    while not MARKER.is_file():
        time.sleep(POLL_SEC)
    print(t('wait_docker_setup_done'), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
