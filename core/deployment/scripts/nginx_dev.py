"""
Dev-lifecycle nginx: marker сессии, foreground-запуск, остановка при закрытии терминала.

Используется start_nginx_if_enabled и start_client_if_dev (терминал VS Code).
"""

from __future__ import annotations

import atexit
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from console_tags import format_console  # noqa: E402
from deployment_env import PROJECT_ROOT, resolve_public_host  # noqa: E402
from nginx_foreground import (  # noqa: E402
    _configure_stdio_utf8,
    _print_client_hint,
    is_nginx_running,
    nginx_paths,
    read_env_port,
    tail_log_files,
)

NGINX_WINDOWS_SERVICE = 'ergo_ms_nginx'
NGINX_LINUX_SERVICE = 'ergo_ms_nginx.service'
DEV_SESSION_MARKER_NAME = 'dev-session.json'


def dev_session_marker_path(root: Path) -> Path:
    nginx_dir, _, _ = nginx_paths()
    return nginx_dir / 'run' / DEV_SESSION_MARKER_NAME


def read_dev_session_marker(root: Path) -> dict[str, Any] | None:
    path = dev_session_marker_path(root)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def write_dev_session_marker(root: Path, *, pid: int | None, source: str) -> None:
    marker_dir = dev_session_marker_path(root).parent
    marker_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        'pid': pid,
        'source': source,
        'started_at': datetime.now(timezone.utc).isoformat(),
    }
    dev_session_marker_path(root).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding='utf-8',
    )


def clear_dev_session_marker(root: Path) -> None:
    dev_session_marker_path(root).unlink(missing_ok=True)


def is_nginx_managed_service(root: Path) -> bool:
    """True, если nginx управляется службой ОС (не portable dev-процессом)."""
    if os.name == 'nt':
        result = subprocess.run(
            ['sc', 'query', NGINX_WINDOWS_SERVICE],
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            check=False,
        )
        if result.returncode != 0:
            return False
        output = (result.stdout or '').upper()
        return 'RUNNING' in output

    active = subprocess.run(
        ['systemctl', 'is-active', '--quiet', NGINX_LINUX_SERVICE],
        check=False,
    )
    return active.returncode == 0


def _remove_stale_pidfile(nginx_dir: Path) -> None:
    (nginx_dir / 'logs' / 'nginx.pid').unlink(missing_ok=True)


def wait_nginx_stopped(nginx_dir: Path, exe: Path, *, timeout_sec: float = 8.0) -> bool:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if not is_nginx_running(nginx_dir, exe):
            return True
        time.sleep(0.2)
    return False


def _force_stop_nginx_process(nginx_dir: Path, exe: Path) -> None:
    if os.name == 'nt':
        subprocess.run(
            ['taskkill', '/F', '/IM', exe.name],
            capture_output=True,
            check=False,
        )
        return

    subprocess.run(
        ['pkill', '-f', str(exe)],
        capture_output=True,
        check=False,
    )


def stop_nginx_for_dev(root: Path, *, quiet: bool = False) -> bool:
    """
    Останавливает portable nginx (nginx -s quit). Службу ОС не трогает.

    Returns True, если nginx больше не запущен.
    """
    if is_nginx_managed_service(root):
        return True

    if not quiet:
        _configure_stdio_utf8()

    nginx_dir, exe, main_conf = nginx_paths()

    if not is_nginx_running(nginx_dir, exe):
        _remove_stale_pidfile(nginx_dir)
        return True

    if not quiet:
        print(format_console('info', 'Остановка nginx...'))

    main_conf_arg = str(main_conf).replace('\\', '/') if os.name == 'nt' else str(main_conf)
    subprocess.run(
        [str(exe), '-s', 'quit', '-c', main_conf_arg],
        cwd=str(nginx_dir),
        capture_output=True,
        check=False,
    )
    time.sleep(0.5)

    _remove_stale_pidfile(nginx_dir)

    if is_nginx_running(nginx_dir, exe):
        if not quiet:
            print(format_console('warning', 'Nginx не ответил на quit, завершение процесса...'))
        _force_stop_nginx_process(nginx_dir, exe)
        _remove_stale_pidfile(nginx_dir)

    still_running = is_nginx_running(nginx_dir, exe)
    if not still_running and not quiet:
        print(format_console('ok', 'Nginx остановлен'))
    return not still_running


def _run_nginx_process(nginx_dir: Path, exe: Path, main_conf: Path) -> int:
    process: subprocess.Popen[bytes] | None = None
    session_owned = False

    def _cleanup() -> None:
        nonlocal session_owned
        if not session_owned:
            return
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        stop_nginx_for_dev(PROJECT_ROOT, quiet=True)
        clear_dev_session_marker(PROJECT_ROOT)
        session_owned = False

    def _handle_signal(signum: int, _frame: object) -> None:
        _cleanup()
        raise SystemExit(128 + signum if signum else 0)

    if hasattr(signal, 'SIGTERM'):
        signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    atexit.register(_cleanup)

    main_conf_arg = str(main_conf).replace('\\', '/') if os.name == 'nt' else str(main_conf)
    try:
        write_dev_session_marker(PROJECT_ROOT, pid=None, source='foreground')
        session_owned = True

        process = subprocess.Popen(
            [str(exe), '-c', main_conf_arg, '-g', 'daemon off;'],
            cwd=str(nginx_dir),
        )
        write_dev_session_marker(PROJECT_ROOT, pid=process.pid, source='foreground')

        return process.wait()
    except KeyboardInterrupt:
        return 0
    finally:
        atexit.unregister(_cleanup)
        _cleanup()


def run_nginx_foreground() -> int:
    _configure_stdio_utf8()
    nginx_dir, exe, main_conf = nginx_paths()
    if not exe.is_file():
        print(format_console('error', 'Nginx не установлен. Выполните: ergoms install-nginx'))
        return 1

    public_host = resolve_public_host()
    port = read_env_port()
    url = f'http://{public_host}'
    if port not in ('80', '443'):
        url = f'{url}:{port}'

    from nginx_foreground import nginx_log_tail_paths  # noqa: WPS433

    access_paths = nginx_log_tail_paths()

    if is_nginx_managed_service(PROJECT_ROOT):
        print(format_console('info', 'Nginx работает как служба ОС; терминал не управляет процессом.'))
        _print_client_hint(url)
        return tail_log_files(access_paths, service='nginx', process_keeps_running=True)

    marker = read_dev_session_marker(PROJECT_ROOT)

    if is_nginx_running(nginx_dir, exe):
        if marker is None:
            print(format_console(
                'info',
                'Nginx уже запущен (внешний); закрытие терминала не остановит сервер.',
            ))
            _print_client_hint(url)
            return tail_log_files(access_paths, service='nginx', process_keeps_running=True)

        print(format_console('info', 'Передача управления nginx в терминал разработки...'))
        stop_nginx_for_dev(PROJECT_ROOT)
        clear_dev_session_marker(PROJECT_ROOT)
        if not wait_nginx_stopped(nginx_dir, exe, timeout_sec=5.0):
            print(format_console('error', 'Не удалось остановить предыдущий nginx перед foreground-запуском.'))
            return 1
    elif marker is not None:
        clear_dev_session_marker(PROJECT_ROOT)

    test = subprocess.run(
        [str(exe), '-t', '-c', str(main_conf)],
        cwd=str(nginx_dir),
        check=False,
    )
    if test.returncode != 0:
        from log_env import log_file_path  # noqa: WPS433

        error_log = log_file_path('NGINX_ERROR', PROJECT_ROOT)
        print(format_console('error', f'Проверка конфигурации nginx не прошла. См. {error_log}'))
        return test.returncode

    print(format_console(
        'info',
        'Запуск nginx (Ctrl+C или закрытие терминала останавливает nginx)...',
    ))
    _print_client_hint(url)
    return _run_nginx_process(nginx_dir, exe, main_conf)
