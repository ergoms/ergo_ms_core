"""
Остановка portable Redis после закрытия терминала VS Code (stop-redis-dev).

Службу ОС не трогает. При REDIS_ENABLED=false — тихий выход.
Marker не обязателен: на Windows при закрытии терминала atexit часто не успевает
очистить marker, а Redis остаётся запущенным.
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

from deployment_env import PROJECT_ROOT, is_redis_enabled  # noqa: E402
from nginx_foreground import _configure_stdio_utf8  # noqa: E402
from redis_dev import (  # noqa: E402
    clear_dev_session_marker,
    is_redis_managed_service,
    stop_redis_for_dev,
)


def main() -> int:
    if not is_redis_enabled():
        return 0

    _configure_stdio_utf8()

    if is_redis_managed_service(PROJECT_ROOT):
        return 0

    stop_redis_for_dev(PROJECT_ROOT)
    clear_dev_session_marker(PROJECT_ROOT)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
