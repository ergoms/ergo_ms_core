"""Вызов shell-функций deployment (services, nginx, redis) без цикла ergo_ms → runner."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[2]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402

from lifecycle.context import DeploymentContext, HostPlatform  # noqa: E402

_WINDOWS_DISPATCH = _DEPLOYMENT_DIR / 'lifecycle' / 'host' / 'internal_dispatch.ps1'
_LINUX_DISPATCH = _DEPLOYMENT_DIR / 'lifecycle' / 'host' / 'internal_dispatch.sh'

_SCRIPTS_DIR = _DEPLOYMENT_DIR / 'scripts'
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from ps1_io import UTF8_BOM  # noqa: E402
from sh_io import sh_encoding_issues  # noqa: E402

_LINUX_MAIN_SCRIPT = _DEPLOYMENT_DIR / 'linux' / 'ergo_ms.sh'


def _assert_linux_sh_readable(path: Path) -> int | None:
    """Bash на Linux: CRLF/BOM в .sh ломают shebang и source."""
    if not path.is_file():
        return None
    issues = sh_encoding_issues(path.read_bytes())
    if not issues:
        return None
    rel = path.relative_to(_DEPLOYMENT_DIR.parent.parent)
    print(
        format_console(
            'error',
            f'{rel}: {", ".join(issues)} — bash не запустит скрипт на Linux. '
            'Выполните: ergoms sh-encoding-check --fix',
        ),
        file=sys.stderr,
    )
    return 1


def _assert_windows_ps1_readable(path: Path) -> int | None:
    """PowerShell 5.1: .ps1 с не-ASCII без BOM не парсится."""
    if not path.is_file():
        return None
    raw = path.read_bytes()
    if raw.startswith(UTF8_BOM):
        return None
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        return None
    if any(ord(ch) > 127 for ch in text):
        rel = path.relative_to(_DEPLOYMENT_DIR.parent.parent)
        print(
            format_console(
                'error',
                f'{rel}: нет UTF-8 BOM — PowerShell 5.1 не разберёт кириллицу. '
                'Выполните: ergoms ps1-encoding-check --fix',
            ),
            file=sys.stderr,
        )
        return 1
    return None


def invoke_dispatch(
    ctx: DeploymentContext,
    category: str,
    operation: str,
    *extra_args: str,
) -> int:
    root = str(ctx.project_root)
    if ctx.platform == HostPlatform.WIN32:
        bom_err = _assert_windows_ps1_readable(_WINDOWS_DISPATCH)
        if bom_err is not None:
            return bom_err
        cmd = [
            'powershell.exe',
            '-ExecutionPolicy',
            'Bypass',
            '-NoProfile',
            '-File',
            str(_WINDOWS_DISPATCH),
            '-Category',
            category,
            '-Operation',
            operation,
            '-Root',
            root,
            *extra_args,
        ]
        return subprocess.call(cmd, cwd=root)

    for sh_path in (_LINUX_DISPATCH, _LINUX_MAIN_SCRIPT):
        sh_err = _assert_linux_sh_readable(sh_path)
        if sh_err is not None:
            return sh_err

    argv = ['bash', str(_LINUX_DISPATCH), category, operation, root, *extra_args]
    if ctx.option_bool('needs_sudo') and sys.platform != 'win32':
        import os

        if hasattr(os, 'geteuid') and os.geteuid() != 0:
            argv = ['sudo', *argv]
    return subprocess.call(argv, cwd=root)
