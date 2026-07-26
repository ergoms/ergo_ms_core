"""
Запуск Vite dev-сервера или nginx в foreground.

При NGINX_ENABLED=true клиент отдаётся через nginx; Vite (:8001) не нужен.
Закрытие терминала или Ctrl+C останавливает nginx сессии разработки.
"""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(DEPLOYMENT_DIR))

from deployment_env import is_nginx_enabled  # noqa: E402
from nginx_dev import run_nginx_foreground  # noqa: E402
from start_client_vite import run_vite_dev  # noqa: E402


def main() -> int:
    if is_nginx_enabled():
        return run_nginx_foreground()
    return run_vite_dev()


if __name__ == '__main__':
    raise SystemExit(main())
