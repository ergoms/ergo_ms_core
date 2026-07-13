"""
Установка автоматической ротации infra-логов (nginx, redis, client-dev).

Linux: cron (ежедневно в ERGO_LOG_INFRA_ROTATE_HOUR).
Windows: задача планировщика «ERGO MS Log Rotate».
Параметры размера — в .env (см. ERGO_LOG_INFRA_*); выполняет rotate_infra_logs.py.
"""

from __future__ import annotations

import argparse
import os
import platform
import subprocess
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from deployment_env import PROJECT_ROOT  # noqa: E402
from log_env import infra_rotation_settings  # noqa: E402

CRON_MARKER = '# ergo_ms infra log rotate'
TASK_NAME = 'ERGO MS Log Rotate'


def _python_exe(root: Path) -> Path:
    if os.name == 'nt':
        return root / 'virtual_env' / 'python' / 'Scripts' / 'python.exe'
    return root / 'virtual_env' / 'python' / 'bin' / 'python'


def _rotate_command(root: Path) -> str:
    py = _python_exe(root)
    script = root / 'core' / 'deployment' / 'scripts' / 'rotate_infra_logs.py'
    if os.name == 'nt':
        return f'"{py}" "{script}" --root "{root}"'
    return f'{py} {script} --root {root}'


def install_linux(root: Path, hour: int, *, uninstall: bool) -> int:
    cron_line = f'0 {hour} * * * {_rotate_command(root)} >> {root / "logs" / "rotate-infra.log"} 2>&1 {CRON_MARKER}'
    try:
        result = subprocess.run(['crontab', '-l'], capture_output=True, text=True, check=False)
        existing = result.stdout if result.returncode == 0 else ''
    except OSError as exc:
        print(f'[ERROR] crontab unavailable: {exc}', file=sys.stderr)
        return 1

    lines = [line for line in existing.splitlines() if CRON_MARKER not in line]
    if uninstall:
        new_crontab = '\n'.join(lines).strip()
        if new_crontab:
            new_crontab += '\n'
        proc = subprocess.run(['crontab', '-'], input=new_crontab, text=True, check=False)
        if proc.returncode == 0:
            print('[OK] Удалено ergo_ms infra log rotate cron job')
        return proc.returncode

    lines.append(cron_line)
    new_crontab = '\n'.join(lines).strip() + '\n'
    proc = subprocess.run(['crontab', '-'], input=new_crontab, text=True, check=False)
    if proc.returncode != 0:
        print('[ERROR] Не удалось добавить запись в crontab', file=sys.stderr)
        return proc.returncode
    print(f'[OK] Ежедневный cron в {hour:02d}:00 — параметры ergoms rotate-logs из .env')
    print(f'     Log: {root / "logs" / "rotate-infra.log"}')
    return 0


def install_windows(root: Path, hour: int, *, uninstall: bool) -> int:
    cmd = _rotate_command(root)
    if uninstall:
        proc = subprocess.run(['schtasks', '/Delete', '/TN', TASK_NAME, '/F'], check=False)
        if proc.returncode == 0:
            print(f'[OK] Удалено scheduled task: {TASK_NAME}')
        else:
            print('[WARNING] Запланированная задача не найдена или не удалось удалить')
        return 0

    time_str = f'{hour:02d}:00'
    proc = subprocess.run(
        [
            'schtasks',
            '/Create',
            '/F',
            '/SC',
            'DAILY',
            '/ST',
            time_str,
            '/TN',
            TASK_NAME,
            '/TR',
            cmd,
            '/RL',
            'HIGHEST',
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        print('[ERROR] schtasks failed:', proc.stderr or proc.stdout, file=sys.stderr)
        print('Запустите PowerShell от имени администратора.', file=sys.stderr)
        return proc.returncode
    print(f'[OK] Запланированная задача «{TASK_NAME}» ежедневно в {time_str}')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description='Install/uninstall scheduled infra log rotation')
    parser.add_argument('--root', type=Path, default=PROJECT_ROOT)
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()

    root = args.root.resolve()
    settings = infra_rotation_settings(root)
    hour = max(0, min(23, int(settings['schedule_hour'])))

    if not settings['enabled'] and not args.uninstall:
        print('[WARNING] ERGO_LOG_INFRA_ROTATE_ENABLED=false — installing schedule anyway (rotation no-op until enabled)')

    system = platform.system().lower()
    if system == 'windows':
        return install_windows(root, hour, uninstall=args.uninstall)
    if system == 'linux':
        return install_linux(root, hour, uninstall=args.uninstall)

    print(f'[ERROR] Unsupported OS for install-infra-log-rotate: {system}', file=sys.stderr)
    print('Запустите вручную: ergoms rotate-logs', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
