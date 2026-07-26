"""
Запуск Redis в foreground для VS Code / ergoms start-redis-dev.

При REDIS_ENABLED=true:
- нет процесса — foreground-запуск (закрытие терминала останавливает Redis);
- есть marker (warmup) — только логи, но закрытие терминала останавливает Redis
  (без stop/restart, чтобы не было окна без Redis перед API);
- без marker (внешний) — только логи, процесс не трогаем.
При REDIS_ENABLED=false: выход без сообщений.
"""

from __future__ import annotations

import atexit
import signal
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from console_tags import format_console  # noqa: E402
from deployment_env import PROJECT_ROOT, is_redis_enabled  # noqa: E402
from install_redis import is_installed, ping_redis, redis_packages_dir  # noqa: E402
from log_env import log_file_path  # noqa: E402
from nginx_foreground import _configure_stdio_utf8, tail_log_files  # noqa: E402
from redis_dev import (  # noqa: E402
    clear_dev_session_marker,
    is_redis_managed_service,
    read_dev_session_marker,
    run_redis_foreground,
    stop_redis_for_dev,
)


def redis_log_tail_paths() -> list[Path]:
    candidates = [
        log_file_path('REDIS', PROJECT_ROOT),
        redis_packages_dir(PROJECT_ROOT) / 'logs' / 'redis.log',
    ]
    seen: set[str] = set()
    unique: list[Path] = []
    for path in candidates:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)
    return unique


def _tail_owned_session() -> int:
    """Поток логов Redis с остановкой portable-процесса при выходе из терминала."""
    session_owned = True

    def _cleanup() -> None:
        nonlocal session_owned
        if not session_owned:
            return
        stop_redis_for_dev(PROJECT_ROOT, quiet=True)
        clear_dev_session_marker(PROJECT_ROOT)
        session_owned = False

    def _handle_signal(signum: int, _frame: object) -> None:
        _cleanup()
        raise SystemExit(128 + signum if signum else 0)

    if hasattr(signal, 'SIGTERM'):
        signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    atexit.register(_cleanup)

    print(format_console(
        'info',
        'Redis уже запущен (warmup); логи ниже. Ctrl+C или закрытие терминала останавливает Redis.',
    ))
    try:
        return tail_log_files(
            redis_log_tail_paths(),
            service='Redis',
            process_keeps_running=False,
        )
    except KeyboardInterrupt:
        return 0
    finally:
        atexit.unregister(_cleanup)
        _cleanup()


def main() -> int:
    if not is_redis_enabled():
        return 0

    _configure_stdio_utf8()

    if not is_installed(PROJECT_ROOT):
        print(format_console('error', 'Redis не установлен. Выполните: ergoms install-redis'))
        return 1

    if is_redis_managed_service(PROJECT_ROOT):
        print(format_console('info', 'Redis работает как служба ОС; терминал не управляет процессом.'))
        return tail_log_files(redis_log_tail_paths(), service='Redis', process_keeps_running=True)

    marker = read_dev_session_marker(PROJECT_ROOT)

    if ping_redis(PROJECT_ROOT):
        if marker is None:
            print(format_console(
                'info',
                'Redis уже запущен (внешний); закрытие терминала не остановит сервер.',
            ))
            return tail_log_files(redis_log_tail_paths(), service='Redis', process_keeps_running=True)
        return _tail_owned_session()

    if marker is not None:
        clear_dev_session_marker(PROJECT_ROOT)

    return run_redis_foreground(PROJECT_ROOT)


if __name__ == '__main__':
    raise SystemExit(main())
