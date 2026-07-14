"""
Запуск Vite dev-сервера для VS Code / ergoms start-client-dev.

При NGINX_ENABLED=false: npm run dev.
При NGINX_ENABLED=true: выход без сообщений (клиент отдаётся через nginx).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from deployment_env import is_nginx_enabled  # noqa: E402
from log_env import client_dev_log_level  # noqa: E402

CLIENT_DIR = Path(__file__).resolve().parents[2] / 'client'


def main() -> int:
    if is_nginx_enabled():
        return 0

    npm_cmd = 'npm.cmd' if os.name == 'nt' else 'npm'
    log_level = client_dev_log_level()
    return subprocess.call(
        [npm_cmd, 'run', 'dev', '--', '--logLevel', log_level],
        cwd=str(CLIENT_DIR),
    )


if __name__ == '__main__':
    raise SystemExit(main())
