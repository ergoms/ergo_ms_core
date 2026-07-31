"""
Marker/PID/atexit helpers для dev-lifecycle nginx и redis (foreground в терминале).
"""

from __future__ import annotations

import atexit
import json
import os
import signal
import subprocess
import sys
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from nginx_foreground import _configure_stdio_utf8  # noqa: E402

DEV_SESSION_MARKER_NAME = 'dev-session.json'


def dev_session_marker_path(run_dir: Path) -> Path:
    return run_dir / DEV_SESSION_MARKER_NAME


def read_dev_session_marker(run_dir: Path) -> dict[str, Any] | None:
    path = dev_session_marker_path(run_dir)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def write_dev_session_marker(run_dir: Path, *, pid: int | None, source: str) -> None:
    marker_dir = dev_session_marker_path(run_dir).parent
    marker_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        'pid': pid,
        'source': source,
        'started_at': datetime.now(timezone.utc).isoformat(),
    }
    dev_session_marker_path(run_dir).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding='utf-8',
    )


def clear_dev_session_marker(run_dir: Path) -> None:
    dev_session_marker_path(run_dir).unlink(missing_ok=True)


def is_managed_service(*, windows_name: str, linux_name: str) -> bool:
    """True, если процесс управляется службой ОС, а не portable dev-сессией."""
    if os.name == 'nt':
        result = subprocess.run(
            ['sc', 'query', windows_name],
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            check=False,
        )
        if result.returncode != 0:
            return False
        return 'RUNNING' in (result.stdout or '').upper()

    active = subprocess.run(
        ['systemctl', 'is-active', '--quiet', linux_name],
        check=False,
    )
    return active.returncode == 0


def run_foreground_with_session(
    *,
    run_dir: Path,
    stop_quiet: Callable[[], None],
    launch: Callable[[], subprocess.Popen[bytes]],
) -> int:
    """
    Запуск foreground-процесса с marker/PID и atexit/signal cleanup.

    ``stop_quiet`` вызывается при выходе (Ctrl+C, закрытие терминала).
    """
    _configure_stdio_utf8()
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
        stop_quiet()
        clear_dev_session_marker(run_dir)
        session_owned = False

    def _handle_signal(signum: int, _frame: object) -> None:
        _cleanup()
        raise SystemExit(128 + signum if signum else 0)

    if hasattr(signal, 'SIGTERM'):
        signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    atexit.register(_cleanup)

    try:
        write_dev_session_marker(run_dir, pid=None, source='foreground')
        session_owned = True
        process = launch()
        write_dev_session_marker(run_dir, pid=process.pid, source='foreground')
        return process.wait()
    except KeyboardInterrupt:
        return 0
    finally:
        atexit.unregister(_cleanup)
        _cleanup()
