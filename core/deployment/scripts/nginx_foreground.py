"""Запуск nginx в foreground для VS Code / ergoms start-client при NGINX_ENABLED=true."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

from deployment_env import PROJECT_ROOT

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from cli_locale import t  # noqa: E402
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
    print(format_console('info', t('nginx_client_via_nginx')))
    print(format_console('info', t('open_url', url=url)))
    print(format_console('info', t('after_client_edits_hint')))


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
                t('log_files_not_found_waiting', service=service),
            ))
            try:
                while True:
                    time.sleep(3600)
            except KeyboardInterrupt:
                print(format_console('info', t('log_stream_stopped')))
            return 0
        time.sleep(0.5)

    if process_keeps_running:
        tail_hint = t('log_stream_keeps_running', service_lower=service_lower, service=service)
    else:
        tail_hint = t('log_stream_exit', service_lower=service_lower)
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
        print(format_console('info', t('log_stream_stopped')))
        return 0
    finally:
        for handle in handles.values():
            handle.close()


def run_nginx_foreground() -> int:
    from nginx_dev import run_nginx_foreground as _run_dev_foreground  # noqa: WPS433

    return _run_dev_foreground()


def read_env_port() -> str:
    from deployment_env import read_env

    return read_env('NGINX_LISTEN_PORT', '80')


if __name__ == '__main__':
    raise SystemExit(run_nginx_foreground())
