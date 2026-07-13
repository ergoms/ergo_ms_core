"""
Запуск Vite dev-сервера или nginx в foreground.

При NGINX_ENABLED=true клиент отдаётся через nginx; Vite (:8001) не нужен.
В VS Code / ergoms start-all в этом слоте запускается nginx в терминале.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from deployment_env import is_nginx_enabled
from nginx_foreground import run_nginx_foreground

CLIENT_DIR = Path(__file__).resolve().parents[2] / 'client'
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from log_env import client_dev_log_level  # noqa: E402


def main() -> int:
    if is_nginx_enabled():
        return run_nginx_foreground()

    npm_cmd = 'npm.cmd' if os.name == 'nt' else 'npm'
    log_level = client_dev_log_level()
    return subprocess.call(
        [npm_cmd, 'run', 'dev', '--', '--logLevel', log_level],
        cwd=str(CLIENT_DIR),
    )


if __name__ == '__main__':
    raise SystemExit(main())
