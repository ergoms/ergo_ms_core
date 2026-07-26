"""
Остановка portable nginx после закрытия терминала VS Code (stop-nginx-dev).

Службу ОС не трогает. При NGINX_ENABLED=false — тихий выход.
Marker не обязателен (на Windows atexit при закрытии терминала часто не срабатывает).
"""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from deployment_env import PROJECT_ROOT, is_nginx_enabled  # noqa: E402
from nginx_dev import (  # noqa: E402
    clear_dev_session_marker,
    is_nginx_managed_service,
    stop_nginx_for_dev,
)
from nginx_foreground import _configure_stdio_utf8  # noqa: E402


def main() -> int:
    if not is_nginx_enabled():
        return 0

    _configure_stdio_utf8()

    if is_nginx_managed_service(PROJECT_ROOT):
        return 0

    stop_nginx_for_dev(PROJECT_ROOT)
    clear_dev_session_marker(PROJECT_ROOT)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
