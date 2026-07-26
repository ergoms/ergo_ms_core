"""
Ожидание GET /api/system/ready/ перед запуском клиента или nginx в dev.
"""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPTS_DIR.parents[2]
API_SCRIPTS = PROJECT_ROOT / 'core' / 'api' / 'scripts'

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(API_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(API_SCRIPTS))

from deployment_env import read_env  # noqa: E402
from nginx_foreground import _configure_stdio_utf8  # noqa: E402
from warmup_api_runtime import wait_until_api_ready  # noqa: E402


def _ready_url() -> str:
    host = read_env('API_HOST', '127.0.0.1') or '127.0.0.1'
    if host in ('0.0.0.0', '::', '[::]'):
        host = '127.0.0.1'
    port = read_env('API_PORT', '8000') or '8000'
    return f'http://{host}:{port}/api/system/ready/'


def wait_for_api_ready() -> int:
    """0 — API готов или ожидание пропущено; 1 — таймаут (клиент всё равно стартует)."""
    _configure_stdio_utf8()
    return wait_until_api_ready(url=_ready_url())


def main() -> int:
    return wait_for_api_ready()


if __name__ == '__main__':
    raise SystemExit(main())
