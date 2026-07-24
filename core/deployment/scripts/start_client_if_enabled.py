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
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from deployment_env import is_nginx_enabled  # noqa: E402
from log_env import client_dev_log_level  # noqa: E402
from project_layout import nodejs_bin_dir, npm_exe, npm_root_dir  # noqa: E402


def main() -> int:
    if is_nginx_enabled():
        return 0

    npm_cmd = str(npm_exe(PROJECT_ROOT))
    if not Path(npm_cmd).is_file():
        npm_cmd = 'npm.cmd' if os.name == 'nt' else 'npm'

    npm_root = npm_root_dir(PROJECT_ROOT)
    env = os.environ.copy()
    node_bin = nodejs_bin_dir(PROJECT_ROOT)
    npm_bin_modules = npm_root / 'node_modules' / '.bin'
    sep = ';' if os.name == 'nt' else ':'
    path_parts = []
    if node_bin.is_dir():
        path_parts.append(str(node_bin))
    if npm_bin_modules.is_dir():
        path_parts.append(str(npm_bin_modules))
    if path_parts:
        env['PATH'] = sep.join(path_parts + [env.get('PATH', '')])

    log_level = client_dev_log_level()
    return subprocess.call(
        [
            npm_cmd,
            'run',
            'dev',
            '-w',
            '@ergo-ms/core-client',
            '--',
            '--logLevel',
            log_level,
        ],
        cwd=str(npm_root),
        env=env,
    )


if __name__ == '__main__':
    raise SystemExit(main())
