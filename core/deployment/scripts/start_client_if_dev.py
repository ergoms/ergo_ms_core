"""
Запуск Vite dev-сервера или nginx в foreground.

При NGINX_ENABLED=true клиент отдаётся через nginx; Vite (:8001) не нужен.
Закрытие терминала или Ctrl+C останавливает nginx сессии разработки.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

CLIENT_DIR = Path(__file__).resolve().parents[2] / 'client'
SCRIPTS_DIR = Path(__file__).resolve().parent
DEPLOYMENT_DIR = SCRIPTS_DIR.parent
PROJECT_ROOT = DEPLOYMENT_DIR.parent.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(DEPLOYMENT_DIR))

from deployment_env import is_nginx_enabled  # noqa: E402
from log_env import client_dev_log_level  # noqa: E402
from nginx_dev import run_nginx_foreground  # noqa: E402
from project_layout import nodejs_bin_dir, npm_exe  # noqa: E402


def main() -> int:
    if is_nginx_enabled():
        return run_nginx_foreground()

    npm_cmd = str(npm_exe(PROJECT_ROOT))
    if not Path(npm_cmd).is_file():
        npm_cmd = 'npm.cmd' if os.name == 'nt' else 'npm'

    env = os.environ.copy()
    node_bin = nodejs_bin_dir(PROJECT_ROOT)
    if node_bin.is_dir():
        sep = ';' if os.name == 'nt' else ':'
        env['PATH'] = f'{node_bin}{sep}{env.get("PATH", "")}'

    log_level = client_dev_log_level()
    return subprocess.call(
        [npm_cmd, 'run', 'dev', '--', '--logLevel', log_level],
        cwd=str(CLIENT_DIR),
        env=env,
    )


if __name__ == '__main__':
    raise SystemExit(main())
