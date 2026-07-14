"""
Запуск nginx в foreground для VS Code / ergoms start-nginx-dev.

При NGINX_ENABLED=true: nginx и потоковый вывод логов.
При NGINX_ENABLED=false: выход без сообщений.
"""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from deployment_env import is_nginx_enabled  # noqa: E402
from nginx_dev import run_nginx_foreground  # noqa: E402


def main() -> int:
    if not is_nginx_enabled():
        return 0
    return run_nginx_foreground()


if __name__ == '__main__':
    raise SystemExit(main())
