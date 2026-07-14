"""Запуск nginx в foreground для VS Code / ergoms start-client при NGINX_ENABLED=true."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

from deployment_env import PROJECT_ROOT, resolve_public_host

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from console_tags import format_console  # noqa: E402
from log_env import log_file_path, nginx_access_log_enabled  # noqa: E402


def _configure_stdio_utf8() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')


def nginx_paths() -> tuple[Path, Path, Path]:
    nginx_dir = PROJECT_ROOT / 'virtual_env' / 'packages' / 'nginx'
    if os.name == 'nt':
        exe = nginx_dir / 'nginx.exe'
    else:
        exe = nginx_dir / 'sbin' / 'nginx'
    main_conf = nginx_dir / 'conf' / 'nginx.conf'
    return nginx_dir, exe, main_conf


def is_nginx_running(nginx_dir: Path, exe: Path) -> bool:
    pid_file = nginx_dir / 'logs' / 'nginx.pid'
    if pid_file.is_file():
        try:
            pid = int(pid_file.read_text(encoding='utf-8').strip())
            if os.name == 'nt':
                result = subprocess.run(
                    ['tasklist', '/FI', f'PID eq {pid}', '/NH'],
                    capture_output=True,
                    text=True,
                    encoding='utf-8',
                    errors='replace',
                    check=False,
                )
                if str(pid) in (result.stdout or ''):
                    return True
            else:
                os.kill(pid, 0)
                return True
        except (OSError, ValueError, ProcessLookupError):
            pass

    if os.name == 'nt':
        result = subprocess.run(
            ['tasklist', '/FI', f'IMAGENAME eq {exe.name}', '/NH'],
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            check=False,
        )
        return exe.name.lower() in (result.stdout or '').lower()

    result = subprocess.run(
        ['pgrep', '-f', str(exe)],
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def nginx_log_tail_paths() -> list[Path]:
    """Central logs (ERGO_LOGS_DIR) and package-local nginx logs (Windows install path)."""
    nginx_dir, _, _ = nginx_paths()
    candidates: list[Path] = [
        log_file_path('NGINX_ERROR', PROJECT_ROOT),
    ]
    if nginx_access_log_enabled(PROJECT_ROOT):
        candidates.append(log_file_path('NGINX_ACCESS', PROJECT_ROOT))
    candidates.extend(
        [
            nginx_dir / 'logs' / 'error.log',
            nginx_dir / 'logs' / 'access.log',
        ]
    )

    seen: set[str] = set()
    unique: list[Path] = []
    for path in candidates:
        key = str(path.resolve())
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)
    return unique


def _print_client_hint(url: str) -> None:
    print(format_console('info', 'NGINX_ENABLED=true — клиент отдаётся через nginx.'))
    print(format_console('info', f'Откройте {url}'))
    print(format_console('info', 'После правок клиента: ergoms client-build && ergoms reload-nginx'))


def tail_log_files(
    paths: list[Path],
    *,
    wait_sec: float = 10.0,
    service: str = 'nginx',
    process_keeps_running: bool = True,
) -> int:
    deadline = time.monotonic() + wait_sec
    handles: dict[Path, object] = {}
    service_lower = service.lower()

    while not handles:
        for path in paths:
            if not path.is_file():
                continue
            handle = path.open('r', encoding='utf-8', errors='replace')
            handle.seek(0, os.SEEK_END)
            handles[path] = handle

        if handles:
            break
        if time.monotonic() >= deadline:
            print(format_console(
                'info',
                f'Файлы логов {service} не найдены. {service} работает; ожидание (Ctrl+C — выход)...',
            ))
            try:
                while True:
                    time.sleep(3600)
            except KeyboardInterrupt:
                print(format_console('info', 'Потоковый вывод логов остановлен.'))
            return 0
        time.sleep(0.5)

    if process_keeps_running:
        tail_hint = f'Потоковый вывод логов {service_lower} (Ctrl+C — выход, {service} продолжит работу)...'
    else:
        tail_hint = f'Потоковый вывод логов {service_lower} (Ctrl+C — выход)...'
    print(format_console('info', tail_hint))
    try:
        while True:
            for path, handle in list(handles.items()):
                line = handle.readline()
                while line:
                    print(f'[{path.name}] {line}', end='')
                    line = handle.readline()
            time.sleep(0.3)
    except KeyboardInterrupt:
        print(format_console('info', 'Потоковый вывод логов остановлен.'))
        return 0
    finally:
        for handle in handles.values():
            handle.close()


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

    error_log = log_file_path('NGINX_ERROR', PROJECT_ROOT)
    access_paths = nginx_log_tail_paths()

    if is_nginx_running(nginx_dir, exe):
        print(format_console('info', 'Nginx уже запущен.'))
        _print_client_hint(url)
        return tail_log_files(access_paths)

    test = subprocess.run(
        [str(exe), '-t', '-c', str(main_conf)],
        cwd=str(nginx_dir),
        check=False,
    )
    if test.returncode != 0:
        print(format_console('error', f'Проверка конфигурации nginx не прошла. См. {error_log}'))
        return test.returncode

    print(format_console('info', 'Запуск nginx (Ctrl+C останавливает nginx).'))
    _print_client_hint(url)
    return subprocess.call(
        [str(exe), '-c', str(main_conf), '-g', 'daemon off;'],
        cwd=str(nginx_dir),
    )


def read_env_port() -> str:
    from deployment_env import read_env

    return read_env('NGINX_LISTEN_PORT', '80')


if __name__ == '__main__':
    raise SystemExit(run_nginx_foreground())
