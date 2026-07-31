"""
Dev-lifecycle Redis: marker сессии, foreground-запуск, остановка при закрытии терминала.

Используется ensure_redis_if_enabled (warmup) и start_redis_if_enabled (терминал VS Code).
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from console_tags import format_console  # noqa: E402
from dev_session import (  # noqa: E402
    clear_dev_session_marker as _clear_marker,
    dev_session_marker_path as _marker_path,
    is_managed_service,
    read_dev_session_marker as _read_marker,
    run_foreground_with_session,
    write_dev_session_marker as _write_marker,
)
from install_redis import (  # noqa: E402
    ping_redis,
    redis_cli_path,
    redis_conf_path,
    redis_packages_dir,
    redis_server_path,
)
from nginx_foreground import _configure_stdio_utf8  # noqa: E402

REDIS_WINDOWS_SERVICE = 'ergo_ms_redis'
REDIS_LINUX_SERVICE = 'ergo_ms_redis.service'


def redis_run_dir(root: Path) -> Path:
    return redis_packages_dir(root) / 'run'


def redis_pidfile_path(root: Path) -> Path:
    return redis_packages_dir(root) / 'run' / 'redis.pid'


def read_redis_pid(root: Path) -> int | None:
    pidfile = redis_pidfile_path(root)
    if not pidfile.is_file():
        return None
    try:
        return int(pidfile.read_text(encoding='utf-8').strip())
    except (OSError, ValueError):
        return None


def is_redis_managed_service(root: Path) -> bool:
    _ = root
    return is_managed_service(windows_name=REDIS_WINDOWS_SERVICE, linux_name=REDIS_LINUX_SERVICE)


def _redis_cli_endpoint(root: Path) -> tuple[str, str]:
    bind = '127.0.0.1'
    port = '6379'
    conf = redis_conf_path(root)
    if conf.is_file():
        for line in conf.read_text(encoding='utf-8').splitlines():
            stripped = line.strip()
            if stripped.startswith('bind '):
                bind = stripped.split()[1]
            elif stripped.startswith('port '):
                port = stripped.split()[1]
    return bind, port


def stop_redis_for_dev(root: Path, *, quiet: bool = False) -> bool:
    """
    Останавливает portable Redis (redis-cli shutdown). Службу ОС не трогает.

    Returns True, если Redis больше не отвечает на ping.
    """
    if is_redis_managed_service(root):
        return True

    if not quiet:
        _configure_stdio_utf8()

    if not ping_redis(root):
        _remove_stale_pidfile(root)
        return True

    cli = redis_cli_path(root)
    if cli.is_file():
        if not quiet:
            print(format_console('info', 'Остановка Redis...'))
        bind, port = _redis_cli_endpoint(root)
        subprocess.run(
            [str(cli), '-h', bind, '-p', port, 'shutdown'],
            capture_output=True,
            check=False,
        )
        time.sleep(0.5)

    _remove_stale_pidfile(root)

    if ping_redis(root):
        if not quiet:
            print(format_console('warning', 'Redis не ответил на shutdown, завершение процесса...'))
        _force_stop_redis_process(root)

    still_running = ping_redis(root)
    if not still_running and not quiet:
        print(format_console('ok', 'Redis остановлен'))
    return not still_running


def _remove_stale_pidfile(root: Path) -> None:
    redis_pidfile_path(root).unlink(missing_ok=True)


def _force_stop_redis_process(root: Path) -> None:
    if os.name == 'nt':
        subprocess.run(
            ['taskkill', '/F', '/IM', 'redis-server.exe'],
            capture_output=True,
            check=False,
        )
        return

    redis_dir = redis_packages_dir(root)
    subprocess.run(
        ['pkill', '-f', f'{redis_dir}/bin/redis-server'],
        capture_output=True,
        check=False,
    )


def run_redis_foreground(root: Path) -> int:
    """
    Запускает redis-server в foreground; при выходе останавливает только свою сессию.
    """
    server = redis_server_path(root)
    conf = redis_conf_path(root)
    redis_dir = redis_packages_dir(root)
    run_dir = redis_run_dir(root)

    if not server.is_file() or not conf.is_file():
        print(format_console('error', 'Redis не установлен. Выполните: ergoms install-redis'))
        return 1

    if is_redis_managed_service(root):
        print(format_console('error', 'Redis работает как служба ОС; используйте ergoms stop-redis'))
        return 1

    _configure_stdio_utf8()

    if ping_redis(root):
        print(format_console('error', 'Redis уже запущен. Остановите его перед foreground-запуском.'))
        return 1

    print(format_console(
        'info',
        'Запуск Redis (Ctrl+C или закрытие терминала останавливает Redis)...',
    ))

    conf_arg = 'conf/redis.conf' if os.name != 'nt' else 'conf\\redis.conf'

    def _launch() -> subprocess.Popen[bytes]:
        return subprocess.Popen(
            [str(server), conf_arg, '--daemonize', 'no'],
            cwd=str(redis_dir),
        )

    return run_foreground_with_session(
        run_dir=run_dir,
        stop_quiet=lambda: stop_redis_for_dev(root, quiet=True),
        launch=_launch,
    )


def dev_session_marker_path(root: Path) -> Path:
    return _marker_path(redis_run_dir(root))


def read_dev_session_marker(root: Path):
    return _read_marker(redis_run_dir(root))


def write_dev_session_marker(root: Path, *, pid: int | None, source: str) -> None:
    _write_marker(redis_run_dir(root), pid=pid, source=source)


def clear_dev_session_marker(root: Path) -> None:
    _clear_marker(redis_run_dir(root))
